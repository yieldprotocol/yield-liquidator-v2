// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "@yield-protocol/utils-v2/contracts/interfaces/IWETH9.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";

library DataTypes {
    struct Series {
        IFYToken fyToken;                                               // Redeemable token for the series.
        bytes6  baseId;                                                 // Asset received on redemption.
        uint32  maturity;                                               // Unix time at which redemption becomes possible.
    }

    struct Vault {
        address owner;
        bytes6  seriesId;                                                // Each vault is related to only one series, which also determines the underlying.
        bytes6  ilkId;                                                   // Asset accepted as collateral
    }

    struct Balances {
        uint128 art;                                                     // Debt amount
        uint128 ink;                                                     // Collateral amount
    }
}

interface IJoin { }

interface IFYToken { }

interface ILadle {
    function joins(bytes6) external view returns (IJoin);
}

interface IWitch {
    function payAll(bytes12 vaultId, uint128 min) external returns (uint256 ink);

    function ladle() external returns (ILadle);

    function cauldron() external returns (ICauldron);

    function auctions(bytes12 vaultId) external returns (address owner, uint32 start);

    function ilks(bytes6 ilkId) external returns (uint32 duration, uint64 initialOffer);
}

interface ICauldron {
    function vaults(bytes12 vault) external view returns (DataTypes.Vault memory);

    function series(bytes6 seriesId) external view returns (DataTypes.Series memory);

    function assets(bytes6 assetsId) external view returns (address);

    function balances(bytes12 vault) external view returns (DataTypes.Balances memory);

    function spotOracles(bytes6 baseId, bytes6 ilkId) external returns (address oracle, uint32 ratio);

    function level(bytes12 vaultId) external returns (int256);

    function debtToBase(bytes6 seriesId, uint128 art) external returns (uint128 base);
}