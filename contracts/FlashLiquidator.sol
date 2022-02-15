// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/IWitch.sol";
import "uniswapv3-oracle/contracts/uniswapv0.8/IUniswapV3Pool.sol";
import "uniswapv3-oracle/contracts/uniswapv0.8/PoolAddress.sol";
import "./UniswapTransferHelper.sol";
import "./balancer/IFlashLoan.sol";


// @notice This is the standard Flash Liquidator used with Yield liquidator bots for most collateral types
contract FlashLiquidator is IFlashLoanRecipient {
    using UniswapTransferHelper for address;

    // DAI  official token -- "otherToken" for UniV3Pool flash loan
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // WETH official token -- alternate "otherToken"
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;


    ICauldron public immutable cauldron;      // Yield Cauldron
    IWitch public immutable witch;            // Yield Witch
    address public immutable swapRouter02;    // UniswapV3 swapRouter 02
    IFlashLoan public immutable flashLoaner;    // balancer flashloan

    bool public liquidating;                  // reentrance + rogue callback protection

    struct FlashCallbackData {
        bytes12 vaultId;
        address base;
        address collateral;
        address baseJoin;
        address recipient;
        bytes swapCalldata;
    }

    // @dev Parameter order matters
    constructor(
        IWitch witch_,
        address swapRouter_,
        IFlashLoan flashLoaner_
    ) {
        witch = witch_;
        cauldron = witch_.cauldron();
        swapRouter02 = swapRouter_;
        flashLoaner = flashLoaner_;
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
        (uint256 inkValue,)  = cauldron.spotOracles(series.baseId, vault.ilkId).oracle.get(vault.ilkId, series.baseId, balances.ink); // ink * spot
        uint128 accrued_debt = cauldron.debtToBase(vault.seriesId, balances.art);
        return inkValue * 1e18 / accrued_debt;
    }

    // @notice flash loan callback, see IFlashLoanRecipient for details
    // @param tokens tokens loaned
    // @param amounts amounts of tokens loaned
    // @param feeAmounts flash loan fees
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData) public virtual override {
        require(liquidating && msg.sender == address(flashLoaner), "baka");
        require(tokens.length == 1, "1 token expected");

        // decode and verify
        FlashCallbackData memory decoded = abi.decode(userData, (FlashCallbackData));

        uint256 baseLoan = amounts[0];
        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        // sell the collateral
        uint256 debtToReturn = baseLoan + feeAmounts[0];
        decoded.collateral.safeApprove(address(swapRouter02), collateralReceived);
        (bool ok, bytes memory swapReturnBytes) = swapRouter02.call(decoded.swapCalldata);
        require(ok, "swap failed");

        // router can't access collateral anymore
        decoded.collateral.safeApprove(address(swapRouter02), 0);

        // take all remaining collateral
        decoded.collateral.safeTransfer(decoded.recipient, IERC20(decoded.collateral).balanceOf(address(this)));

        // repay flash loan
        decoded.base.safeTransfer(msg.sender, debtToReturn);
    }

    // @notice Liquidates a vault with help from a flash loan
    // @param vaultId The vault to liquidate
    function liquidate(bytes12 vaultId, bytes calldata swapCalldata) external {
        require(!liquidating, "go away baka");
        liquidating = true;

        (, uint32 start) = witch.auctions(vaultId);
        require(start > 0, "Vault not under auction");
        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        DataTypes.Series memory series = cauldron.series(vault.seriesId);
        address baseToken = cauldron.assets(series.baseId);
        uint128 baseLoan = cauldron.debtToBase(vault.seriesId, balances.art);
        address collateral = cauldron.assets(vault.ilkId);

        // data for the callback to know what to do
        FlashCallbackData memory args = FlashCallbackData({
            vaultId: vaultId,
            base: baseToken,
            collateral: collateral,
            baseJoin: address(witch.ladle().joins(series.baseId)),
            swapCalldata: swapCalldata,
            recipient: msg.sender   // We will get front-run by generalized front-runners, this is desired as it reduces our gas costs
        });

        address[] memory tokens = new address[](1);
        tokens[0] = baseToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = baseLoan;
        // initiate flash loan, with the liquidation logic embedded in the flash loan callback
        flashLoaner.flashLoan(this, tokens, amounts, abi.encode(args));

        liquidating = false;
    }
}
