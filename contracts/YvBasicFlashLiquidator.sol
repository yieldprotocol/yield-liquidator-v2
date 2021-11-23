// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "@yield-protocol/utils-v2/contracts/interfaces/IWETH9.sol";
import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/IWitch.sol";
import "./UniswapImports.sol";
import "./IYvToken.sol";

// @notice This should only be used with basic Yearn Vault Tokens such as yvDAI and yvUSDC
//         and should not be used with something like yvcrvstEth which would require additional
//         logic to unwrap
// TODO: Rename this file and contract FlashLiquidatorYearnVaultBasic.sol
// For now, we use the old name for initial code review to clearly show diff from the original contract
contract YvBasicFlashLiquidator is IUniswapV3FlashCallback, PeripheryImmutableState, PeripheryPayments {
    using TransferHelper for address;

    // @notice Emitted when a new underlying is mapped to the corresponding Yearn Vault token
    // @param underlying Address of the underlying token (e.g. USDC)
    // @param yvToken Address of the Yearn Vault token (e.g. yvUSDC)
    event UnderlyingSet(
        address indexed yvToken,
        address indexed underlying
    );

    ISwapRouter public immutable swapRouter;
    ICauldron public immutable cauldron;
    IWitch public immutable witch;
    address public immutable recipient;
    mapping (address => address) public yvToUnderlying; // Yearn Vault token addresses to addresses of underlying tokens

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

    function setUnderlyingAddress(address yvToken, address underlying) external {
        yvToUnderlying[yvToken] = underlying;
        emit UnderlyingSet(yvToken, underlying);(yvToken, underlying);
    }

    function collateralToDebtRatio(bytes12 vaultId) public
    returns (uint256) {
        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);

        if (balances.art == 0) {
            return 0;
        }
        // The castings below can't overflow
        int256 accruedDebt = int256(uint256(cauldron.debtToBase(vault.seriesId, balances.art)));
        int256 level = cauldron.level(vaultId);
        int256 ratio = int256(uint256((cauldron.spotOracles(series.baseId, vault.ilkId)).ratio)) * 1e12; // Convert from 6 to 18 decimals

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

    // @param fee0 The fee from calling flash for token0
    // @param fee1 The fee from calling flash for token1
    // @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    // @notice implements the callback called from flash
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external override {
        // we only borrow 1 token
        require(fee0 == 0 || fee1 == 0, "Two tokens were borrowed");
        uint256 fee = fee0 + fee1;

        // decode and verify
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);
        address underlyingAddress = yvToUnderlying[decoded.collateral];
        require(underlyingAddress != address(0), "Underlying not set");

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0); // collateral is yvToken

        // redeem the yvToken for underlying
        uint256 underlyingRedeemed = IYvToken(decoded.collateral).withdraw();

        // sell the collateral
        uint256 debtToReturn = decoded.baseLoan + fee;
        decoded.collateral.safeApprove(address(swapRouter), collateralReceived);
        uint256 debtRecovered = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: underlyingAddress,
                tokenOut: decoded.base,
                fee: 500,  // can't use the same fee as the flash loan
                           // because of reentrancy protection
                recipient: address(this),
                deadline: block.timestamp + 180,
                amountIn: underlyingRedeemed,
                amountOutMinimum: debtToReturn,
                sqrtPriceLimitX96: 0
            })
        );

        // if profitable pay profits to recipient
        if (debtRecovered > debtToReturn) {
            uint256 profit = debtRecovered - debtToReturn;
            pay(decoded.base, address(this), recipient, profit);
        }

        // repay flash loan
        pay(decoded.base, address(this), msg.sender, debtToReturn);
    }

    // @param vaultId The vault to liquidate
    // @notice Liquidates a vault with help from a Uniswap v3 flash loan
    function liquidate(bytes12 vaultId) external {
        uint24 poolFee = 3000; // 0.3%

        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);
        address base = cauldron.assets(series.baseId);
        address collateral = cauldron.assets(vault.ilkId);
		uint128 baseLoan = cauldron.debtToBase(vault.seriesId, balances.art);

        // tokens in PoolKey must be ordered
        bool ordered = (collateral < base);
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: ordered ? collateral : base,
            token1: ordered ? base : collateral,
            fee: poolFee
        });
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        // data for the callback to know what to do
        FlashCallbackData memory args = FlashCallbackData({
            vaultId: vaultId,
            base: base,
            collateral: collateral,
            baseLoan: baseLoan,
            baseJoin: address(witch.ladle().joins(series.baseId)),
            poolKey: poolKey
        });

        // initiate flash loan, with the liquidation logic embedded in the flash loan callback
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
