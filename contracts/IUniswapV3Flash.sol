// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

// File @uniswap/v3-core/contracts/interfaces/pool/IUniswapV3PoolActions.sol@v1.0.0

// @title This is based on IUniswapV3Permissionless pool actions because all we need is flash()
interface IUniswapV3Flash {
    // @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback
    // @dev The caller of this method receives a callback in the form of IUniswapV3FlashCallback#uniswapV3FlashCallback
    // @dev Can be used to donate underlying tokens pro-rata to currently in-range liquidity providers by calling
    // with 0 amount{0,1} and sending the donation amount(s) from the callback
    // @param recipient The address which will receive the token0 and token1 amounts
    // @param amount0 The amount of token0 to send
    // @param amount1 The amount of token1 to send
    // @param data Any data to be passed through to the callback
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}
