// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "@yield-protocol/utils-v2/contracts/interfaces/IWETH9.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/IWitch.sol";
import "./UniswapImports.sol";
import "./ICurveStableSwap.sol";
import "./IWstEth.sol";

// TODO: Rename this file and contract FlashLiquidatorWsteth.sol
// For now, we use the old name for initial code review to clearly show diff from the original contract
contract FlashLiquidator is IUniswapV3FlashCallback, PeripheryImmutableState, PeripheryPayments {
    using TransferHelper for address;
    using TransferHelper for IWstEth;

    address public immutable recipient;           // Recipient address
    ISwapRouter public immutable swapRouter;      // Uniswap swap router
    IWitch public immutable witch;                // Yield witch
    ICauldron public immutable cauldron;          // Yield cauldron
    ICurveStableSwap public immutable curveSwap;  // Curve stEth/Eth pool
    IWstEth public immutable wstEth;              // Lido wrapped stEth contract address
    address public immutable stEth;               // stEth contract address


    struct FlashCallbackData {
        bytes12 vaultId;
        address base;
        address collateral;
        uint256 baseLoan;
        address baseJoin;
        PoolAddress.PoolKey poolKey;
    }

    constructor(
        address recipient_,
        ISwapRouter swapRouter_,
        address factory_,
        address WETH9_,
        IWitch witch_,
        ICurveStableSwap curveSwap_,
        IWstEth wstEth_,
        address stEth_
    ) PeripheryImmutableState(factory_, WETH9_) {
        recipient = recipient_;
        swapRouter = swapRouter_;
        witch = witch_;
        cauldron = witch_.cauldron();
        curveSwap = curveSwap_;
        wstEth = wstEth_;
        stEth = stEth_;
    }

    receive() external override payable {
        require(msg.sender == WETH9 || msg.sender == address(curveSwap), "Unauthorized sender");
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
        // we only borrow 1 token
        require(fee0 == 0 || fee1 == 0, "Two tokens were borrowed");
        uint256 fee = fee0 + fee1;

        // decode and verify
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);

        uint256 debtToReturn = decoded.baseLoan + fee;

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        // Sell collateral

        // Step 1 - unwrap wstEth => stEth
        uint256 unwrappedStEth = wstEth.unwrap(collateralReceived);

        // Step 2 - swap stEth for Eth on Curve
        stEth.safeApprove(address(curveSwap), unwrappedStEth);
        uint256 ethReceived = curveSwap.exchange(1, 0, unwrappedStEth, 0);

        // Step 3 -  wrap the Eth => Weth
        IWETH9(WETH9).deposit{value: ethReceived}();

        // Step 4 - if necessary, swap Weth for base on UniSwap
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
            uint256 profit = debtRecovered - debtToReturn;
            pay(decoded.base, address(this), recipient, profit);
        }

        // repay flash loan
        pay(decoded.base, address(this), msg.sender, debtToReturn);
    }

    /// @param vaultId The vault to liquidate
    /// @notice Liquidates a vault with help from a Uniswap v3 flash loan
    function liquidate(bytes12 vaultId) external {
        uint24 poolFee = 3000; // 0.3%

        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);
        address base = cauldron.assets(series.baseId);
        require(cauldron.assets(vault.ilkId) == address(wstEth), "not wstEth");

        //  Hardcoding the DAI address for now, can't use the ilk for the other token
        //  in the pool because there are no wstEth pools on Uniswap from what I can tell
        address collateral = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

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
