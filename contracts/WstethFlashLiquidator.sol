// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.6;

import "./FlashLiquidator.sol";
import "./ICurveStableSwap.sol";
import "./IWstEth.sol";

// @notice This is the Yield Flash liquidator contract for Lido Wrapped Staked Ether (WSTETH)
contract WstethFlashLiquidator is FlashLiquidator {
    using UniswapTransferHelper for address;
    using UniswapTransferHelper for IWstEth;

    // @notice "i" and "j" are the first two parameters (token to sell and token to receive respectively)
    //         in the CurveStableSwap.exchange function.  They represent that contract's internally stored
    //         index of the token being swapped
    // @dev    The STETH/ETH pool only supports two tokens: ETH index: 0, STETH index: 1
    //         https://etherscan.io/address/0xDC24316b9AE028F1497c275EB9192a3Ea0f67022#readContract
    //         This can be confirmed by calling the "coins" function on the CurveStableSwap contract
    //         0 -> 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE == ETH (the address Curve uses to represent ETH -- see github link below)
    //         1 -> 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 == STETH (deployed contract address of STETH)
    // https://github.com/curvefi/curve-contract/blob/b0bbf77f8f93c9c5f4e415bce9cd71f0cdee960e/contracts/pools/steth/StableSwapSTETH.vy#L143
    int128 public constant CURVE_EXCHANGE_PARAMETER_I = 1; // token to sell (STETH, index 1 on Curve contract)
    int128 public constant CURVE_EXCHANGE_PARAMETER_J = 0; // token to receive (ETH, index 0 on Curve contract)

    // @notice stEth and wstEth deployed contracts https://docs.lido.fi/deployed-contracts/
    address public constant STETH  = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // @notice Curve stEth/Eth pool https://curve.readthedocs.io/ref-addresses.html
    address public constant CURVE_SWAP = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    constructor(
        IWitch witch_,
        address swapRouter_,
        IFlashLoan flashLoaner_
    ) FlashLiquidator(
        witch_,
        swapRouter_,
        flashLoaner_
    ) {}

    // @dev Required to receive ETH from Curve
    receive() external payable {}

    // @notice flash loan callback, see IFlashLoanRecipient for details
    // @param tokens tokens loaned
    // @param amounts amounts of tokens loaned
    // @param feeAmounts flash loan fees
    // @dev        Unlike the other Yield FlashLiquidator contracts, this contains extra steps to
    //             unwrap WSTETH and swap it for Eth on Curve before Uniswapping it for base
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData) public override {

        require(liquidating && msg.sender == address(flashLoaner), "baka");
        require(tokens.length == 1 , "1 token expected");

        // decode, verify, and set debtToReturn
        FlashCallbackData memory decoded = abi.decode(userData, (FlashCallbackData));

        uint256 baseLoan = amounts[0];
        uint256 debtToReturn = baseLoan + feeAmounts[0];

        // liquidate the vault
        decoded.base.safeApprove(decoded.baseJoin, baseLoan);
        uint256 collateralReceived = witch.payAll(decoded.vaultId, 0);

        // Sell collateral:

        // Step 1 - unwrap WSTETH => STETH
        uint256 unwrappedStEth = IWstEth(WSTETH).unwrap(collateralReceived);

        // Step 2 - swap STETH for Eth on Curve
        STETH.safeApprove(CURVE_SWAP, unwrappedStEth);
        uint256 ethReceived = ICurveStableSwap(CURVE_SWAP).exchange(
            CURVE_EXCHANGE_PARAMETER_I,  // index 1 representing STETH
            CURVE_EXCHANGE_PARAMETER_J,  // index 0 representing ETH
            unwrappedStEth,              // amount to swap
            0                            // no slippage guard
        );

        // Step 3 -  wrap the Eth => Weth
        IWETH9(WETH).deposit{ value: ethReceived }();

        // Step 4 - if necessary, swap Weth for base on UniSwap
        uint256 debtRecovered;
        if (decoded.base == WETH) {
            debtRecovered = ethReceived;
        } else {
            address swapRouter_ = swapRouter02;
            WETH.safeApprove(address(swapRouter_), ethReceived);
            (bool ok, bytes memory swapReturnBytes) = swapRouter02.call(decoded.swapCalldata);
            require(ok, "swap failed");
        }

        // if profitable pay profits to recipient
        if (debtRecovered > debtToReturn) {
            uint256 profit;
            unchecked {
                profit = debtRecovered - debtToReturn;
            }
            decoded.base.safeTransfer(decoded.recipient, profit);
        }
        // repay flash loan
        decoded.base.safeTransfer(msg.sender, debtToReturn);
    }
}
