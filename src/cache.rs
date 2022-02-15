//! Immutable data cache
//!
use crate::{
    bindings::{Cauldron}, bindings::{BaseIdType, IlkIdType, AssetIdType},
    bindings::SeriesIdType, Result,
};

use ethers::prelude::*;
use std::{collections::HashMap, sync::Arc};
use tracing::{debug, instrument, warn};


#[derive(Clone)]
pub struct ImmutableCache<M> {
    /// The cauldron smart contract
    pub cauldron: Cauldron<M>,

    pub series_to_base: HashMap<SeriesIdType, BaseIdType>,

    pub asset_id_to_address: HashMap<AssetIdType, Address>,

    pub base_to_debt_threshold: HashMap<BaseIdType, u128>,

    instance_name: String,
}

impl<M: Middleware> ImmutableCache<M> {
    /// Constructor
    pub async fn new(
        client: Arc<M>,
        cauldron: Address,
        series_to_base: HashMap<SeriesIdType, BaseIdType>,
        base_to_debt_threshold: HashMap<BaseIdType, u128>,
        instance_name: String,
    ) -> Self {
        ImmutableCache {
            cauldron: Cauldron::new(cauldron, client.clone()),
            series_to_base,
            asset_id_to_address: HashMap::new(),
            base_to_debt_threshold,
            instance_name
        }
    }

    #[instrument(skip(self), fields(self.instance_name))]
    pub async fn get_or_fetch_base_id(&mut self, series_id: SeriesIdType) -> Result<BaseIdType, M> {

        if !self.series_to_base.contains_key(&series_id) {
            debug!(series_id=?hex::encode(series_id), "fetching series");
            self.series_to_base.insert(series_id, self.cauldron.series(series_id).call().await?.1);
        }
        match self.series_to_base.get(&series_id) {
            Some(x) => Ok(*x),
            None => panic!("can't find data for series {:}", hex::encode(series_id))
        }
    }

    pub async fn get_or_fetch_asset_address(&mut self, asset_id: AssetIdType) -> Result<Address, M> {

        if !self.asset_id_to_address.contains_key(&asset_id) {
            debug!(asset_id=?hex::encode(asset_id), "fetching asset");
            self.asset_id_to_address.insert(asset_id, self.cauldron.assets(asset_id).call().await?);
        }
        match self.asset_id_to_address.get(&asset_id) {
            Some(x) => Ok(*x),
            None => panic!("can't find data for asset {:}", hex::encode(asset_id))
        }
    }


    #[instrument(skip(self), fields(self.instance_name))]
    pub async fn is_vault_ignored(&mut self, series_id: SeriesIdType, ilk_id: IlkIdType, debt: u128) -> Result<bool, M> {
        let base_id = match self.get_or_fetch_base_id(series_id).await {
            Ok(x) => x,
            Err(x) => return Err(x)
        };
        if base_id == ilk_id {
            debug!("vault is trivial");
            return Ok(true);
        }
        match self.base_to_debt_threshold.get(&base_id) {
            Some(threshold) => Ok(debt < *threshold),
            None => {
                warn!(series_id=?hex::encode(series_id), base_id=?hex::encode(base_id), "missing debt threshold");
                return Ok(false)
            }
        }
    }
}
