// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;
import "@yield-protocol/utils-v2/contracts/token/ERC20.sol";


contract LINKMock is ERC20  {

    constructor() ERC20("ChainLink Token", "LINK", 18) { }

    /// @dev Give tokens to whoever asks for them.
    function mint(address to, uint256 amount) public virtual {
        _mint(to, amount);
    }
}
