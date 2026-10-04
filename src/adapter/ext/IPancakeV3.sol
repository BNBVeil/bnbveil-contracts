// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice PancakeSwap V3 SwapRouter（BSC 主网 0x1b81D678ffb9C0263b24A97847620C99d213eB14）
interface ISwapRouter {
  struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 deadline;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
  }

  function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWBNB {
  function deposit() external payable;
  function withdraw(uint256 amount) external;
  function balanceOf(address account) external view returns (uint256);
}
