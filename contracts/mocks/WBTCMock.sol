// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract WBTCMock is ERC20PresetMinterPauser {

    constructor () ERC20PresetMinterPauser("Wrapped BTC", "WBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

}