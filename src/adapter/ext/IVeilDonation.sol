// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice contracts/src/VeilDonation.sol 中本适配器用到的部分
interface IVeilDonation {
  function donate(uint256 id, bytes32 receiptHash) external payable;

  function campaigns(uint256 id)
    external
    view
    returns (address recipient, bool active, uint64 donations, uint256 totalBnb, string memory title);
}
