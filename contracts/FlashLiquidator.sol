// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/IWitch.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20Metadata.sol";
import "./IUniswapV3Pool.sol";
import "./ISwapRouter.sol";
import "./PoolAddress.sol";
import "./TransferHelper.sol";


// @notice This is the standard Flash Liquidator used with Yield liquidator bots for most collateral types
contract FlashLiquidator {
    using TransferHelper for address;

    address public immutable recipient;       // address to receive any profits
    ICauldron public immutable cauldron;      // Yield Cauldron
    IWitch public immutable witch;            // Yield Witch
    address public immutable factory;         // UniswapV3 pool factory
    ISwapRouter public immutable swapRouter;  // UniswapV3 swapRouter
    address public immutable dai;             // DAI  official token -- "otherToken" for UniV3Pool flash loan
    address public immutable weth;            // WETH official token -- alternate "otherToken"

    struct FlashCallbackData {
        bytes12 vaultId;
        address base;
        address collateral;
        uint256 baseLoan;
        address baseJoin;
        PoolAddress.PoolKey poolKey;
    }

    // @dev Parameter order matters
    constructor(
        address recipient_,
        IWitch witch_,
        address factory_,
        ISwapRouter swapRouter_,
        address dai_,
        address weth_
    ) {
        require(
            keccak256(abi.encodePacked(IERC20Metadata(weth_).symbol())) == keccak256(abi.encodePacked("WETH")),
            "Incorrect WETH address"
        );
        weth = weth_;
        require(
            keccak256(abi.encodePacked(IERC20Metadata(dai_).symbol())) == keccak256(abi.encodePacked("DAI")),
            "Incorrect DAI address"
        );
        dai = dai_;

        recipient = recipient_;
        witch = witch_;
        cauldron = witch_.cauldron();
        factory = factory_;
        swapRouter = swapRouter_;
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
                fee: 500,  // can't use the same fee as the flash loan
                           // because of reentrancy protection
                recipient: address(this),
                deadline: block.timestamp + 180,
                amountIn: collateralReceived,
                amountOutMinimum: debtToReturn,
                sqrtPriceLimitX96: 0
            })
        );

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

    // @notice Liquidates a vault with help from a Uniswap v3 flash loan
    // @param vaultId The vault to liquidate
    function liquidate(bytes12 vaultId) external {
        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);
        address baseToken = cauldron.assets(series.baseId);
		uint128 baseLoan = cauldron.debtToBase(vault.seriesId, balances.art);
        address collateral = cauldron.assets(vault.ilkId);

        // The flash loan only borrows one token, so the UniV3Pool that is selected only
        // needs to have the baseToken in it.  For the otherToken we prefer WETH or DAI
        address otherToken = baseToken == weth ? dai : weth;

        // tokens in PoolKey must be ordered
        bool ordered = (baseToken < otherToken);
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: ordered ? baseToken : otherToken,
            token1: ordered ? otherToken : baseToken,
            fee: 3000 // 0.3%
        });
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        // data for the callback to know what to do
        FlashCallbackData memory args = FlashCallbackData({
            vaultId: vaultId,
            base: baseToken,
            collateral: collateral,
            baseLoan: baseLoan,
            baseJoin: address(witch.ladle().joins(series.baseId)),
            poolKey: poolKey
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
