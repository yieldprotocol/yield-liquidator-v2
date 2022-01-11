// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;


import "./FlashLiquidator.sol";
import "@yield-protocol/vault-v2/contracts/oracles/yearn/IYvToken.sol";

// @notice This is the Yield Flash liquidator contract for basic Yearn Vault tokens
// @dev    This should only be used with basic Yearn Vault Tokens such as yvDAI and yvUSDC
//         and should not be used with something like yvcrvstEth which would require additional
//         logic to unwrap
contract YvBasicFlashLiquidator is FlashLiquidator {
    using UniswapTransferHelper for address;

    constructor(
        IWitch witch_,
        address factory_,
        ISwapRouter swapRouter_
    ) FlashLiquidator(
        witch_,
        factory_,
        swapRouter_
    ) {}

    // @param fee0 The fee from calling flash for token0
    // @param fee1 The fee from calling flash for token1
    // @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    // @notice     implements the callback called from flash
    // @dev        Unlike the other Yield FlashLiquidator contracts, this contains extra steps to
    //             unwrap basic yvTokens (yvDai and yvUSDC)
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        // we only borrow 1 token
        require(fee0 == 0 || fee1 == 0, "Two tokens were borrowed");
        uint256 fee;
        unchecked {
            // Since one fee is always zero, this won't overflow
            fee = fee0 + fee1;
        }

        // decode, verify, and set debtToReturn
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        _verifyCallback(decoded.poolKey);
        uint256 debtToReturn = decoded.baseLoan + fee;

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        witch.payAll(decoded.vaultId, 0); // collateral is paid in yvToken

        // redeem the yvToken for underlying
        address underlyingAddress = IYvToken(decoded.collateral).token();
        require(underlyingAddress != address(0), "underlying not found");
        uint256 underlyingRedeemed = IYvToken(decoded.collateral).withdraw(); // defaults to max if no params passed

        uint256 debtRecovered;
        if (decoded.base == underlyingAddress) {
            debtRecovered = underlyingRedeemed;
        } else {
            ISwapRouter swapRouter_ = swapRouter;
            decoded.collateral.safeApprove(address(swapRouter), underlyingRedeemed);
            debtRecovered = swapRouter_.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: underlyingAddress,
                    tokenOut: decoded.base,
                    fee: 500,  // can't use the same fee as the flash loan
                               // because of reentrancy protection
                    recipient: address(this),
                    deadline: block.timestamp + 180,
                    amountIn: underlyingRedeemed,
                    amountOutMinimum: debtToReturn, // bots will sandwich us and eat profits, we don't mind
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
            decoded.base.safeTransfer(decoded.recipient, profit);
        }
        // repay flash loan
        decoded.base.safeTransfer(msg.sender, debtToReturn);
    }

}
