// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;


// @notice Something
contract AddressRegistry {
    event AddressSet(bytes32 indexed contractName, address indexed contractAddress);

    mapping(bytes32 => address) public addresses; // registry of addresses of deployed Yield contracts

    // @notice This function sets addresses in the registry
    // @dev Won't replace/overwrite an address unless "replace" set to True
    // @param contractName Bytes representation of name of contract
    // @param contractAddress address of target contract
    // @param replace boolean flag to prevent inadvertant overwriting
    function setAddress(bytes32 contractName, address contractAddress, bool replace) external {
        if (!replace) {
            require(addresses[contractName] == address(0), "Address exists");
        }
        addresses[contractName] = contractAddress;
        emit AddressSet(contractName, contractAddress);
    }
}
