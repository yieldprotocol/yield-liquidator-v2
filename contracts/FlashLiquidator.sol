// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/IWitch.sol";
import "./IUniswapV3Pool.sol";
import "./ISwapRouter.sol";
import "./PoolAddress.sol";
import "./TransferHelper.sol";


// @notice This is the standard Flash Liquidator used with Yield liquidator bots for most collateral types
contract FlashLiquidator {
    using TransferHelper for address;

    // DAI  official token -- "otherToken" for UniV3Pool flash loan
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // WETH official token -- alternate "otherToken"
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;


    ICauldron public immutable cauldron;      // Yield Cauldron
    IWitch public immutable witch;            // Yield Witch
    address public immutable factory;         // UniswapV3 pool factory
    ISwapRouter public immutable swapRouter;  // UniswapV3 swapRouter

    struct FlashCallbackData {
        bytes12 vaultId;
        address base;
        address collateral;
        uint256 baseLoan;
        address baseJoin;
        PoolAddress.PoolKey poolKey;
        address recipient;
    }

    // @dev Parameter order matters
    constructor(
        IWitch witch_,
        address factory_,
        ISwapRouter swapRouter_
    ) {
        witch = witch_;
        cauldron = witch_.cauldron();
        factory = factory_;
        swapRouter = swapRouter_;
    }

    // @notice This is used by the bot to determine the current collateral to debt ratio
    // @dev    Cauldron.level returns collateral * price(collateral, denominator=debt) - debt * ratio * accrual
    //         but the bot needs collateral * price(collateral, denominator=debt)/debt * accrual
    // @param  vaultId id of vault to check
    // @return adjusted collateralization level
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

    // @notice This is used by the bot to determine if the auction price has reached the final, minimum price yet
    // @param  vaultId id of vault to check
    // @return True if it has reached minimal price
    function isAtMinimalPrice(bytes12 vaultId) public returns (bool) {
        bytes6 ilkId = (cauldron.vaults(vaultId)).ilkId;
        (uint32 duration, ) = witch.ilks(ilkId);
        (, uint32 auctionStart) = witch.auctions(vaultId);
        uint256 elapsed = uint32(block.timestamp) - auctionStart;
        return elapsed >= duration;
    }

    // @notice Returns the address of a valid Uniswap V3 Pool
    // @dev from 'uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol'
    // @param poolKey The identifying key of the V3 pool
    // @return pool The V3 pool contract address
    function _verifyCallback(PoolAddress.PoolKey memory poolKey)
        internal
        view
        returns (IUniswapV3Pool pool)
    {
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));
        require(msg.sender == address(pool), "Invalid caller");
    }

    // @param fee0 The fee from calling flash for token0
    // @param fee1 The fee from calling flash for token1
    // @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    // @notice implements the callback called from flash
    // @dev this fn should be overwritten by subclasses for non-standard collateral types
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external virtual {
        // we only borrow 1 token
        require(fee0 == 0 || fee1 == 0, "Two tokens were borrowed");
        uint256 fee;
        unchecked {
            // Since one fee is always zero, this won't overflow
            fee = fee0 + fee1;
        }

        // decode and verify
        FlashCallbackData memory decoded = abi.decode(data, (FlashCallbackData));
        _verifyCallback(decoded.poolKey);

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, decoded.baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        // sell the collateral
        uint256 debtToReturn = decoded.baseLoan + fee;
        decoded.collateral.safeApprove(address(swapRouter), collateralReceived);
        uint256 debtRecovered = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: decoded.collateral,
                tokenOut: decoded.base,
                fee: 3000,  // can't use the same fee as the flash loan
                           // because of reentrancy protection
                recipient: address(this),
                deadline: block.timestamp + 180,
                amountIn: collateralReceived,
                amountOutMinimum: debtToReturn, // bots will sandwich us and eat profits, we don't mind
                sqrtPriceLimitX96: 0
            })
        );

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

    // @notice Liquidates a vault with help from a Uniswap v3 flash loan
    // @param vaultId The vault to liquidate
    function liquidate(bytes12 vaultId) external {
        (, uint32 start) = witch.auctions(vaultId);
        require(start > 0, "Vault not under auction");
        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);
        address baseToken = cauldron.assets(series.baseId);
        uint128 baseLoan = cauldron.debtToBase(vault.seriesId, balances.art);
        address collateral = cauldron.assets(vault.ilkId);

        // The flash loan only borrows one token, so the UniV3Pool that is selected only
        // needs to have the baseToken in it. For the otherToken we prefer WETH or DAI
        address otherToken = baseToken == WETH ? DAI : WETH;

        // tokens in PoolKey must be ordered
        bool ordered = (baseToken < otherToken);
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: ordered ? baseToken : otherToken,
            token1: ordered ? otherToken : baseToken,
            fee: 500 // 0.3%
        });
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        // data for the callback to know what to do
        FlashCallbackData memory args = FlashCallbackData({
            vaultId: vaultId,
            base: baseToken,
            collateral: collateral,
            baseLoan: baseLoan,
            baseJoin: address(witch.ladle().joins(series.baseId)),
            poolKey: poolKey,
            recipient: msg.sender   // We will get front-run by generalized front-runners, this is desired as it reduces our gas costs
        });

        // initiate flash loan, with the liquidation logic embedded in the flash loan callback
        pool.flash(
            address(this),
            ordered ? baseLoan : 0,
            ordered ? 0 : baseLoan,
            abi.encode(
                args
            )
        );
    }
}
