// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "./FlashLiquidator.sol";
import "./ICurveStableSwap.sol";
import "./IWstEth.sol";

// @notice This is the Yield Flash liquidator contract for Lido Wrapped Staked Ether (WstEth)
contract WstethFlashLiquidator is FlashLiquidator {
    using TransferHelper for address;
    using TransferHelper for IWstEth;

    ICurveStableSwap public immutable curveSwap;  // Curve stEth/Eth pool
    IWstEth public immutable wstEth;              // Lido wrapped stEth contract address
    address public immutable stEth;               // stEth contract address

    constructor(
        address recipient_,
        IWitch witch_,
        address factory_,
        ISwapRouter swapRouter_,

        ICurveStableSwap curveSwap_,
        address stEth_,
        IWstEth wstEth_
    ) FlashLiquidator(
        recipient_,
        witch_,
        factory_,
        swapRouter_
    ) {
        curveSwap = curveSwap_;
        stEth = stEth_;
        wstEth = wstEth_;
    }

    // @dev Overrides PeripheryPayments.receive -> noop
    receive() external payable {}

    // @param fee0 The fee from calling flash for token0
    // @param fee1 The fee from calling flash for token1
    // @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    // @notice     implements the callback called from flash
    // @dev        Unlike the other Yield FlashLiquidator contracts, this contains extra steps to
    //             unwrap wstEth and swap it for Eth on Curve before Uniswapping it for base
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        // we only borrow 1 token
        require(fee0 == 0 || fee1 == 0, "Two tokens were borrowed");
        uint256 fee = fee0 + fee1;

        // decode, verify, and set debtToReturn
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        _verifyCallback(decoded.poolKey);
        uint256 debtToReturn = decoded.baseLoan + fee;

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        // Sell collateral:

        // Step 1 - unwrap wstEth => stEth
        uint256 unwrappedStEth = wstEth.unwrap(collateralReceived);

        // Step 2 - swap stEth for Eth on Curve
        stEth.safeApprove(address(curveSwap), unwrappedStEth);
        uint256 ethReceived = curveSwap.exchange(1, 0, unwrappedStEth, 0);

        // Step 3 -  wrap the Eth => Weth
        IWETH9(WETH).deposit{value: ethReceived}();

        // Step 4 - if necessary, swap Weth for base on UniSwap
        uint256 debtRecovered;
        if (decoded.base == WETH) {
            debtRecovered = ethReceived;
        } else {
            ISwapRouter swapRouter_ = swapRouter;
            WETH.safeApprove(address(swapRouter_), ethReceived);
            debtRecovered = swapRouter_.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: decoded.base,
                    fee: 500,  // can't use the same fee as the flash loan
                               // because of reentrancy protection
                    recipient: address(this),
                    deadline: block.timestamp + 180,
                    amountIn: ethReceived,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // if profitable pay profits to recipient
        if (debtRecovered > debtToReturn) {
            uint256 profit;
            unchecked {
                profit = debtRecovered - debtToReturn;
            }
            decoded.base.safeTransfer(recipient, profit);
        }
        // repay flash loan
        decoded.base.safeTransfer(msg.sender, debtToReturn);
    }
}
