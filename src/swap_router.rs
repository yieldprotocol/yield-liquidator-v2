//! Immutable data cache
//!

use async_process::Command;
use ethers::prelude::*;
use thiserror::Error;
use tracing::instrument;

use serde::Deserialize;

#[derive(Deserialize)]
struct RouterResult {
    data: String,
}

#[derive(Clone)]
pub struct SwapRouter {
    pub rpc_url: String,
    pub chain_id: u64,
    pub uni_router_02: Address,
    pub flash_liquidator: Address,
    pub router_binary_path: String,
    pub instance_name: String,
}

#[derive(Error, Debug)]
pub enum SwapRouterError {
    #[error("router error")]
    RouterError(String),
    #[error("unknown error")]
    Unknown,
}

pub struct SwapCalldata {
    pub calldata: Vec<u8>,
}

impl SwapRouter {
    /// Constructor
    pub fn new(
        rpc_url: String,
        chain_id: u64,
        uni_router_02: Address,
        flash_liquidator: Address,
        router_binary_path: String,
        instance_name: String,
    ) -> Self {
        SwapRouter {
            rpc_url,
            chain_id,
            uni_router_02,
            flash_liquidator,
            router_binary_path,
            instance_name,
        }
    }

    #[instrument(skip(self), fields(self.instance_name))]
    pub async fn build_swap_exact_out(
        &self,
        token_in: Address,
        token_out: Address,
        amount_in: U256,
    ) -> std::result::Result<SwapCalldata, SwapRouterError> {
        let out = Command::new(self.router_binary_path.as_str())
            .arg(format!("--rpc_url={}", self.rpc_url))
            .arg(format!("--chain_id={}", self.chain_id))
            .arg(format!("--from_address={:?}", self.flash_liquidator))
            .arg(format!("--token_in={:?}", token_in))
            .arg(format!("--token_out={:?}", token_out))
            .arg(format!("--amount_out={}", amount_in))
            .arg(format!("--silent"))
            .output()
            .await
            .map_err(|io_error| {
                SwapRouterError::RouterError(format!(
                    "Failed to call external router: {:}",
                    io_error
                ))
            })?;
        if out.status.success() {
            return stdout_to_swap(&out.stdout);
        } else {
            return Err(SwapRouterError::RouterError(format!(
                "Failed to call external router; exit code: {:?}; stderr: {:?}; stdout: {:?}",
                out.status.code(),
                String::from_utf8(out.stderr),
                String::from_utf8(out.stdout),
            )));
        }
    }
    /*
            uint256 debtRecovered = swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: decoded.collateral,
                    tokenOut: decoded.base,
                    fee: 3000,  // can't use the same fee as the flash loan
                               // because of reentrancy protection
                    recipient: address(this),
                    deadline: block.timestamp + 180,
                    amountIn: collateralReceived,
                    amountOutMinimum: debtToReturn, // bots will sandwich us and eat profits, we don't mind
                    sqrtPriceLimitX96: 0
                })
            );

    */
}

fn stdout_to_swap(stdout: &[u8]) -> std::result::Result<SwapCalldata, SwapRouterError> {
    let router_result: RouterResult = serde_json::from_slice(stdout).map_err(|e| {
        return SwapRouterError::RouterError(format!(
            "failed to deserialize json output: {:?}; output: {:?}",
            e,
            String::from_utf8(stdout.to_vec())
        ));
    })?;
    let calldata = hex::decode(&router_result.data[2..]).map_err(|e| {
        SwapRouterError::RouterError(format!("failed to deserialize hex calldata: {:?}", e))
    })?;
    return Ok(SwapCalldata { calldata });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[tokio::test]
    async fn swap_weth_for_usdc() {
        let sr = SwapRouter::new(
            "http://127.0.0.1:8545/".to_string(),
            1,
            Address::from_str("0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45").unwrap(),
            Address::zero(),
            "build/bin/router".to_string(),
            "".to_string(),
        );
        let maybe_swap = sr
            .build_swap_exact_out(
                Address::from_str("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2").unwrap(),
                Address::from_str("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48").unwrap(),
                U256::one(), //U256::from(10).pow(U256::from(18))
            )
            .await;
        // assert_eq!(maybe_swap.is_ok(), true);
        let swap = maybe_swap.unwrap();
        assert_eq!(swap.calldata.len() > 4, true, "calldata should be at least 4 bytes long");
    }
}
