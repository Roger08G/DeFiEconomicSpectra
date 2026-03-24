// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidStaking {
    function stake() external payable returns (uint256 spETHAmount);
    function withdraw(uint256 spETHAmount) external returns (uint256 ethAmount);
    function exchangeRate() external view returns (uint256);
    function totalPooledETH() external view returns (uint256);
    function claimRewards() external returns (uint256);
    function reportRewards(uint256 amount) external;
    function deployToStrategy(address strategy, uint256 amount) external;
}
