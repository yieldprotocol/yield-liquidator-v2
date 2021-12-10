// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import '@yield-protocol/utils-v2/contracts/interfaces/IWETH9.sol';

// File @uniswap/v3-periphery/contracts/libraries/TransferHelper.sol@v1.1.1
//
library UniswapTransferHelper {
    // @notice Transfers tokens from msg.sender to a recipient
    // @dev Errors with ST if transfer fails
    // @param token The contract address of the token which will be transferred
    // @param to The recipient of the transfer
    // @param value The value of the transfer
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'ST');
    }

    // @notice Approves the stipulated contract to spend the given allowance in the given token
    // @dev Errors with "SA" if transfer fails
    // @param token The contract address of the token to be approved
    // @param to The target of the approval
    // @param value The amount of the given token the target will be allowed to spend
    function safeApprove(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'SA');
    }
}
