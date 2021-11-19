//! Auctions Module
//!
//! This module is responsible for triggering and participating in a Auction's
//! dutch auction
use crate::{
    bindings::{Cauldron, Witch, VaultIdType, FlashLiquidator},
    borrowers::{Vault},
    escalator::GeometricGasPrice,
    merge, Result,
};

use ethers_core::types::transaction::eip2718::TypedTransaction;

use ethers::{
    prelude::*,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fmt, sync::Arc, time::Instant};
use tracing::{debug, debug_span, error, info, trace, warn, instrument};

pub type AuctionMap = HashMap<VaultIdType, bool>;


#[derive(Clone)]
pub struct Liquidator<M> {
    cauldron: Cauldron<M>,
    liquidator: Witch<M>,
    flash_liquidator: FlashLiquidator<M>,

    /// The currently active auctions
    pub auctions: AuctionMap,

    /// We use multicall to batch together calls and have reduced stress on
    /// our RPC endpoint
    multicall: Multicall<M>,

    /// The minimum ratio (collateral/debt) to trigger liquidation
    min_ratio: u16,

    pending_liquidations: HashMap<VaultIdType, PendingTransaction>,
    pending_auctions: HashMap<VaultIdType, PendingTransaction>,
    gas_escalator: GeometricGasPrice,

    instance_name: String
}

/// Tx / Hash/ Submitted at time
type PendingTransaction = (TypedTransaction, TxHash, Instant);

/// An initiated auction
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Auction {
    /// The start time of the auction
    started: u32,
    under_auction: bool,
    /// The debt which can be repaid
    debt: u128,

    ratio_pct: u16,
    is_at_minimal_price: bool,

}

#[derive(Clone, Debug, Serialize, Deserialize)]
enum TxType {
    Auction,
    Liquidation,
}

impl fmt::Display for TxType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let string = match self {
            TxType::Auction => "auction",
            TxType::Liquidation => "liquidation",
        };
        write!(f, "{}", string)
    }
}

impl<M: Middleware> Liquidator<M> {
    /// Constructor
    pub async fn new(
        cauldron: Address,
        liquidator: Address,
        flashloan: Address,
        multicall: Option<Address>,
        min_ratio: u16,
        client: Arc<M>,
        auctions: AuctionMap,
        gas_escalator: GeometricGasPrice,
        instance_name: String
    ) -> Self {
        let multicall = Multicall::new(client.clone(), multicall)
            .await
            .expect("could not initialize multicall");

        Self {
            cauldron: Cauldron::new(cauldron, client.clone()),
            liquidator: Witch::new(liquidator, client.clone()),
            flash_liquidator: FlashLiquidator::new(flashloan, client.clone()),
            multicall,
            min_ratio,
            auctions,

            pending_liquidations: HashMap::new(),
            pending_auctions: HashMap::new(),
            gas_escalator,
            instance_name
        }
    }

    /// Checks if any transactions which have been submitted are mined, removes
    /// them if they were successful, otherwise bumps their gas price
    #[instrument(skip(self), fields(self.instance_name))]
    pub async fn remove_or_bump(&mut self) -> Result<(), M> {
        let now = Instant::now();

        let liquidator_client = self.liquidator.client();
        // Check all the pending liquidations
        Liquidator::remove_or_bump_inner(now, liquidator_client, &self.gas_escalator,
            &mut self.pending_liquidations, "liquidations", self.instance_name.as_ref()).await?;
        Liquidator::remove_or_bump_inner(now, liquidator_client, &self.gas_escalator,
            &mut self.pending_auctions, "auctions", self.instance_name.as_ref()).await?;

        Ok(())
    }

    async fn remove_or_bump_inner<K: Clone + Eq + ::std::hash::Hash + std::fmt::Debug>(
        now: Instant,
        client: &M,
        gas_escalator: &GeometricGasPrice,
        pending_txs: &mut HashMap<K, PendingTransaction>,
        tx_type: &str,
        instance_name: &str
        ) -> Result<(), M> {
        for (addr, (pending_tx_wrapper, tx_hash, instant)) in pending_txs.clone().into_iter() {
            let pending_tx = match pending_tx_wrapper {
                TypedTransaction::Eip1559(x) => x,
                _ => panic!("Non-Eip1559 transactions are not supported yet")
            };

            // get the receipt and check inclusion, or bump its gas price
            let receipt = client
                .get_transaction_receipt(tx_hash)
                .await
                .map_err(ContractError::MiddlewareError)?;
            if let Some(receipt) = receipt {
                pending_txs.remove(&addr);
                let status = if receipt.status == Some(1.into()) {
                    "success"
                } else {
                    "fail"
                };
                info!(tx_hash = ?tx_hash, gas_used = %receipt.gas_used.unwrap_or_default(), user = ?addr,
                    status = status, tx_type, instance_name, "confirmed");
            } else {
                // Get the new gas price based on how much time passed since the
                // tx was last broadcast
                let new_gas_price = gas_escalator.get_gas_price(
                    pending_tx.max_fee_per_gas.expect("max_fee_per_gas price must be set"),
                    now.duration_since(instant).as_secs(),
                );

                let replacement_tx = pending_txs
                    .get_mut(&addr)
                    .expect("tx will always be found since we're iterating over the map");

                // bump the gas price
                if let TypedTransaction::Eip1559(x) = &mut replacement_tx.0 {
                    x.max_fee_per_gas = Some(new_gas_price);
                    x.max_priority_fee_per_gas = Some(new_gas_price); // 2 gwei
                } else {
                    panic!("Non-Eip1559 transactions are not supported yet");
                }

                // rebroadcast (TODO: Can we avoid cloning?)
                replacement_tx.1 = *client
                    .send_transaction(replacement_tx.0.clone(), None)
                    .await
                    .map_err(ContractError::MiddlewareError)?;

                info!(tx_hash = ?tx_hash, new_gas_price = %new_gas_price, user = ?addr,
                    tx_type, instance_name, "Bumping gas: done");
            }
        }

        Ok(())
    }

    /// Sends a bid for any of the liquidation auctions.
    #[instrument(skip(self, from_block, to_block), fields(self.instance_name))]
    pub async fn buy_opportunities(
        &mut self,
        from_block: U64,
        to_block: U64,
        gas_price: U256,
    ) -> Result<(), M> {
        let all_auctions = {
            let liquidations = self
                .liquidator
                .auctioned_filter()
                .from_block(from_block)
                .to_block(to_block)
                .query()
                .await?;
            let new_liquidations = liquidations
                .iter()
                .map(|x| x.vault_id).collect::<Vec<_>>();
            merge(new_liquidations, &self.auctions)
        };

        info!(count=all_auctions.len(), instance_name=self.instance_name.as_str(), "Liquidations collected");
        for vault_id in all_auctions {
            self.auctions.insert(vault_id, true);

            trace!(vault_id=?hex::encode(vault_id), "Buying");
            let is_still_valid: bool = self.buy(vault_id, Instant::now(), gas_price).await?;
            if !is_still_valid {
                info!(vault_id=?hex::encode(vault_id), instance_name=self.instance_name.as_str(), "Removing no longer valid auction");
                self.auctions.remove(&vault_id);
            }
        }

        Ok(())
    }

    /// Tries to buy the collateral associated with a user's liquidation auction
    /// via a flashloan funded by Uniswap.
    ///
    /// Returns
    ///  - Result<false>: auction is no longer valid, we need to forget about it
    ///  - Result<true>: auction is still valid
    #[instrument(skip(self), fields(self.instance_name))]
    async fn buy(&mut self, vault_id: VaultIdType, now: Instant, gas_price: U256) -> Result<bool, M> {
        // only iterate over users that do not have active auctions
        if let Some(pending_tx) = self.pending_auctions.get(&vault_id) {
            trace!(tx_hash = ?pending_tx.1, vault_id=?vault_id, "bid not confirmed yet");
            return Ok(true);
        }

        // Get the vault's info
        let auction = match self.get_auction(vault_id).await {
            Ok(x) => x,
            Err(x) => {
                warn!(vault_id=?hex::encode(vault_id), err=?x, "Failed to get auction");
                return Ok(true);
            }
        };

        if !auction.under_auction {
            debug!(vault_id=?hex::encode(vault_id), auction=?auction, "Auction is no longer active");
            return Ok(false);
        }

        // Skip auctions which do not have any outstanding debt
        if auction.debt == 0 {
            debug!(vault_id=?hex::encode(vault_id), auction=?auction, "Has no debt - skipping");
            return Ok(true);
        }

        let mut buy: bool = false;
        if auction.ratio_pct <= self.min_ratio {
            info!(vault_id=?hex::encode(vault_id), auction=?auction,
                ratio=auction.ratio_pct, ratio_threshold=self.min_ratio,
                instance_name=self.instance_name.as_str(),
                "Ratio threshold is reached, buying");
            buy = true;
        }
        if auction.is_at_minimal_price {
            info!(vault_id=?hex::encode(vault_id), auction=?auction,
                ratio=auction.ratio_pct, ratio_threshold=self.min_ratio,
                instance_name=self.instance_name.as_str(),
                "Is at minimal price, buying");
            buy = true;
        }
        if !buy {
            debug!(vault_id=?hex::encode(vault_id), auction=?auction, "Not time to buy yet");
            return Ok(true);
        }

        if self.auctions.insert(vault_id, true).is_none() {
            debug!(vault_id=?vault_id, auction=?auction, "new auction");
        }
        let span = debug_span!("buying", vault_id=?vault_id, auction=?auction);
        let _enter = span.enter();

        let call = self.flash_liquidator.liquidate(vault_id)
            .gas_price(gas_price)
            .block(BlockNumber::Pending);

        let tx = call.tx.clone();

        match call.send().await {
            Ok(hash) => {
                // record the tx
                info!(tx_hash = ?hash, instance_name=self.instance_name.as_str(), "Submitted buy order");
                self.pending_auctions
                    .entry(vault_id)
                    .or_insert((tx, *hash, now));
            }
            Err(err) => {
                let err = err.to_string();
                error!("Error: {}; data: {:?}", err, call.calldata());
            }
        };

        Ok(true)
    }

    /// Triggers liquidations for any vulnerable positions which were fetched from the
    /// controller
    #[instrument(skip(self, vaults), fields(self.instance_name))]
    pub async fn start_auctions(
        &mut self,
        vaults: impl Iterator<Item = (&VaultIdType, &Vault)>,
        gas_price: U256,
    ) -> Result<(), M> {
        debug!("checking for undercollateralized positions...");

        let now = Instant::now();

        for (vault_id, vault) in vaults {
            if !vault.is_initialized {
                trace!(vault_id = ?hex::encode(vault_id), "Vault is not initialized yet, skipping");
                continue;
            }
            // only iterate over vaults that do not have pending liquidations
            if let Some(pending_tx) = self.pending_liquidations.get(vault_id) {
                trace!(tx_hash = ?pending_tx.1, vault_id = ?hex::encode(vault_id), "liquidation not confirmed yet");
                continue;
            }

            if !vault.is_collateralized {
                if vault.under_auction {
                    debug!(vault_id = ?hex::encode(vault_id), details = ?vault, "found vault under auction, ignoring it");
                    continue;
                }
                info!(
                    vault_id = ?hex::encode(vault_id), details = ?vault, gas_price=?gas_price,
                    instance_name=self.instance_name.as_str(),
                    "found an undercollateralized vault. starting an auction",
                );

                // Send the tx and track it
                let call = self.liquidator.auction(*vault_id).gas_price(gas_price);
                let tx = call.tx.clone();
                match call.send().await {
                    Ok(tx_hash) => {
                        info!(tx_hash = ?tx_hash, vault_id = ?hex::encode(vault_id), instance_name=self.instance_name.as_str(), "Submitted liquidation");
                        self.pending_liquidations
                            .entry(*vault_id)
                            .or_insert((tx, *tx_hash, now));
                    }
                    Err(x) => {
                        warn!(
                            vault_id = ?hex::encode(vault_id), 
                            error=?x,
                            calldata=?call.calldata(),
                            "Can't start the auction");
                    }
                };
            } else {
                debug!(vault_id=?hex::encode(vault_id), "Vault is collateralized");
            }
        }
        Ok(())
    }

    async fn get_auction(&mut self, vault_id: VaultIdType) -> Result<Auction, M> {
        let balances_fn = self.cauldron.balances(vault_id);
        let auction_fn = self.liquidator.auctions(vault_id);

        trace!(
            vault_id=?hex::encode(vault_id),
            "Fetching auction details"
        );

        let multicall = self
            .multicall
            .clear_calls()
            .add_call(balances_fn)
            .add_call(auction_fn)
            .add_call(self.flash_liquidator.is_at_minimal_price(vault_id))
            .add_call(self.flash_liquidator.collateral_to_debt_ratio(vault_id))
            ;

        let ((art, _), (auction_owner, auction_start), is_at_minimal_price, ratio_u256):
            ((u128, u128), (Address, u32), bool, U256) = multicall.call().await?;

        trace!(
            vault_id=?hex::encode(vault_id),
            debt=?art,
            ratio=?ratio_u256,
            is_at_minimal_price=is_at_minimal_price,
            "Fetched auction details"
        );

        let ratio_pct_u256 = ratio_u256 / U256::exp10(16);
        let ratio_pct: u16 = {
            if ratio_pct_u256 > U256::from(u16::MAX) {
                error!(vault_id=?vault_id, ratio_pct_u256=?ratio_pct_u256, "Ratio is too big");
                0
            } else {
                (ratio_pct_u256.as_u64()) as u16
            }
        };

        Ok(Auction {
            under_auction: (auction_owner != Address::zero()),
            started: auction_start,
            debt: art,
            ratio_pct: ratio_pct,
            is_at_minimal_price: is_at_minimal_price,
        })

    }
}
