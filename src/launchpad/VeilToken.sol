// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VeilToken
/// @notice 发射台统一代币模板（EIP-1167 克隆）：固定总量、无税、无增发、无黑名单、不可升级。
///         唯一的特殊规则：毕业前禁止向 PancakeSwap 池地址转入，防止有人抢先往池子里加流动性或砸价。
contract VeilToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    address public portal;
    address public dexPool;
    bool public graduated;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error AlreadyInitialized();
    error OnlyPortal();
    error PoolLocked();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    /// @dev 实现合约本身不可用：构造时把 portal 设为非零，阻止任何人初始化实现合约
    constructor() {
        portal = address(0xdead);
    }

    function initialize(string calldata name_, string calldata symbol_, uint256 supply, address portal_) external {
        if (portal != address(0)) revert AlreadyInitialized();
        if (portal_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        portal = portal_;
        totalSupply = supply;
        balanceOf[portal_] = supply;
        emit Transfer(address(0), portal_, supply);
    }

    modifier onlyPortal() {
        if (msg.sender != portal) revert OnlyPortal();
        _;
    }

    /// @notice 发币时由 Portal 设置预先初始化好的 PancakeSwap V3 池地址
    function setDexPool(address pool) external onlyPortal {
        dexPool = pool;
    }

    function markGraduated() external onlyPortal {
        graduated = true;
    }

    /// @notice 毕业时销毁多余代币（只有 Portal 能销毁自己持有的部分）
    function burnFromPortal(uint256 amount) external onlyPortal {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        // 毕业前只有 Portal 能把代币放进池子（毕业那一刻），其他人一律拒绝
        if (!graduated && to == dexPool && to != address(0)) revert PoolLocked();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
