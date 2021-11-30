// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;


import "./FlashLiquidator.sol";
import "./IYvToken.sol";

// @notice This is the Yield Flash liquidator contract for basic Yearn Vault tokens
// @dev    This should only be used with basic Yearn Vault Tokens such as yvDAI and yvUSDC
//         and should not be used with something like yvcrvstEth which would require additional
//         logic to unwrap
contract YvBasicFlashLiquidator is FlashLiquidator {
    using TransferHelper for address;

    constructor(
        address recipient_,
        IWitch witch_,
        address factory_,
        ISwapRouter swapRouter_
    ) FlashLiquidator(
        recipient_,
        witch_,
        factory_,
        swapRouter_
    ) {}

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
        CallbackValidation.verifyCallback(factory, decoded.poolKey);
        uint256 debtToReturn = decoded.baseLoan + fee;

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        witch.payAll(decoded.vaultId, 0); // collateral is paid in yvToken

        // redeem the yvToken for underlying
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
                    fee: 500,  // can't use the same fee as the flash loan
                               // because of reentrancy protection
                    recipient: address(this),
                    deadline: block.timestamp + 180,
                    amountIn: underlyingRedeemed,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // if profitable pay profits to recipient
        if (debtRecovered > debtToReturn) {
            uint256 profit = debtRecovered - debtToReturn;
            pay(decoded.base, address(this), recipient, profit);
        }

        // repay flash loan
        pay(decoded.base, address(this), msg.sender, debtToReturn);
    }
}
