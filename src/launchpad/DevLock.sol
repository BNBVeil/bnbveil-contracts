// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DevLock
/// @notice 开发者份额锁仓（每个代币一个 EIP-1167 克隆）。线性解锁。
///         隐私：每次领取都可以发往新的隐身地址（或直接存入屏蔽池），不需要公开更换受益人——
///         链上“更换受益人”本身就会把新旧地址关联起来。
contract DevLock {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public beneficiary;
    uint64 public start;
    uint64 public duration;
    uint256 public totalLocked;
    uint256 public released;

    event Released(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error OnlyBeneficiary();
    error ZeroAddress();
    error NothingToRelease();

    constructor() {
        token = IERC20(address(0xdead));
    }

    /// @dev 由 Portal 在发币的同一笔交易里调用；代币此前已转入本合约
    function initialize(IERC20 token_, address beneficiary_, uint256 amount, uint64 duration_) external {
        if (address(token) != address(0)) revert AlreadyInitialized();
        if (beneficiary_ == address(0) || address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        beneficiary = beneficiary_;
        start = uint64(block.timestamp);
        duration = duration_;
        totalLocked = amount;
    }

    function vested(uint256 timestamp) public view returns (uint256) {
        if (timestamp <= start) return 0;
        uint256 elapsed = timestamp - start;
        if (elapsed >= duration) return totalLocked;
        return (totalLocked * elapsed) / duration;
    }

    function releasable() public view returns (uint256) {
        return vested(block.timestamp) - released;
    }

    /// @param to 收款地址：建议每次用新的隐身地址，或屏蔽池的存入适配器
    function release(address to) external {
        if (msg.sender != beneficiary) revert OnlyBeneficiary();
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        emit Released(to, amount);
        token.safeTransfer(to, amount);
    }
}
