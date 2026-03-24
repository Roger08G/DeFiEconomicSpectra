// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SpETH — Spectra Liquid Staking Derivative
/// @notice ERC20 token representing staked ETH in the Spectra Protocol
/// @dev Only the LiquidStaking contract can mint and burn

contract SpETH {
    string public constant name = "Spectra Staked ETH";
    string public constant symbol = "spETH";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    address public liquidStaking;
    address public owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error Unauthorized();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    modifier onlyAuthorized() {
        if (msg.sender != liquidStaking && msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setLiquidStaking(address _liquidStaking) external {
        if (msg.sender != owner) revert Unauthorized();
        if (_liquidStaking == address(0)) revert ZeroAddress();
        liquidStaking = _liquidStaking;
    }

    function mint(address to, uint256 amount) external onlyAuthorized {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyAuthorized {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] = currentAllowance - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
