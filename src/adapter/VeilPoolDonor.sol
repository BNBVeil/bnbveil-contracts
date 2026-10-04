// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from '@oz/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@oz/utils/ReentrancyGuard.sol';

import {Constants} from 'contracts/lib/Constants.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

import {IVeilDonation} from './ext/IVeilDonation.sol';

/// @title VeilPoolDonor
/// @notice 取款即捐款：自己作为取款的 processooor，从原生 BNB 隐私池取出后立刻捐给 VeilDonation 的活动。
///         链上看到的捐款人是本合约，受助方收到钱和（可选的）凭证哈希，看不到是谁捐的。
/// @dev 活动、凭证哈希和中继费都在 `Withdrawal.data` 里，被取款证明的 context 绑定，中继者无法改动。
///      取款金额必须是 0.01 BNB 的整数倍（标准份额之和），避免用零碎金额对号。
///      合约不保存资金：调用结束时 BNB 余额必须回到调用前。
contract VeilPoolDonor is ReentrancyGuard {
  using ProofLib for ProofLib.WithdrawProof;

  /// @notice 放在 `Withdrawal.data` 里的捐款指令
  struct DonateData {
    uint256 campaignId;
    bytes32 receiptHash;
    address feeRecipient;
    uint256 relayFeeBPS;
  }

  uint256 public constant LOT_UNIT = 0.01 ether;
  uint256 internal constant _BPS = 10_000;
  address internal constant _NO_POOL = address(1);

  IEntrypoint public immutable ENTRYPOINT;
  IVeilDonation public immutable DONATION;

  /// @dev 正在被本合约调用 withdraw 的池，只有它可以在此期间向本合约转 BNB
  address private _activePool = _NO_POOL;

  /// @notice 捐款完成。不含任何能关联到取款人的信息
  event DonatedPrivately(uint256 indexed campaignId, uint256 amount, bytes32 receiptHash);

  error ZeroAddress();
  error InvalidProcessooor();
  error PoolNotFound();
  error NotNativePool();
  error InvalidWithdrawnAmount();
  error NotStandardAmount(uint256 amount);
  error RelayFeeGreaterThanMax();
  error InvalidFeeRecipient();
  error CampaignInactive(uint256 campaignId);
  error UnexpectedSender();
  error PoolBalanceMismatch();
  error ResidualBalance();
  error TransferFailed();

  constructor(IEntrypoint entrypoint_, IVeilDonation donation_) {
    if (address(entrypoint_) == address(0) || address(donation_) == address(0)) revert ZeroAddress();
    ENTRYPOINT = entrypoint_;
    DONATION = donation_;
  }

  /// @dev 只在池向我们付款时收 BNB，误转一律回滚
  receive() external payable {
    if (msg.sender != _activePool) revert UnexpectedSender();
  }

  /// @notice 取款并捐款。任何人（中继者）都可以提交
  /// @param w 取款，`processooor` 必须是本合约，`data = abi.encode(DonateData)`
  /// @param p 取款证明
  /// @param scope 池的 scope（必须是已在 Entrypoint 登记的原生币池）
  function withdrawAndDonate(
    IPrivacyPool.Withdrawal calldata w,
    ProofLib.WithdrawProof calldata p,
    uint256 scope
  ) external nonReentrant {
    if (w.processooor != address(this)) revert InvalidProcessooor();

    IPrivacyPool pool = ENTRYPOINT.scopeToPool(scope);
    if (address(pool) == address(0)) revert PoolNotFound();
    if (pool.ASSET() != Constants.NATIVE_ASSET) revert NotNativePool();

    DonateData memory d = abi.decode(w.data, (DonateData));
    _checkRelayFee(d.relayFeeBPS, d.feeRecipient);
    (, bool active,,,) = DONATION.campaigns(d.campaignId);
    if (!active) revert CampaignInactive(d.campaignId);

    uint256 withdrawn = p.withdrawnValue();
    if (withdrawn == 0) revert InvalidWithdrawnAmount();
    if (withdrawn % LOT_UNIT != 0) revert NotStandardAmount(withdrawn);

    uint256 balanceBefore = address(this).balance;

    _activePool = address(pool);
    pool.withdraw(w, p);
    _activePool = _NO_POOL;

    if (address(this).balance != balanceBefore + withdrawn) revert PoolBalanceMismatch();

    uint256 fee = (withdrawn * d.relayFeeBPS) / _BPS;
    if (fee != 0) _sendBnb(d.feeRecipient, fee);
    uint256 amount = withdrawn - fee;

    DONATION.donate{value: amount}(d.campaignId, d.receiptHash);
    emit DonatedPrivately(d.campaignId, amount, d.receiptHash);

    if (address(this).balance != balanceBefore) revert ResidualBalance();
  }

  function _checkRelayFee(uint256 relayFeeBPS, address feeRecipient) private view {
    (,,, uint256 maxRelayFeeBPS) = ENTRYPOINT.assetConfig(IERC20(Constants.NATIVE_ASSET));
    if (relayFeeBPS > maxRelayFeeBPS) revert RelayFeeGreaterThanMax();
    if (relayFeeBPS != 0 && feeRecipient == address(0)) revert InvalidFeeRecipient();
  }

  function _sendBnb(address to, uint256 amount) private {
    (bool success,) = to.call{value: amount}('');
    if (!success) revert TransferFailed();
  }
}
