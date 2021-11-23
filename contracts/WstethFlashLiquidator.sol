// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "./FlashLiquidator.sol";
import "./UniswapImports.sol";
import "./ICurveStableSwap.sol";
import "./IWstEth.sol";

/// @notice This is the Yield Flash liquidator contract for Lido Wrapped Staked Ether (WstEth)
contract WstethFlashLiquidator is FlashLiquidator {
    using TransferHelper for address;
    using TransferHelper for IWstEth;

    ICurveStableSwap public immutable curveSwap;  /// Curve stEth/Eth pool
    IWstEth public immutable wstEth;              /// Lido wrapped stEth contract address
    address public immutable stEth;               /// stEth contract address
    address public immutable DAI;                 /// stEth contract address

    /// @notice An event for whenever Eth is received
    /// @dev    This should happen whenever stEth is swapped for Eth on Curve
    event EthReceived(address indexed guy, uint256 amount);

    constructor(
        address recipient_,
        ISwapRouter swapRouter_,
        address factory_,
        address WETH9_,
        IWitch witch_,
        ICurveStableSwap curveSwap_,
        IWstEth wstEth_,
        address stEth_,
        address DAI_
    ) FlashLiquidator(
        recipient_,
        swapRouter_,
        factory_,
        WETH9_,
        witch_
    ) {
        curveSwap = curveSwap_;
        wstEth = wstEth_;
        stEth = stEth_;
        DAI = DAI_;
    }

    /// @dev Overrides PeripheryPayments.receive
    receive() external override payable {
        emit EthReceived(msg.sender, msg.value);
    }

    /// @notice This internal function is called to determine the other token used in the Flash pool
    /// @dev    Since we are only borrowing one token, the other token does not really matter as long
    ///         as the pool exists and has liquidity.  Since Uni does not have a pool for WstEth,
    ///         we use WETH as the other token, unless the collateral is WETH in which case we use DAI
    /// @param  baseToken is the address of the series base in the vault being liquidated
    /// @param  collateral is the address of the ilk in the vault being liquidated
    /// @return otherToken address used to identify the other token in the pool besides the series base
    function _getOtherToken(address baseToken, address collateral) internal override view returns (address otherToken) {
        require(collateral == address(wstEth), "not wstEth");
        if (baseToken != WETH9) {
            otherToken = WETH9;
        } else {
            otherToken = DAI;
        }
    }

    /// @param fee0 The fee from calling flash for token0
    /// @param fee1 The fee from calling flash for token1
    /// @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    /// @notice     implements the callback called from flash
    /// @dev        Unlike the other Yield FlashLiquidator contracts, this contains extra steps to
    ///             unwrap wstEth and swap it for Eth on Curve before Uniswapping it for base
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        /// we only borrow 1 token
        require(fee0 == 0 || fee1 == 0, "Two tokens were borrowed");
        uint256 fee = fee0 + fee1;

        /// decode, verify, and set debtToReturn
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);
        uint256 debtToReturn = decoded.baseLoan + fee;

        /// liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        /// Sell collateral:

        /// Step 1 - unwrap wstEth => stEth
        uint256 unwrappedStEth = wstEth.unwrap(collateralReceived);

        /// Step 2 - swap stEth for Eth on Curve
        stEth.safeApprove(address(curveSwap), unwrappedStEth);
        uint256 ethReceived = curveSwap.exchange(1, 0, unwrappedStEth, 0);

        /// Step 3 -  wrap the Eth => Weth
        IWETH9(WETH9).deposit{value: ethReceived}();

        /// Step 4 - if necessary, swap Weth for base on UniSwap
        uint256 debtRecovered;
        if (decoded.base == WETH9) {
            debtRecovered = ethReceived;
        } else {
            ISwapRouter swapRouter_ = swapRouter;
            WETH9.safeApprove(address(swapRouter_), ethReceived);
            debtRecovered = swapRouter_.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: WETH9,
                    tokenOut: decoded.base,
                    fee: 500,  /// can't use the same fee as the flash loan
                               /// because of reentrancy protection
                    recipient: address(this),
                    deadline: block.timestamp + 180,
                    amountIn: ethReceived,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        /// if profitable pay profits to recipient
        if (debtRecovered > debtToReturn) {
            uint256 profit = debtRecovered - debtToReturn;
            pay(decoded.base, address(this), recipient, profit);
        }

        /// repay flash loan
        pay(decoded.base, address(this), msg.sender, debtToReturn);
    }
}
