// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

// @notice For use with Yield Flash Liquidator to redeem yvTokens for underlying
interface IYvToken {
    function withdraw() external returns (uint256);
}
