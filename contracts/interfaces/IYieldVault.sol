// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYieldVault {
    function deposit(uint256 assets) external returns (uint256 shares);
    function mint(uint256 shares) external returns (uint256 assets);
    function withdraw(uint256 shares) external returns (uint256 assets);
    function harvest() external;
    function totalManagedAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function sharePrice() external view returns (uint256);
}
