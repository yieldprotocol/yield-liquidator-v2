// SPDX-License-Identifier: GPL-2.0-or-later

import "./ICurveStableSwap.sol";
import "./IWstEth.sol";
import "./TransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/interfaces/IWETH9.sol";


// @notice
contract SwapperSteth {
    using TransferHelper for address;
    using TransferHelper for IWstEth;

    struct SwapperData {
        address receivedAddress;
        uint256 receivedAmount;
    }

    function swap(uint256 amountToSwap) external returns(SwapperData) {
        // wstEth
        // // unwrap wstEth => stEth
        // uint256 unwrappedStEth = wstEth.unwrap(collateralReceived);

        // // swap stEth for Eth on Curve
        // stEth.safeApprove(address(curveSwap), unwrappedStEth);
        // uint256 ethReceived = curveSwap.exchange(1, 0, unwrappedStEth, 0);

        // // wrap the Eth => Weth
        // IWETH9(WETH9).deposit{value: ethReceived}();


    }
}
