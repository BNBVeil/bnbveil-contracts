// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CurveMath
/// @notice 虚拟储备恒定乘积联合曲线：x * y = k，其中 x = 虚拟 BNB + 已募集 BNB，y = 曲线剩余（含虚拟）代币。
///         取整方向一律有利于曲线（买少给、卖少给），保证 k 只增不减。
library CurveMath {
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @return tokensOut 投入 netBnb（已扣手续费）能买到的代币数量
    function tokensForBnb(uint256 x, uint256 y, uint256 netBnb) internal pure returns (uint256 tokensOut) {
        uint256 newY = ceilDiv(x * y, x + netBnb);
        tokensOut = y - newY;
    }

    /// @return netBnb 恰好买到 tokens 个代币所需的净 BNB（向上取整）
    function bnbForTokens(uint256 x, uint256 y, uint256 tokens) internal pure returns (uint256 netBnb) {
        netBnb = ceilDiv(x * y, y - tokens) - x;
    }

    /// @return grossBnb 卖出 tokensIn 得到的 BNB（未扣手续费，向下取整）
    function bnbForSell(uint256 x, uint256 y, uint256 tokensIn) internal pure returns (uint256 grossBnb) {
        uint256 newX = ceilDiv(x * y, y + tokensIn);
        grossBnb = x - newX;
    }
}
