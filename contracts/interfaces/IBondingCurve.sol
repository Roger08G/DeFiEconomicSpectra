// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBondingCurve {
    function buy() external payable returns (uint256 tokensOut);
    function sell(uint256 tokenAmount) external returns (uint256 ethOut);
    function spotPrice() external view returns (uint256);
    function realReserve() external view returns (uint256);
    function tokenSupply() external view returns (uint256);
}
