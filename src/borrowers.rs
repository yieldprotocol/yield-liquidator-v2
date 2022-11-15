//! Borrowers / Users
//!
//! This module is responsible for keeping track of the users that have open
//! positions and observing their debt healthiness.
use crate::{
    bindings::Cauldron, bindings::IMulticall2, bindings::IMulticall2Call, bindings::IlkIdType,
    bindings::SeriesIdType, bindings::VaultIdType, bindings::Witch, Result, cache::ImmutableCache,
};

use ethers::prelude::*;
use futures_util::stream::{self, StreamExt};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc};
use tracing::{debug, debug_span, info, instrument, trace, warn};
use crate::bindings::ResultData;

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
    multicall2: IMulticall2<M>,
    multicall_batch_size: usize,

    instance_name: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
/// A vault's details
pub struct Vault {
    pub vault_id: VaultIdType,

    pub is_initialized: bool,

    pub is_collateralized: bool,

    pub under_auction: bool,

    pub level: I256,

    pub debt: u128,

    pub ilk_id: IlkIdType,

    pub series_id: SeriesIdType,
}

impl<M: Middleware> Borrowers<M> {
    /// Constructor
    pub async fn new(
        cauldron: Address,
        liquidator: Address,
        multicall2: Address,
        multicall_batch_size: usize,
        client: Arc<M>,
        vaults: HashMap<VaultIdType, Vault>,
        instance_name: String,
    ) -> Self {
        let multicall2 = IMulticall2::new(multicall2, client.clone());
        Borrowers {
            cauldron: Cauldron::new(cauldron, client.clone()),
            liquidator: Witch::new(liquidator, client),
            vaults,
            multicall2,
            multicall_batch_size,
            instance_name,
        }
    }

    /// Gets any new borrowers which may have joined the system since we last
    /// made this call and then proceeds to get the latest account details for
    /// each user
    #[instrument(skip(self, cache), fields(self.instance_name))]
    pub async fn update_vaults(&mut self, from_block: U64, to_block: U64, cache: &mut ImmutableCache<M>) -> Result<(), M> {
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
        info!(
            count = all_vaults.len(),
            instance_name = self.instance_name.as_str(),
            "Vaults collected"
        );

        self.get_vault_info(&all_vaults, cache)
            .await
            .iter()
            .zip(all_vaults)
            .for_each(|(vault_info, vault_id)| match vault_info {
                Ok(details) => {
                    if self.vaults.insert(vault_id, details.clone()).is_none() {
                        debug!(new_vault = ?hex::encode(vault_id), details=?details);
                    }
                }
                Err(x) => {
                    warn!(vault_id=?vault_id, err=?x, "Failed to get vault details");
                    self.vaults.insert(
                        vault_id,
                        Vault {
                            vault_id: vault_id,
                            is_initialized: false,
                            is_collateralized: false,
                            debt: 0,
                            level: I256::zero(),
                            under_auction: false,
                            series_id: [0, 0, 0, 0, 0, 0],
                            ilk_id: [0, 0, 0, 0, 0, 0],
                        },
                    );
                }
            });
        Ok(())
    }

    /// Fetches vault info for a set of vaults
    ///
    /// It relies on Multicall2 and does 2 levels of batching:
    ///     1. For each vault_id, there are 3 calls made
    ///     2. Calls for different vaults are batched together (self.multicall_batch_size is the batch size)
    /// If multicall_batch_size == 10 and we query 42 vaults, we will issue 5 separate Multicall2 calls
    /// First 4 multicalls will have multicall_batch_size * 3 == 40 internal calls
    /// Last multicall will have 2 * 3 = 6 internal calls
    ///
    #[instrument(skip(self, vault_ids, cache), fields(self.instance_name))]
    pub async fn get_vault_info(&mut self, vault_ids: &[VaultIdType], cache: &mut ImmutableCache<M>) -> Vec<Result<Vault, M>> {
        let mut ret: Vec<_> = stream::iter(vault_ids)
            // split to chunks
            .chunks(self.multicall_batch_size)
            // technicality: 'materialize' slices, so that the next step can be async
            .map(|x| x.iter().map(|a| **a).collect())
            // for each chunk, make a multicall2 call
            .then(|ids_chunk: Vec<VaultIdType>| async {
                let calls = self.get_vault_info_chunk_generate_multicall_args(&ids_chunk);
                let chunk_response = self.multicall2.try_aggregate(false, calls).call().await;

                match self.get_vault_info_chunk_parse_response(ids_chunk, chunk_response) {
                    Ok(response) => response,
                    Err(x) => {
                        // if the multicall itself failed, we panic and crash
                        // This is most likely to happen if the multicall runs out of gas (batch is too big)
                        // We can't ignore this error and can't fallback to fetching vaults one-by-one
                        // because it will be easy to miss the we start using the fallbacks
                        // So, we take the safe route of letting the operator adjust the batch size
                        panic!("multicall2 failed: {:?}", x)
                    }
                }
            })
            // glue back chunk responses
            .flat_map(|x| stream::iter(x))
            .collect()
            .await;

        // hack: for vaults that appear undercollaterized do another round of checks
        // if base == ilk, vaults are not liquidatable => we mark them as overcollaterized
        //
        for single_vault_maybe in &mut ret {
            if let Ok(single_vault) = single_vault_maybe {
                if !single_vault.is_collateralized {
                    info!(vault_id=?hex::encode(single_vault.vault_id), "Potentially undercollaterized vault - checking if it's trivial");
                    match cache.is_vault_ignored(single_vault.series_id, single_vault.ilk_id, single_vault.debt)
                        .await
                    {
                        Ok(true) => {
                            info!(vault_id=?hex::encode(single_vault.vault_id), "should be ignored - marking as NOT undercollaterized");
                            single_vault.is_collateralized = true;
                        }
                        Ok(false) => {
                            info!(vault_id=?hex::encode(single_vault.vault_id), "Is not ignorable");
                        }
                        Err(x) => {
                            warn!(vault_id=?hex::encode(single_vault.vault_id), "Failed to check if it's ignorable");
                            *single_vault_maybe = Err(x);
                        }
                    }
                }
            }
        }

        assert!(vault_ids.len() == ret.len());
        return ret;
    }

    /// Given a set of vaultIds, generate a Multicall2 call to get vault info
    fn get_vault_info_chunk_generate_multicall_args(
        &self,
        ids_chunk: &Vec<VaultIdType>,
    ) -> Vec<IMulticall2Call> {
        return ids_chunk
            .iter()
            .flat_map(|vault_id| {
                trace!(vault_id=?vault_id, "Getting vault info");
                let level_fn = self.cauldron.level(*vault_id);
                let balances_fn = self.cauldron.balances(*vault_id);
                let vault_data_fn = self.cauldron.vaults(*vault_id);
                let auction_id_fn = self.liquidator.auctions(*vault_id);

                return [
                    IMulticall2Call {
                        target: self.cauldron.address(),
                        call_data: level_fn.calldata().unwrap(),//level_fn.calldata().unwrap().to_vec(),
                    },
                    IMulticall2Call {
                        target: self.cauldron.address(),
                        call_data: balances_fn.calldata().unwrap(),
                    },
                    IMulticall2Call {
                        target: self.cauldron.address(),
                        call_data: vault_data_fn.calldata().unwrap(),
                    },
                    IMulticall2Call {
                        target: self.liquidator.address(),
                        call_data: auction_id_fn.calldata().unwrap(),
                    },
                ];
            })
            .collect();
    }

    /// Counterpart of get_vault_info_chunk_generate_multicall_args: given multicall response,
    /// convert it to a set of vaults
    fn get_vault_info_chunk_parse_response(
        &self,
        ids_chunk: Vec<VaultIdType>,                     // TODO borrow
        maybe_response: Result<Vec<ResultData>, M>, // TODO borrow
    ) -> Result<Vec<Result<Vault, M>>, M> {
        return maybe_response.map(|response| {
            assert!(
                response.len() == ids_chunk.len() * 4,
                "Unexpected results len: {}; expected: {}",
                response.len(),
                ids_chunk.len() * 4
            );
            let x: Vec<Result<Vault, M>> = response
                .chunks(4)
                .zip(ids_chunk)
                .map(|(single_vault_data, vault_id)| {
                    return self.get_vault_info_generate_vault(single_vault_data, &vault_id);
                })
                .collect();
            return x;
        });
    }

    /// Given individual responses from Multicall2, construct vault data
    fn get_vault_info_generate_vault(
        &self,
        single_vault_data: &[ResultData],
        vault_id: &VaultIdType,
    ) -> Result<Vault, M> {
        assert!(single_vault_data.len() == 4);
        let ResultData {success:level_data_ok, return_data:level_data} = &single_vault_data[0];
        let ResultData{success:balances_data_ok, return_data:balances_data} = &single_vault_data[1];
        let ResultData {success:vault_data_ok, return_data:vault_data} = &single_vault_data[2];
        let ResultData{success:auction_id_data_ok, return_data:auction_id_data} = &single_vault_data[3];
        if !level_data_ok || !balances_data_ok || !vault_data_ok || !auction_id_data_ok {
            warn!(vault_id=?hex::encode(vault_id), vault_data=?single_vault_data, "Failed to get vault data");
            return Err(ContractError::ConstructorError {});
        }
        use ethers::abi::Detokenize;
        let level_int = I256::from_tokens(
            self.cauldron
                .level(*vault_id)
                .function
                .decode_output(&level_data)
                .unwrap(),
        )?;
        let balances = <(u128, u128) as Detokenize>::from_tokens(
            self.cauldron
                .balances(*vault_id)
                .function
                .decode_output(&balances_data)
                .unwrap(),
        )?;
        let vault_data = <(Address, SeriesIdType, IlkIdType) as Detokenize>::from_tokens(
            self.cauldron
                .vaults(*vault_id)
                .function
                .decode_output(&vault_data)
                .unwrap(),
        )?;
        let auction_id = <(Address, u32) as Detokenize>::from_tokens(
            self.liquidator
                .auctions(*vault_id)
                .function
                .decode_output(&auction_id_data)
                .unwrap(),
        )?;

        let is_collateralized: bool = !level_int.is_negative();
        trace!(vault_id=?hex::encode(vault_id), "Got vault info");
        return Ok(Vault {
            vault_id: *vault_id,
            is_initialized: true,
            is_collateralized: is_collateralized,
            level: level_int,
            debt: balances.0,
            under_auction: auction_id.0 != Address::zero(),
            series_id: vault_data.1,
            ilk_id: vault_data.2,
        });
    }
}
