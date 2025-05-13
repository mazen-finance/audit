// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface IMaverickRouter {
    function exactInputSingle(
        address recipient,
        address pool,
        bool tokenAIn,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) external payable returns (uint256 amountOut);
}