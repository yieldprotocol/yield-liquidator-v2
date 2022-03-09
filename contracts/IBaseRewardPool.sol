// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

interface IBaseRewardPool {
    function withdraw(uint256 amount, bool claim) external returns (bool);
}
