// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

interface IMaverickV2Pool {
    struct State {
        uint128 reserveA;
        uint128 reserveB;
        int64 lastTwaD8;
        int64 lastLogPriceD8;
        uint40 lastTimestamp;
        int32 activeTick;
        bool isLocked;
        uint32 binCounter;
        uint8 protocolFeeRatioD3;
    }

    struct SwapParams {
        uint256 amount;
        bool tokenAIn;
        bool exactOutput;
        int32 tickLimit;
    }

    function swap(
        address recipient,
        SwapParams calldata params,
        bytes calldata data
    ) external returns (uint256 amountIn, uint256 amountOut);

    function getState() external view returns (State memory);
    function tokenA() external view returns (address);
    function tokenB() external view returns (address);
    function fee(bool tokenAIn) external view returns (uint256);
}