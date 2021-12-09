// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.6;
import "./ISourceMock.sol";
import "./ERC20Mock.sol";

contract WstETHMock is ISourceMock, ERC20Mock {
    ERC20 stETH;
    uint256 public price;

    constructor(ERC20 _stETH) ERC20Mock("Wrapped liquid staked Ether 2.0", "wstETH") {
        stETH = _stETH;
    }

    function wrap(uint256 _stETHAmount) external returns (uint256) {
        uint256 wstETHAmount = getWstETHByStETH(_stETHAmount);
        _mint(msg.sender, wstETHAmount);
        stETH.transferFrom(msg.sender, address(this), _stETHAmount);
        return wstETHAmount;
    }

    function unwrap(uint256 _wstETHAmount) external returns (uint256) {
        uint256 stETHAmount = getStETHByWstETH(_wstETHAmount);
        _burn(msg.sender, _wstETHAmount);
        stETH.transfer(msg.sender, stETHAmount);
        return stETHAmount;
    }

    function set(uint256 price_) external override {
        price = price_;
    }

    function getWstETHByStETH(uint256 _stETHAmount) public view returns (uint256) {
        return (_stETHAmount * 1e18) / price;
    }

    function getStETHByWstETH(uint256 _wstETHAmount) public view returns (uint256) {
        return (_wstETHAmount * price) / 1e18;
    }
}
