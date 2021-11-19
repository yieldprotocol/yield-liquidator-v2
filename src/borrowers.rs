//! Borrowers / Users
//!
//! This module is responsible for keeping track of the users that have open
//! positions and observing their debt healthiness.
use crate::{bindings::Cauldron, bindings::Witch, bindings::VaultIdType, bindings::ArtIdType, bindings::InkIdType, Result};

use ethers::prelude::*;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};
use tracing::{debug, debug_span, trace, warn, info, instrument};

pub type VaultMap = HashMap<VaultIdType, Vault>;

#[derive(Clone)]
pub struct Borrowers<M> {
    /// The cauldron smart contract
    pub cauldron: Cauldron<M>,
    pub liquidator: Witch<M>,

    /// Mapping of the addresses that have taken loans from the system and might
    /// be susceptible to liquidations
    pub vaults: VaultMap,

    /// We use multicall to batch together calls and have reduced stress on
    /// our RPC endpoint
    multicall: Multicall<M>,

    instance_name: String
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
/// A vault's details
pub struct Vault {
    pub is_initialized: bool,

    pub is_collateralized: bool,

    pub under_auction: bool,

    pub level: I256,

    pub ink: InkIdType,

    pub art: ArtIdType,
}

impl<M: Middleware> Borrowers<M> {
    /// Constructor
    pub async fn new(
        cauldron: Address,
        liquidator: Address,
        multicall: Option<Address>,
        client: Arc<M>,
        vaults: HashMap<VaultIdType, Vault>,
        instance_name: String
    ) -> Self {
        let multicall = Multicall::new(client.clone(), multicall)
            .await
            .expect("could not initialize multicall");
        Borrowers {
            cauldron: Cauldron::new(cauldron, client.clone()),
            liquidator: Witch::new(liquidator, client),
            vaults,
            multicall,
            instance_name
        }
    }

    /// Gets any new borrowers which may have joined the system since we last
    /// made this call and then proceeds to get the latest account details for
    /// each user
    #[instrument(skip(self), fields(self.instance_name))]
    pub async fn update_vaults(&mut self, from_block: U64, to_block: U64) -> Result<(), M> {
        let span = debug_span!("monitoring");
        let _enter = span.enter();

        // get the new vaults
        // TODO: Improve this logic to be more optimized
        let new_vaults = self
            .cauldron
            .vault_poured_filter()
            .from_block(from_block)
            .to_block(to_block)
            .query()
            .await?
            .into_iter()
            .map(|x| x.vault_id)
            .collect::<Vec<_>>();

        if new_vaults.len() > 0 {
            debug!("New vaults: {}", new_vaults.len());
        } else {
            trace!("New vaults: {}", new_vaults.len());
        }

        let all_vaults = crate::merge(new_vaults, &self.vaults);
        info!(count=all_vaults.len(), instance_name=self.instance_name.as_str(), "Vaults collected");

        // update all the accounts' details
        for vault_id in all_vaults {
            match self.get_vault_info(vault_id).await {
                Ok(details) => {
                    if self.vaults.insert(vault_id, details.clone()).is_none() {
                        debug!(new_vault = ?vault_id, details=?details);
                    }
                }
                Err(x) => {
                    warn!(vault_id=?vault_id, err=?x, "Failed to get vault details");
                    self.vaults.insert(vault_id, Vault {
                        is_initialized: false,
                        is_collateralized: false,
                        level: I256::zero(),
                        under_auction: false,
                        art: [0, 0, 0, 0, 0, 0],
                        ink: [0, 0, 0, 0, 0, 0]
                    });
                }
            }
        }

        Ok(())
    }

    /// Updates the vault info
    /// 
    #[instrument(skip(self), fields(self.instance_name))]
    pub async fn get_vault_info(&mut self, vault_id: VaultIdType) -> Result<Vault, M> {
        trace!(vault_id=?vault_id, "Getting vault info");
        let level_fn = self.cauldron.level(vault_id);
        let vault_data_fn = self.cauldron.vaults(vault_id);
        let auction_id_fn = self.liquidator.auctions(vault_id);

        // batch the calls together
        let multicall = self
            .multicall
            .clear_calls()
            .add_call(level_fn)
            .add_call(vault_data_fn)
            .add_call(auction_id_fn);

        match multicall.call::<(I256, (Address, ArtIdType, InkIdType), (Address, u32))>().await {
            Ok((level_int, vault_data, auction_id)) => {
                let is_collateralized: bool = !level_int.is_negative();
                trace!(vault_id=?hex::encode(vault_id), "Got vault info");

                Ok(Vault {
                    is_initialized: true,
                    is_collateralized: is_collateralized,
                        level: level_int,
                        under_auction: auction_id.0 != Address::zero(),
                        art: vault_data.1,
                        ink: vault_data.2
                    })
            }
            Err(x) => {
                Err(x)
            }
        }
    }
}
