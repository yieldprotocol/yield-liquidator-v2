// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@yield-protocol/utils-v2/contracts/token/ERC20.sol";


contract StETHMock is ERC20  {

    constructor() ERC20("Liquid staked Ether 2.0", "stETH", 18) { }

    /// @dev Give tokens to whoever asks for them.
    function mint(address to, uint256 amount) public virtual {
        _mint(to, amount);
    }

    /// @dev We mimic the rebasing feature by burning one wei on each transfer
    function _transfer(address src, address dst, uint wad) internal virtual override returns (bool) {
        super._transfer(src, dst, wad - 1);
        _burn(src, 1);
        return true;
    }
}
