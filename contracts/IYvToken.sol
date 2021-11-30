// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

// @notice For use with Yield Flash Liquidator
interface IYvToken {
    // @dev Used to redeem yvTokens for underlying
    function withdraw() external returns (uint256);

    function token() external returns (address);
}
