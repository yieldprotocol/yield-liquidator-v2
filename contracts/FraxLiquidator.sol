// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import '@yield-protocol/utils-v2/contracts/token/IERC20.sol';
import './FlashLiquidator.sol';

// @notice This is the Flash liquidator contract for Frax
contract FraxFlashLiquidator is FlashLiquidator {
    using UniswapTransferHelper for address;
    using UniswapTransferHelper for IERC20;
    address public constant FRAX = 0x853d955aCEf822Db058eb8505911ED77F175b99e;

    constructor(
        IWitch witch_,
        address swapRouter_,
        IFlashLoan flashLoaner_
    ) FlashLiquidator(witch_, swapRouter_, flashLoaner_) {}

    // @dev Required to receive ETH from Curve
    receive() external payable {}

    // @notice flash loan callback, see IFlashLoanRecipient for details
    // @param tokens tokens loaned
    // @param amounts amounts of tokens loaned
    // @param feeAmounts flash loan fees
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) public override {
        require(liquidating && msg.sender == address(flashLoaner), 'baka');
        require(tokens.length == 1, '1 token expected');

        // decode, verify, and set debtToReturn
        FlashCallbackData memory decoded = abi.decode(userData, (FlashCallbackData));

        uint256 baseLoan = amounts[0];
        uint256 debtToReturn = baseLoan + feeAmounts[0];

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        // Sell collateral:
        address swapRouter_ = swapRouter02;
        IERC20(FRAX).approve(address(swapRouter_), collateralReceived);
        (bool ok, bytes memory swapReturnBytes) = swapRouter02.call(decoded.swapCalldata);
        require(ok, 'swap failed');

        uint256 debtRecovered;

        debtRecovered = IERC20(decoded.base).balanceOf(address(this));

        // if profitable pay profits to recipient
        if (debtRecovered > debtToReturn) {
            uint256 profit;
            unchecked {
                profit = debtRecovered - debtToReturn;
            }
            decoded.base.safeTransfer(decoded.recipient, profit);
        }
        // repay flash loan
        decoded.base.safeTransfer(msg.sender, debtToReturn);
    }
}
