pub mod bindings;
pub mod borrowers;
pub mod cache;
pub mod escalator;
pub mod keeper;
pub mod liquidations;

use ethers::prelude::*;
use std::collections::HashMap;

/// "ETH-A" collateral type in hex, right padded to 32 bytes
pub const WETH: [u8; 32] = [
    0x45, 0x54, 0x48, 0x2d, 0x41, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00,
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00,
];

// merge & deduplicate the 2 data structs
pub fn merge<K:Clone + Ord, T>(a: Vec<K>, b: &HashMap<K, T>) -> Vec<K> {
    let keys = b.keys().cloned().collect::<Vec<_>>();
    let mut all = [a, keys].concat();
    all.sort_unstable();
    all.dedup();
    all
}

pub type Result<T, M> = std::result::Result<T, ContractError<M>>;
