/// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;


import "./FlashLiquidator.sol";
import "./IYvToken.sol";

/// @notice This is the Yield Flash liquidator contract for basic Yearn Vault tokens
/// @dev    This should only be used with basic Yearn Vault Tokens such as yvDAI and yvUSDC
///         and should not be used with something like yvcrvstEth which would require additional
///         logic to unwrap
contract YvBasicFlashLiquidator is FlashLiquidator {
    using TransferHelper for address;

    address public immutable DAI;  /// DAI contract address

    constructor(
        address _recipient,
        ISwapRouter _swapRouter,
        address _factory,
        address _WETH9,
        IWitch _witch,
        address DAI_
    ) FlashLiquidator(
        _recipient,
        _swapRouter,
        _factory,
        _WETH9,
        _witch
    ) {
        DAI = DAI_;
    }

    /// @notice This internal function is called to determine the other token used in the Flash pool
    /// @dev    Since we are only borrowing one token, the other token does not really matter as long
    ///         as the pool exists and has liquidity.  Since Uni does not have pools for Yearn Vault tokens,
    ///         we use WETH as the other token, unless the collateral is yvWETH in which case we use DAI
    /// @param  baseToken is the address of the series base in the vault being liquidated
    /// @param  collateral is the address of the ilk in the vault being liquidated
    /// @return otherToken address used to identify the other token in the pool besides the series base
    function _getOtherToken(address baseToken, address collateral) internal override view returns (address otherToken) {
        if (baseToken != WETH9) {
            otherToken = WETH9;
        } else {
            otherToken = DAI;
        }
    }

    /// @param fee0 The fee from calling flash for token0
    /// @param fee1 The fee from calling flash for token1
    /// @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    /// @notice implements the callback called from flash
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
        witch.payAll(decoded.vaultId, 0); /// collateral is paid in yvToken

        /// redeem the yvToken for underlying
        address underlyingAddress = IYvToken(decoded.collateral).token();
        require(underlyingAddress != address(0), "underlying not found");
        uint256 underlyingRedeemed = IYvToken(decoded.collateral).withdraw();  // defaults to max if no params passed

        uint256 debtRecovered;
        if (decoded.base == underlyingAddress) {
            debtRecovered = underlyingRedeemed;
        } else {
            ISwapRouter swapRouter_ = swapRouter;
            WETH9.safeApprove(address(swapRouter_), underlyingRedeemed);
            debtRecovered = swapRouter_.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: underlyingAddress,
                    tokenOut: decoded.base,
                    fee: 500,  /// can't use the same fee as the flash loan
                               /// because of reentrancy protection
                    recipient: address(this),
                    deadline: block.timestamp + 180,
                    amountIn: underlyingRedeemed,
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
