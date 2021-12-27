// SPDX-License-Identifier: MIT


pragma solidity >=0.8.0;

/// @title Multicall2 - Aggregate results from multiple read-only function calls
/// @author Michael Elliot <mike@makerdao.com>
/// @author Joshua Levine <joshua@makerdao.com>
/// @author Nick Johnson <arachnid@notdot.net>

interface IMulticall2 {
    struct CallData {
        address target;
        bytes callData;
    }
    struct ResultData {
        bool success;
        bytes returnData;
    }
    function tryAggregate(bool requireSuccess, CallData[] memory calls) external returns (ResultData[] memory returnData);
}