// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SpectraToken — Governance & Utility Token for Spectra Protocol
/// @notice ERC20 token with controlled minting for rewards distribution
/// @dev Minter role is granted to RewardController and BondingCurve

contract SpectraToken {
    string public constant name = "Spectra Token";
    string public constant symbol = "SPEC";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    address public owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isMinter;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterUpdated(address indexed minter, bool status);

    error Unauthorized();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyMinter() {
        if (!isMinter[msg.sender] && msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(uint256 initialSupply) {
        owner = msg.sender;
        if (initialSupply > 0) {
            balanceOf[msg.sender] = initialSupply;
            totalSupply = initialSupply;
            emit Transfer(address(0), msg.sender, initialSupply);
        }
    }

    function setMinter(address minter, bool status) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        isMinter[minter] = status;
        emit MinterUpdated(minter, status);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
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
