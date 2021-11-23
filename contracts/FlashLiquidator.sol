// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "@yield-protocol/utils-v2/contracts/interfaces/IWETH9.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/IWitch.sol";
import "./UniswapImports.sol";


/// @notice This is the standard Flash Liquidator contract used with Yield liquidator bots
contract FlashLiquidator is IUniswapV3FlashCallback, PeripheryImmutableState, PeripheryPayments {
    using TransferHelper for address;

    ISwapRouter public immutable swapRouter;
    ICauldron public immutable cauldron;
    IWitch public immutable witch;
    address public immutable recipient;

    struct FlashCallbackData {
        bytes12 vaultId;
        address base;
        address collateral;
        uint256 baseLoan;
        address baseJoin;
        PoolAddress.PoolKey poolKey;
    }

    constructor(
        address _recipient,
        ISwapRouter _swapRouter,
        address _factory,
        address _WETH9,
        IWitch _witch
    ) PeripheryImmutableState(_factory, _WETH9) {
        swapRouter = _swapRouter;
        witch = _witch;
        cauldron = _witch.cauldron();
        recipient = _recipient;
    }

    function collateralToDebtRatio(bytes12 vaultId) public
    returns (uint256) {
        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);

        if (balances.art == 0) {
            return 0;
        }
        /// The castings below can't overflow
        int256 accruedDebt = int256(uint256(cauldron.debtToBase(vault.seriesId, balances.art)));
        int256 level = cauldron.level(vaultId);
        int256 ratio = int256(uint256((cauldron.spotOracles(series.baseId, vault.ilkId)).ratio)) * 1e12; /// Convert from 6 to 18 decimals

        level = (level * 1e18) / (accruedDebt * ratio);
        require(level >= 0, "level is negative");
        return uint256(level);
    }

    function isAtMinimalPrice(bytes12 vaultId) public returns (bool) {
        bytes6 ilkId = (cauldron.vaults(vaultId)).ilkId;
        (uint32 duration, ) = witch.ilks(ilkId);
        (, uint32 auctionStart) = witch.auctions(vaultId);
        uint256 elapsed = uint32(block.timestamp) - auctionStart;
        return elapsed >= duration;
    }

    /// @param fee0 The fee from calling flash for token0
    /// @param fee1 The fee from calling flash for token1
    /// @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    /// @notice implements the callback called from flash
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external virtual override {
        /// we only borrow 1 token
        require(fee0 == 0 || fee1 == 0, "Two tokens were borrowed");
        uint256 fee = fee0 + fee1;

        /// decode and verify
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);

        /// liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        /// sell the collateral
        uint256 debtToReturn = decoded.baseLoan + fee;
        decoded.collateral.safeApprove(address(swapRouter), collateralReceived);
        uint256 debtRecovered = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: decoded.collateral,
                tokenOut: decoded.base,
                fee: 500,  /// can't use the same fee as the flash loan
                           /// because of reentrancy protection
                recipient: address(this),
                deadline: block.timestamp + 180,
                amountIn: collateralReceived,
                amountOutMinimum: debtToReturn,
                sqrtPriceLimitX96: 0
            })
        );

        /// if profitable pay profits to recipient
        if (debtRecovered > debtToReturn) {
            uint256 profit = debtRecovered - debtToReturn;
            pay(decoded.base, address(this), recipient, profit);
        }

        /// repay flash loan
        pay(decoded.base, address(this), msg.sender, debtToReturn);
    }

    /// @notice This internal function is called to determine the other token used in the Flash pool
    /// @dev    Since we are only borrowing one token, the other token does not really matter as long
    ///         as the pool exists and has liquidity.
    ///         Other contracts override this fn when there are no Uni pools for the underlying collateral
    /// @param  baseToken is the address of the series base in the vault being liquidated
    /// @param  collateral is the address of the ilk in the vault being liquidated
    /// @return otherToken address used to identify the other token in the pool besides the series base
    function _getOtherToken(address baseToken, address collateral) internal virtual returns (address otherToken) {
        return collateral;
    }

    /// @notice Liquidates a vault with help from a Uniswap v3 flash loan
    /// @param vaultId The id of the vault to liquidate
    function liquidate(bytes12 vaultId) external {
        uint24 poolFee = 3000; /// 0.3%

        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);
        address baseToken = cauldron.assets(series.baseId);
		uint128 baseLoan = cauldron.debtToBase(vault.seriesId, balances.art);
        address collateral = cauldron.assets(vault.ilkId);

        /// We are only borrowing one token, so the other token doesn't matter as long
        /// as the pool exists and has liquidity
        address otherToken = _getOtherToken(baseToken, collateral);

        /// tokens in PoolKey must be ordered
        bool ordered = (otherToken < baseToken);
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: ordered ? otherToken : baseToken,
            token1: ordered ? baseToken : otherToken,
            fee: poolFee
        });
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        /// data for the callback to know what to do
        FlashCallbackData memory args = FlashCallbackData({
            vaultId: vaultId,
            base: baseToken,
            collateral: collateral,
            baseLoan: baseLoan,
            baseJoin: address(witch.ladle().joins(series.baseId)),
            poolKey: poolKey
        });

        /// initiate flash loan, with the liquidation logic embedded in the flash loan callback
        pool.flash(
            address(this),
            ordered ? 0 : baseLoan,
            ordered ? baseLoan : 0,
            abi.encode(
                args
            )
        );
    }
}
