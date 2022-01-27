// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import './IFlashLoanRecipient.sol';

interface IFlashLoan {
    function flashLoan(
        IFlashLoanRecipient recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}
