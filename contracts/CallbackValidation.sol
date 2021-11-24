// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "./IUniswapV3Pool.sol";
import "./PoolAddress.sol";


/// from 'uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol';
/// @notice Provides validation for callbacks from Uniswap V3 Pools
library CallbackValidation {
    /// @notice Returns the address of a valid Uniswap V3 Pool
    /// @param factory The contract address of the Uniswap V3 factory
    /// @param poolKey The identifying key of the V3 pool
    /// @return pool The V3 pool contract address
    function verifyCallback(address factory, PoolAddress.PoolKey memory poolKey)
        internal
        view
        returns (IUniswapV3Pool pool)
    {
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));
        require(msg.sender == address(pool), "Invalid caller");
    }
}

