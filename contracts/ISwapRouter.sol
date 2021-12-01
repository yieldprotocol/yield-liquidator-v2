// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

// File @uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol@v1.1.1

// @title Router token swapping functionality
// @notice Functions for swapping tokens via Uniswap V3
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    // @notice Swaps `amountIn` of one token for as much as possible of another token
    // @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    // @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
