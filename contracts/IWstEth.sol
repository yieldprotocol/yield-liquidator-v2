// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";

interface IWstEth is IERC20 {
    /**
     * @notice Exchanges wstEth to stEth
     * @param _wstEthAmount amount of wstEth to uwrap in exchange for stEth
     * @dev Requirements:
     *  - `_wstEthAmount` must be non-zero
     *  - msg.sender must have at least `_wstEthAmount` wstEth.
     * @return Amount of stEth user receives after unwrap
     */
    function unwrap(uint256 _wstEthAmount) external returns (uint256);
}
