// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;
import "@yield-protocol/utils/contracts/token/IERC20.sol";
import "@yield-protocol/vault-interfaces/IJoin.sol";
import "./AccessControl.sol";
import "./TransferHelper.sol";


contract Join is IJoin, AccessControl() {
    using TransferHelper for IERC20;

    address public override asset;
    uint256 public storedBalance;
    // bytes6  public asset;   // Collateral Type
    // uint    public dec;
    // uint    public live;  // Active Flag

    constructor(address asset_) {
        asset = asset_;
        // dec = token.decimals();
        // live = 1;
    }

    /*
    function cage() external auth {
        live = 0;
    }
    */

    /// @dev With a positive `amount`, `join` will `transferFrom` the user the `amount`, minus any unaccounted `token` already present.
    /// Users can `transfer` to this contract and then execute `join`, as well as `approve` this contract and let `join` pull the tokens.
    function join(address user, uint128 amount)
        external override
        auth
        returns (uint128)
    {
        IERC20 token = IERC20(asset);

        // require(live == 1, "GemJoin/not-live");
        uint256 initialBalance = token.balanceOf(address(this));
        uint256 surplus = initialBalance - storedBalance;
        uint256 required = surplus >= amount ? 0 : amount - surplus;
        storedBalance = initialBalance + required;
        if (required > 0) token.safeTransferFrom(user, address(this), required);
        return amount;
    }

    function exit(address user, uint128 amount)
        external override
        auth
        returns (uint128)
    {
        IERC20 token = IERC20(asset);

        storedBalance -= amount;                                  // To withdraw surplus tokens we can do a `join` for zero tokens first.
        token.safeTransfer(user, amount);
        return amount;
    }
}