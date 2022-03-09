// 3CRV: https://etherscan.io/address/0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490
// Convex deposit contract: https://etherscan.io/address/0x689440f2Ff927E1f24c72F1087E1FAF471eCe1c8
// cvx3CRV: https://etherscan.io/address/0x30d9410ed1d5da1f6c8391af5338c93ab8d4035c

// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import '@yield-protocol/utils-v2/contracts/token/IERC20.sol';
import './FlashLiquidator.sol';
import './ICurveStableSwap.sol';
import './IWstEth.sol';
import './IBaseRewardPool.sol';

// @notice This is the Yield Flash liquidator contract for Lido Wrapped Staked Ether (WSTETH)
contract Cvx3CrvFlashLiquidator is FlashLiquidator {
    using UniswapTransferHelper for address;
    using UniswapTransferHelper for IWstEth;
    using UniswapTransferHelper for IERC20;

    address public constant BASE_REWARD_POOL = 0x689440f2Ff927E1f24c72F1087E1FAF471eCe1c8;
    address public constant THREECRV = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;
    address public constant USDC = 0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490;

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
    // @dev        Unlike the other Yield FlashLiquidator contracts, this contains extra steps to
    //             unwrap WSTETH and swap it for Eth on Curve before Uniswapping it for base
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

        // Step 1 - unwrap CVX3CRV => 3CRV
        bool threeCRVReceived = IBaseRewardPool(BASE_REWARD_POOL).withdraw(collateralReceived, false); // What needs to be done for the reward??

        if (threeCRVReceived) {
            // Step 2 - swap 3CRV => WETH/USDC/DAI
            address swapRouter_ = swapRouter02;
            IERC20(THREECRV).approve(address(swapRouter_), collateralReceived);
            (bool ok, bytes memory swapReturnBytes) = swapRouter02.call(decoded.swapCalldata);
            require(ok, 'swap failed');

            uint256 debtRecovered;

            if (decoded.base == WETH) {
                debtRecovered = IERC20(WETH).balanceOf(address(this));
            } else if (decoded.base == DAI) {
                debtRecovered = IERC20(DAI).balanceOf(address(this));
            } else {
                // USDC
                debtRecovered = IERC20(USDC).balanceOf(address(this));
            }

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
}
