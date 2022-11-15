//! Auctions Module
//!
//! This module is responsible for triggering and participating in a Auction's
//! dutch auction
use crate::{
    bindings::{Cauldron, Witch, VaultIdType, FlashLiquidator, BaseIdType, IlkIdType},
    borrowers::{Vault},
    escalator::GeometricGasPrice,
    merge, Result, cache::ImmutableCache, swap_router::SwapRouter,
};

use ethers_core::types::transaction::eip2718::TypedTransaction;

use ethers::{
    prelude::*,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, fmt, ops::Mul, sync::Arc, time::{Instant, SystemTime}, convert::TryInto};
use tracing::{debug, debug_span, error, info, trace, warn, instrument};

pub type AuctionMap = HashMap<VaultIdType, bool>;

use std::ops::Div;


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

    // uniswap swap router
    swap_router: SwapRouter,

    /// The minimum ratio (collateral/debt) to trigger liquidation
    min_ratio: u16,

    // extra gas to use for txs, as percent of estimated gas cost
    gas_boost: u16,

    // buy an auction when this percentage of collateral is released
    target_collateral_offer: u16,

    pending_liquidations: HashMap<VaultIdType, PendingTransaction>,
    pending_auctions: HashMap<VaultIdType, PendingTransaction>,
    gas_escalator: GeometricGasPrice,
    bump_gas_delay: u64,

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

    base_id: BaseIdType,
    
    ilk_id: IlkIdType,

    ratio_pct: u16,
    collateral_offer_is_good_enough: bool,
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
        swap_router: SwapRouter,
        cauldron: Address,
        liquidator: Address,
        flashloan: Address,
        multicall: Option<Address>,
        min_ratio: u16,
        gas_boost: u16,
        target_collateral_offer: u16,
        client: Arc<M>,
        auctions: AuctionMap,
        gas_escalator: GeometricGasPrice,
        bump_gas_delay: u64,
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
            swap_router,
            min_ratio,
            gas_boost,
            target_collateral_offer,
            auctions,

            pending_liquidations: HashMap::new(),
            pending_auctions: HashMap::new(),
            gas_escalator,
            bump_gas_delay,
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
        Liquidator::remove_or_bump_inner(now, &liquidator_client, &self.gas_escalator,
            &mut self.pending_liquidations, "liquidations",
            self.instance_name.as_ref(),
            self.bump_gas_delay).await;
        Liquidator::remove_or_bump_inner(now, &liquidator_client, &self.gas_escalator,
            &mut self.pending_auctions, "auctions",
            self.instance_name.as_ref(),
            self.bump_gas_delay).await;

        Ok(())
    }

    async fn remove_or_bump_inner<K: Clone + Eq + ::std::hash::Hash + std::fmt::Debug>(
        now: Instant,
        client: &M,
        gas_escalator: &GeometricGasPrice,
        pending_txs: &mut HashMap<K, PendingTransaction>,
        tx_type: &str,
        instance_name: &str,
        bump_gas_delay: u64
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
                let time_since = now.duration_since(instant).as_secs();
                if time_since > bump_gas_delay {
                    info!(tx_hash = ?tx_hash, "Bumping gas");
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
                        // it should be reversed:
                        // - max_fee_per_gas has to be constant
                        // - max_priority_fee_per_gas needs to be bumped
                        x.max_fee_per_gas = Some(new_gas_price);
                        x.max_priority_fee_per_gas = Some(U256::from(2000000000)); // 2 gwei
                    } else {
                        panic!("Non-Eip1559 transactions are not supported yet");
                    }

                    // rebroadcast
                    match client
                        .send_transaction(replacement_tx.0.clone(), None)
                        .await {
                            Ok(tx) => {
                                replacement_tx.1 = *tx;
                            },
                            Err(x) => {
                                error!(tx=?replacement_tx, err=?x, "Failed to replace transaction: dropping it");
                                pending_txs.remove(&addr);
                            }
                        }

                    info!(tx_hash = ?tx_hash, new_gas_price = %new_gas_price, user = ?addr,
                        tx_type, instance_name, "Bumping gas: done");
                    } else {
                        info!(tx_hash = ?tx_hash, time_since, bump_gas_delay, instance_name, "Bumping gas: too early");
                    }
            }
        }

        Ok(())
    }

    /// Sends a bid for any of the liquidation auctions.
    #[instrument(skip(self, from_block, to_block, cache), fields(self.instance_name))]
    pub async fn buy_opportunities(
        &mut self,
        from_block: U64,
        to_block: U64,
        gas_price: U256,
        cache: &mut ImmutableCache<M>
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
            match self.buy(vault_id, Instant::now(), gas_price, cache).await {
                Ok(is_still_valid) => {
                    if !is_still_valid {
                        info!(vault_id=?hex::encode(vault_id), instance_name=self.instance_name.as_str(), "Removing no longer valid auction");
                        self.auctions.remove(&vault_id);
                    }        
                }
                Err(x) => {
                    error!(vault_id=?hex::encode(vault_id), instance_name=self.instance_name.as_str(), 
                        error=?x, "Failed to buy");
                }
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
    #[instrument(skip(self, cache), fields(self.instance_name))]
    async fn buy(&mut self, vault_id: VaultIdType, now: Instant, gas_price: U256,
        cache: &mut ImmutableCache<M>) -> Result<bool, M> {
        // only iterate over users that do not have active auctions
        if let Some(pending_tx) = self.pending_auctions.get(&vault_id) {
            trace!(tx_hash = ?pending_tx.1, vault_id=?vault_id, "bid not confirmed yet");
            return Ok(true);
        }

        // Get the vault's info
        let auction = match self.get_auction(vault_id, cache).await {
            Ok(Some(x)) => x,
            Ok(None) => {
                // auction is not valid
                return Ok(false);
            }
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
        if auction.collateral_offer_is_good_enough {
            info!(vault_id=?hex::encode(vault_id), auction=?auction,
                ratio=auction.ratio_pct, ratio_threshold=self.min_ratio,
                instance_name=self.instance_name.as_str(),
                "Collateral offer is good enough, buying");
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

        let maybe_calldata = self.swap_router.build_swap_exact_out(
            cache.get_or_fetch_asset_address(auction.ilk_id).await?, // in: collateral
            cache.get_or_fetch_asset_address(auction.base_id).await?, // out:debt
            U256::from(auction.debt)
        ).await;
        if let Err(x) = maybe_calldata {
            warn!(vault_id=?hex::encode(vault_id), err=?x, "failed to generate swap calldata - will try later");
            return Ok(true);
        }
        let swap_calldata = maybe_calldata.unwrap().calldata;

        let raw_call = self.flash_liquidator.liquidate(vault_id, swap_calldata.into())
            // explicitly set 'from' field because we're about to call `estimate_gas`
            // If there's no `from` set, the estimated transaction is sent from 0x0 and reverts (tokens can't be transferred there)
            //
            // Also, it's safe to unwrap() client().default_sender(): if it's not set, we're in trouble anyways
            .from(self.flash_liquidator.client().default_sender().unwrap());
        let gas_estimation = raw_call.estimate_gas().await?;
        let gas = gas_estimation.mul(U256::from(self.gas_boost + 100)).div(100);
        let call = raw_call
            .gas_price(gas_price)
            .gas(gas);

        let tx = call.tx.clone();

        match call.send().await {
            Ok(hash) => {
                // record the tx
                info!(tx_hash = ?hash,
                    vault_id = ?hex::encode(vault_id),
                    instance_name=self.instance_name.as_str(),
                    gas=?gas,
                    "Submitted buy order");
                self.pending_auctions
                    .entry(vault_id)
                    .or_insert((tx, *hash, now));
            }
            Err(err) => {
                let err = err.to_string();
                error!("Buy error: {}; data: {:?}", err, call.calldata());
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
                        info!(tx_hash = ?tx_hash,
                            vault_id = ?hex::encode(vault_id), 
                            instance_name=self.instance_name.as_str(), "Submitted liquidation");
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
                debug!(vault_id=?hex::encode(vault_id), "Vault is collateralized/ignored");
            }
        }
        Ok(())
    }

    fn current_offer(&self, now: u64, auction_start: u64, duration: u64, initial_offer: u64) -> Result<u16, M> {
        if now < auction_start.into() {
            return Err(ContractError::ConstructorError{});
        }
        let one = 10u64.pow(18);
        if initial_offer > one {
            error!(initial_offer, "initialOffer > 1");
            return Err(ContractError::ConstructorError{});
        }
        let initial_offer_pct = initial_offer / 10u64.pow(16); // 0-100

        let time_since_auction_start: u64 = now - auction_start;
        if time_since_auction_start >= duration {
            Ok(100)
        } else {
            // time_since_auction_start / duration * (1 - initial_offer) + initial_offer
            Ok((time_since_auction_start * (100 - initial_offer_pct) / duration + initial_offer_pct).try_into().unwrap())
        }
    }

    async fn get_auction(&mut self, vault_id: VaultIdType, cache: &mut ImmutableCache<M>) -> Result<Option<Auction>, M> {
        let (_, series_id, ilk_id) = self.cauldron.vaults(vault_id).call().await?;
        let balances_fn = self.cauldron.balances(vault_id);
        let auction_fn = self.liquidator.auctions(vault_id);

        trace!(
            vault_id=?hex::encode(vault_id),
            "Fetching auction details"
        );

        let multicall = self
            .multicall
            .clear_calls()
            .add_call(balances_fn,true)
            .add_call(auction_fn,true)
            .add_call(self.liquidator.ilks(ilk_id),true)
            .add_call(self.flash_liquidator.collateral_to_debt_ratio(vault_id),true)
            ;

        let ((art, _), (auction_owner, auction_start), (duration, initial_offer), ratio_u256):
            ((u128, u128), (Address, u32), (u32, u64), U256) = multicall.call().await.unwrap();

        if cache.is_vault_ignored(series_id, ilk_id, art).await? {
            info!(vault_id=?hex::encode(vault_id), "vault is trivial or ignored - not auctioning");
            return Ok(None);
        }
        let current_offer: u16 = 
            match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
                    Ok(x) => self.current_offer(x.as_secs(), 
                    u64::from(auction_start), 
                    u64::from(duration), initial_offer)
                        .unwrap_or(0),
                    Err(x) => {
                        error!("Failed to get system time: {}", x);
                        0u16
                    }
                };

        trace!(
            vault_id=?hex::encode(vault_id),
            debt=?art,
            ratio=?ratio_u256,
            current_offer=current_offer,
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

        Ok(Some(Auction {
            under_auction: (auction_owner != Address::zero()),
            started: auction_start,
            debt: art,
            ratio_pct: ratio_pct,
            base_id: cache.get_or_fetch_base_id(series_id).await?,
            ilk_id: ilk_id,
            collateral_offer_is_good_enough: current_offer >= self.target_collateral_offer,
        }))

    }
}
