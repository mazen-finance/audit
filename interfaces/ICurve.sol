// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.0;

interface ICurve {
  // function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) payable external returns (uint256);
    function swap(
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256 minDy,
        uint256 deadline
    ) external returns (uint256);
}

interface ICurveLegacy {
  // function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) payable external;
    function swap(
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx,
        uint256 minDy,
        uint256 deadline
    ) external returns (uint256);
}


