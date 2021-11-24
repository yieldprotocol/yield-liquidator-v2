// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;


// @notice Something
interface IAddressRegistry {
    function addresses(bytes32 id) external returns (address contractName);
}
