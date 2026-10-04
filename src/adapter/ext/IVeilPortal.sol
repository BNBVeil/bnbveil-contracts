// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 已部署 VeilPortal 的买卖与市场查询接口
interface IVeilPortal {
  function buy(address token, uint256 minTokensOut, address to) external payable returns (uint256 tokensOut);

  function sell(address token, uint256 tokensIn, uint256 minBnbOut, address to) external returns (uint256 bnbOut);

  function markets(address token)
    external
    view
    returns (uint256 x, uint256 y, uint256 raised, uint256 sold, address pool, address devLock, bool graduated);
}
