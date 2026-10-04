// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from '@oz/token/ERC20/IERC20.sol';
import {IERC20Permit} from '@oz/token/ERC20/extensions/IERC20Permit.sol';
import {SafeERC20} from '@oz/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@oz/utils/ReentrancyGuard.sol';
import {ECDSA} from '@oz/utils/cryptography/ECDSA.sol';
import {EIP712} from '@oz/utils/cryptography/EIP712.sol';

import {Constants} from 'contracts/lib/Constants.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

import {ISwapRouter, IWBNB} from './ext/IPancakeV3.sol';
import {IVeilPortal} from './ext/IVeilPortal.sol';

/// @title VeilPoolAdapter
/// @notice 0xbow 隐私池（原生 BNB 池）与 VeilPortal / PancakeSwap V3 之间的桥：
///         - 买入：自己作为取款的 processooor，取出 BNB 后买币，币直接发给一次性隐身地址；
///         - 卖出：隐身地址用 EIP-712 签卖单（可附 EIP-2612 permit），任何中继者提交，
///                 卖得的 BNB 扣除中继费后按标准份额经 Entrypoint 重新存入池。
/// @dev 记账原则：合约不保存用户资金。所有金额都用“调用前后的余额差”核对，调用结束时 BNB 余额必须回到调用前；
///      有人强行打入（selfdestruct / coinbase）的 BNB 或直接转入的代币不会影响记账，也无法取回。
///      每一笔重新存入，扣掉审核费之后的池内金额必须恰好是 1 / 0.5 / 0.1 / 0.05 / 0.01 BNB。
contract VeilPoolAdapter is EIP712, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using ProofLib for ProofLib.WithdrawProof;
  using ProofLib for ProofLib.RagequitProof;

  /*///////////////////////////////////////////////////////////////
                              TYPES
  //////////////////////////////////////////////////////////////*/

  /// @notice 放在 `Withdrawal.data` 里的买入指令，整体被取款证明的 context 绑定。
  ///         `leftoverPrecommitments[i]` 用来存第 i 个标准份额（先大后小），用不到的尾部忽略。
  struct BuyData {
    address token;
    uint256 minTokensOut;
    address recipient;
    uint256[] leftoverPrecommitments;
    address feeRecipient;
    uint256 relayFeeBPS;
  }

  /// @notice 隐身地址签名的卖单。`depositPrecommitments[i]` 对应第 i 个标准份额。
  struct SellOrder {
    address holder;
    address token;
    uint256 amount;
    uint256 minBnbOut;
    uint256[] depositPrecommitments;
    address feeRecipient;
    uint256 relayFeeBPS;
    uint256 nonce;
    uint256 deadline;
  }

  /// @notice EIP-2612 permit 参数（spender 固定为本合约）
  struct PermitData {
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  /// @notice 由本合约存入池的存款的退回登记：ragequit 的资金只会发到 `to`
  struct Refund {
    address pool;
    address to;
  }

  /*///////////////////////////////////////////////////////////////
                            CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @dev 动态数组按 EIP-712 编码为 `keccak256(abi.encodePacked(元素))`，不进 `abi.encode(struct)`。
  bytes32 public constant SELL_ORDER_TYPEHASH = keccak256(
    'SellOrder(address holder,address token,uint256 amount,uint256 minBnbOut,uint256[] depositPrecommitments,address feeRecipient,uint256 relayFeeBPS,uint256 nonce,uint256 deadline)'
  );

  /// @notice 一次调用最多存回多少个标准份额。再多的部分当作零头直接付出。
  uint256 public constant MAX_STANDARD_DEPOSITS = 8;

  uint256 internal constant _BPS = 10_000;
  uint256 internal constant _LOT_1 = 1 ether;
  uint256 internal constant _LOT_1_2 = 0.5 ether;
  uint256 internal constant _LOT_1_10 = 0.1 ether;
  uint256 internal constant _LOT_1_20 = 0.05 ether;
  uint256 internal constant _LOT_1_100 = 0.01 ether;
  uint24 public constant POOL_FEE = 2500;
  address internal constant _NO_POOL = address(1);

  /*///////////////////////////////////////////////////////////////
                             IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  IEntrypoint public immutable ENTRYPOINT;
  IVeilPortal public immutable PORTAL;
  ISwapRouter public immutable ROUTER;
  IWBNB public immutable WBNB;

  /*///////////////////////////////////////////////////////////////
                               STATE
  //////////////////////////////////////////////////////////////*/

  /// @notice 卖单 nonce 是否已用（holder => nonce => 已用）
  mapping(address holder => mapping(uint256 nonce => bool used)) public usedNonces;

  /// @notice 本合约存入池的每笔存款（按 label）的退回登记
  mapping(uint256 label => Refund refund) public refunds;

  /// @dev 正在被本合约调用 withdraw / ragequit 的池，只有它可以在此期间向本合约转 BNB；平时为 `_NO_POOL`（非零，省 Gas）
  address private _activePool = _NO_POOL;

  /// @dev 买卖进行中才接受 Portal（卖出所得、毕业退款）和 WBNB（解包）打来的 BNB。
  ///      平时关掉：任何人都能把 Portal.buy/sell 的 `to` 填成我们，若一律收下，这笔 BNB 会永久卡在合约里。
  bool private _acceptingProceeds;

  /*///////////////////////////////////////////////////////////////
                              EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice 买入完成。不含任何能关联到取款人的信息
  event BoughtPrivately(address indexed token, address indexed recipient, uint256 bnbIn, uint256 tokensOut);

  /// @notice 一个标准份额已存入池。同一笔卖出会发多条：`tokensIn` / `bnbOut` 都是整笔兑换
  ///         （`bnbOut` 未扣中继费），`depositPrecommitment` 只对应该份额。ASP 按承诺匹配，不要把 `bnbOut` 加总。
  event SoldPrivately(
    address indexed token, address indexed holder, uint256 tokensIn, uint256 bnbOut, uint256 depositPrecommitment
  );

  /// @notice 本合约以 depositor 身份向池存入了一个标准份额（买入的剩余 / 卖出所得）。`amount` 是交给 Entrypoint 的毛额。
  event Redeposited(uint256 indexed label, uint256 indexed precommitment, uint256 amount);

  /// @notice 某一个本该存入的标准份额改为直接支付（承诺为 0、承诺已被占用，或池已停止存款时的整笔金额）
  event PaidOutInstead(address indexed to, uint256 amount);

  /// @notice 拆不成标准份额的零头（含超过 8 笔之后的剩余）直接付给卖出的 holder 或买入的隐身地址
  event RemainderPaid(address indexed to, uint256 amount);

  /// @notice 通过本合约转发的 ragequit
  event RagequitForwarded(uint256 indexed label, address indexed to, uint256 value);

  event NonceInvalidated(address indexed holder, uint256 indexed nonce);

  /*///////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/

  error ZeroAddress();
  error InvalidProcessooor();
  error PoolNotFound();
  error NotNativePool();
  error InvalidWithdrawnAmount();
  error RelayFeeGreaterThanMax();
  error InvalidFeeRecipient();
  error InvalidRecipient();
  error UnknownToken();
  error ZeroAmount();
  error Slippage(uint256 out, uint256 minOut);
  error OrderExpired();
  error NonceAlreadyUsed();
  error InvalidSignature();
  error PermitUnsupported(address token);
  error InsufficientAllowance(address token);
  error UnexpectedTokenTransfer();
  error UnexpectedSender();
  error PoolBalanceMismatch();
  error ResidualBalance();
  error TransferFailed();
  error LabelMismatch();
  error UnknownRefund();
  error TooManyPrecommitments(uint256 length);
  error NotEnoughPrecommitments(uint256 provided, uint256 required);
  error InvalidVettingFee();

  /*///////////////////////////////////////////////////////////////
                           CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  constructor(
    IEntrypoint entrypoint_,
    IVeilPortal portal_,
    ISwapRouter router_,
    IWBNB wbnb_
  ) EIP712('VeilPoolAdapter', '2') {
    if (
      address(entrypoint_) == address(0) || address(portal_) == address(0) || address(router_) == address(0)
        || address(wbnb_) == address(0)
    ) revert ZeroAddress();
    ENTRYPOINT = entrypoint_;
    PORTAL = portal_;
    ROUTER = router_;
    WBNB = wbnb_;
  }

  /// @dev 只在两段窗口收 BNB：池正在向我们付款（取款 / ragequit），或我们正在买卖（Portal 退款 / 卖出所得、WBNB 解包）。
  ///      窗口之外一律拒绝，误转和“把 to 填成 Adapter”的转账都会回滚，钱不会卡在这里。
  receive() external payable {
    if (msg.sender == _activePool) return;
    if (_acceptingProceeds && (msg.sender == address(PORTAL) || msg.sender == address(WBNB))) return;
    revert UnexpectedSender();
  }

  /*///////////////////////////////////////////////////////////////
                         PRIVATE BUY (WITHDRAW)
  //////////////////////////////////////////////////////////////*/

  /// @notice 取款并买币。任何人（中继者）都可以提交；`w.data` 已被证明的 context 绑定，无法被篡改
  /// @param w 取款，`processooor` 必须是本合约，`data = abi.encode(BuyData)`
  /// @param p 取款证明
  /// @param scope 池的 scope（必须是已在 Entrypoint 登记的原生币池）
  function withdrawAndBuy(
    IPrivacyPool.Withdrawal calldata w,
    ProofLib.WithdrawProof calldata p,
    uint256 scope
  ) external nonReentrant {
    if (w.processooor != address(this)) revert InvalidProcessooor();

    IPrivacyPool pool = ENTRYPOINT.scopeToPool(scope);
    if (address(pool) == address(0)) revert PoolNotFound();
    if (pool.ASSET() != Constants.NATIVE_ASSET) revert NotNativePool();

    BuyData memory d = abi.decode(w.data, (BuyData));
    if (d.recipient == address(0) || d.recipient == address(this)) revert InvalidRecipient();
    if (d.leftoverPrecommitments.length > MAX_STANDARD_DEPOSITS) {
      revert TooManyPrecommitments(d.leftoverPrecommitments.length);
    }
    _checkRelayFee(d.relayFeeBPS, d.feeRecipient);

    uint256 withdrawn = p.withdrawnValue();
    if (withdrawn == 0) revert InvalidWithdrawnAmount();

    uint256 balanceBefore = address(this).balance;

    _activePool = address(pool);
    pool.withdraw(w, p);
    _activePool = _NO_POOL;

    if (address(this).balance != balanceBefore + withdrawn) revert PoolBalanceMismatch();

    uint256 fee = _payRelayFee(withdrawn, d.relayFeeBPS, d.feeRecipient);
    uint256 spend = withdrawn - fee;

    // 未上市的地址在 _buy 里以 UnknownToken 回滚。EOA 没有 balanceOf，这里不要先调用，否则错误会变成解码失败。
    uint256 tokenBefore = d.token.code.length == 0 ? 0 : IERC20(d.token).balanceOf(address(this));
    uint256 wbnbBefore = WBNB.balanceOf(address(this));

    (uint256 tokensOut, uint256 leftover) = _buy(d.token, spend, d.minTokensOut);
    uint256 recipientBefore = IERC20(d.token).balanceOf(d.recipient);
    IERC20(d.token).safeTransfer(d.recipient, tokensOut);
    if (IERC20(d.token).balanceOf(d.recipient) != recipientBefore + tokensOut) revert UnexpectedTokenTransfer();
    emit BoughtPrivately(d.token, d.recipient, spend - leftover, tokensOut);

    if (leftover != 0) _settleProceeds(leftover, d.leftoverPrecommitments, d.recipient, address(0), 0, 0);

    if (address(this).balance != balanceBefore) revert ResidualBalance();
    if (IERC20(d.token).balanceOf(address(this)) != tokenBefore) revert ResidualBalance();
    if (WBNB.balanceOf(address(this)) != wbnbBefore) revert ResidualBalance();
  }

  /*///////////////////////////////////////////////////////////////
                         PRIVATE SELL (SIGNED ORDER)
  //////////////////////////////////////////////////////////////*/

  /// @notice 提交隐身地址签名的卖单：取币 → 卖出 → 扣中继费 → 按标准份额存回池。持币地址不需要 Gas
  /// @param order 卖单
  /// @param signature `order.holder` 对卖单的 EIP-712 签名
  /// @param permit EIP-2612 授权；若 holder 已授权足够额度，可传全零
  function sell(SellOrder calldata order, bytes calldata signature, PermitData calldata permit) external nonReentrant {
    if (block.timestamp > order.deadline) revert OrderExpired();
    if (order.holder == address(0)) revert ZeroAddress();
    if (order.amount == 0) revert ZeroAmount();
    if (order.depositPrecommitments.length > MAX_STANDARD_DEPOSITS) {
      revert TooManyPrecommitments(order.depositPrecommitments.length);
    }
    _checkRelayFee(order.relayFeeBPS, order.feeRecipient);
    if (usedNonces[order.holder][order.nonce]) revert NonceAlreadyUsed();

    (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(_hashTypedDataV4(hashSellOrder(order)), signature);
    if (err != ECDSA.RecoverError.NoError || signer != order.holder) revert InvalidSignature();
    usedNonces[order.holder][order.nonce] = true;

    // 未在 Portal 上市的代币直接拒绝，避免先把币拉进来再回滚
    _isGraduated(order.token);

    uint256 balanceBefore = address(this).balance;
    uint256 tokenBefore = IERC20(order.token).balanceOf(address(this));
    uint256 wbnbBefore = WBNB.balanceOf(address(this));

    _pullTokens(order.holder, order.token, order.amount, permit);
    uint256 bnbOut = _sell(order.token, order.amount, order.minBnbOut);
    _refundTokenDust(order.holder, order.token, tokenBefore);

    uint256 fee = _payRelayFee(bnbOut, order.relayFeeBPS, order.feeRecipient);
    _settleProceeds(bnbOut - fee, order.depositPrecommitments, order.holder, order.token, order.amount, bnbOut);

    if (address(this).balance != balanceBefore) revert ResidualBalance();
    if (IERC20(order.token).balanceOf(address(this)) != tokenBefore) revert ResidualBalance();
    if (WBNB.balanceOf(address(this)) != wbnbBefore) revert ResidualBalance();
  }

  /// @notice 持有者主动作废自己的某个 nonce（取消尚未成交的卖单）
  function invalidateNonce(uint256 nonce) external {
    usedNonces[msg.sender][nonce] = true;
    emit NonceInvalidated(msg.sender, nonce);
  }

  /*///////////////////////////////////////////////////////////////
                              RAGEQUIT
  //////////////////////////////////////////////////////////////*/

  /// @notice 转发 ragequit：本合约是这些存款在池里登记的 depositor，只有它能调用池的 `ragequit`。
  ///         资金只会发到存款当时登记的地址（卖出的 holder / 买入剩余的 recipient），所以证明被抢跑也无法改道。
  function ragequit(ProofLib.RagequitProof calldata p) external nonReentrant {
    uint256 label = p.label();
    Refund memory refund = refunds[label];
    if (refund.to == address(0)) revert UnknownRefund();
    delete refunds[label];

    uint256 balanceBefore = address(this).balance;

    _activePool = refund.pool;
    IPrivacyPool(refund.pool).ragequit(p);
    _activePool = _NO_POOL;

    uint256 value = p.value();
    if (address(this).balance != balanceBefore + value) revert PoolBalanceMismatch();

    _sendBnb(refund.to, value);
    emit RagequitForwarded(label, refund.to, value);

    if (address(this).balance != balanceBefore) revert ResidualBalance();
  }

  /*///////////////////////////////////////////////////////////////
                               VIEWS
  //////////////////////////////////////////////////////////////*/

  function hashSellOrder(SellOrder calldata order) public pure returns (bytes32) {
    return keccak256(
      abi.encode(
        SELL_ORDER_TYPEHASH,
        order.holder,
        order.token,
        order.amount,
        order.minBnbOut,
        keccak256(abi.encodePacked(order.depositPrecommitments)),
        order.feeRecipient,
        order.relayFeeBPS,
        order.nonce,
        order.deadline
      )
    );
  }

  /// @notice 卖单的最终签名摘要（前端 / 测试用）
  function sellOrderDigest(SellOrder calldata order) external view returns (bytes32) {
    return _hashTypedDataV4(hashSellOrder(order));
  }

  function DOMAIN_SEPARATOR() external view returns (bytes32) {
    return _domainSeparatorV4();
  }

  /*///////////////////////////////////////////////////////////////
                           INTERNAL: TRADING
  //////////////////////////////////////////////////////////////*/

  function _isGraduated(address token) private view returns (bool graduated) {
    uint256 x;
    (x,,,,,, graduated) = PORTAL.markets(token);
    if (x == 0) revert UnknownToken();
  }

  /// @dev 用 `amountIn` 的 BNB 买币，币留在本合约。返回买到的数量与没用完的 BNB（毕业退款 / 兑换剩余）。
  ///      Portal 把代币和毕业退款都打给 `to`，所以 `to` 必须是本合约，退款才能存回池；代币随后再转给隐身地址。
  function _buy(
    address token,
    uint256 amountIn,
    uint256 minTokensOut
  ) private returns (uint256 tokensOut, uint256 leftover) {
    bool graduated = _isGraduated(token);
    uint256 tokenBefore = IERC20(token).balanceOf(address(this));
    uint256 bnbBefore = address(this).balance;
    _acceptingProceeds = true;

    if (!graduated) {
      PORTAL.buy{value: amountIn}(token, minTokensOut, address(this));
      leftover = address(this).balance + amountIn - bnbBefore;
    } else {
      uint256 wbnbBefore = WBNB.balanceOf(address(this));
      WBNB.deposit{value: amountIn}();
      IERC20(address(WBNB)).forceApprove(address(ROUTER), amountIn);
      ROUTER.exactInputSingle(
        ISwapRouter.ExactInputSingleParams({
          tokenIn: address(WBNB),
          tokenOut: token,
          fee: POOL_FEE,
          recipient: address(this),
          deadline: block.timestamp,
          amountIn: amountIn,
          amountOutMinimum: minTokensOut,
          sqrtPriceLimitX96: 0
        })
      );
      IERC20(address(WBNB)).forceApprove(address(ROUTER), 0);
      leftover = WBNB.balanceOf(address(this)) - wbnbBefore;
      if (leftover != 0) WBNB.withdraw(leftover);
    }

    _acceptingProceeds = false;
    tokensOut = IERC20(token).balanceOf(address(this)) - tokenBefore;
    if (tokensOut == 0 || tokensOut < minTokensOut) revert Slippage(tokensOut, minTokensOut);
  }

  /// @dev 卖出本合约持有的 `amountIn` 个币，返回得到的 BNB（未扣中继费）
  function _sell(address token, uint256 amountIn, uint256 minBnbOut) private returns (uint256 bnbOut) {
    bool graduated = _isGraduated(token);
    uint256 bnbBefore = address(this).balance;
    _acceptingProceeds = true;

    if (!graduated) {
      IERC20(token).forceApprove(address(PORTAL), amountIn);
      PORTAL.sell(token, amountIn, minBnbOut, address(this));
      IERC20(token).forceApprove(address(PORTAL), 0);
      bnbOut = address(this).balance - bnbBefore;
    } else {
      uint256 wbnbBefore = WBNB.balanceOf(address(this));
      IERC20(token).forceApprove(address(ROUTER), amountIn);
      ROUTER.exactInputSingle(
        ISwapRouter.ExactInputSingleParams({
          tokenIn: token,
          tokenOut: address(WBNB),
          fee: POOL_FEE,
          recipient: address(this),
          deadline: block.timestamp,
          amountIn: amountIn,
          amountOutMinimum: minBnbOut,
          sqrtPriceLimitX96: 0
        })
      );
      IERC20(token).forceApprove(address(ROUTER), 0);
      bnbOut = WBNB.balanceOf(address(this)) - wbnbBefore;
      if (bnbOut != 0) WBNB.withdraw(bnbOut);
    }

    _acceptingProceeds = false;
    if (bnbOut == 0 || bnbOut < minBnbOut) revert Slippage(bnbOut, minBnbOut);
  }

  /// @dev 路由没有吃完的代币退回持有者。只退这次多出来的，不动调用前就已经在合约里的余额。
  function _refundTokenDust(address holder, address token, uint256 tokenBefore) private {
    uint256 bal = IERC20(token).balanceOf(address(this));
    if (bal > tokenBefore) IERC20(token).safeTransfer(holder, bal - tokenBefore);
  }

  /// @dev 取 holder 的币：额度不够就用 permit 补。permit 被别人抢先执行也没关系，只要最终额度够。
  ///      调用没有回滚数据，说明代币没有 permit（已部署的 VeilToken 就是这样）；有回滚数据则原样抛出。
  function _pullTokens(address holder, address token, uint256 amount, PermitData calldata permit) private {
    IERC20 erc20 = IERC20(token);
    if (erc20.allowance(holder, address(this)) < amount) {
      (bool permitted, bytes memory reason) = token.call(
        abi.encodeCall(
          IERC20Permit.permit, (holder, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s)
        )
      );
      if (!permitted) {
        if (reason.length == 0) revert PermitUnsupported(token);
        assembly ('memory-safe') {
          revert(add(reason, 0x20), mload(reason))
        }
      }
      if (erc20.allowance(holder, address(this)) < amount) revert InsufficientAllowance(token);
    }

    uint256 balanceBefore = erc20.balanceOf(address(this));
    erc20.safeTransferFrom(holder, address(this), amount);
    if (erc20.balanceOf(address(this)) - balanceBefore != amount) revert UnexpectedTokenTransfer();
  }

  /*///////////////////////////////////////////////////////////////
                         INTERNAL: FEES & DEPOSIT
  //////////////////////////////////////////////////////////////*/

  function _checkRelayFee(uint256 relayFeeBPS, address feeRecipient) private view {
    (,,, uint256 maxRelayFeeBPS) = ENTRYPOINT.assetConfig(IERC20(Constants.NATIVE_ASSET));
    if (relayFeeBPS > maxRelayFeeBPS) revert RelayFeeGreaterThanMax();
    if (relayFeeBPS != 0 && feeRecipient == address(0)) revert InvalidFeeRecipient();
  }

  function _payRelayFee(uint256 amount, uint256 relayFeeBPS, address feeRecipient) private returns (uint256 fee) {
    fee = (amount * relayFeeBPS) / _BPS;
    if (fee != 0) _sendBnb(feeRecipient, fee);
  }

  /// @notice 把 `amount` 拆成标准份额。返回每一份要交给 Entrypoint 的毛额（扣费后净额恰好是份额），以及拆不下的零头。
  /// @dev `grossForExactNet` 取的是最小毛额。份额按 1、0.5、0.1、0.05、0.01 BNB 先大后小，最多 `MAX_STANDARD_DEPOSITS` 份。
  function splitStandardLots(
    uint256 amount,
    uint256 vettingFeeBPS,
    uint256 minimumDeposit
  ) public pure returns (uint256[] memory grossAmounts, uint256 remainder) {
    if (vettingFeeBPS >= _BPS) revert InvalidVettingFee();
    uint256[5] memory lots = [_LOT_1, _LOT_1_2, _LOT_1_10, _LOT_1_20, _LOT_1_100];
    uint256[] memory buffer = new uint256[](MAX_STANDARD_DEPOSITS);
    uint256 count;
    remainder = amount;
    for (uint256 i; i < lots.length && count < MAX_STANDARD_DEPOSITS; ++i) {
      uint256 gross = grossForExactNet(lots[i], vettingFeeBPS);
      // 更小的份额毛额更小，连这一档都达不到最小存款额时，后面的也不用再试。
      if (gross < minimumDeposit) break;
      while (count < MAX_STANDARD_DEPOSITS && remainder >= gross) {
        buffer[count] = gross;
        remainder -= gross;
        ++count;
      }
    }
    grossAmounts = new uint256[](count);
    for (uint256 i; i < count; ++i) {
      grossAmounts[i] = buffer[i];
    }
  }

  /// @notice 最小的 `gross`，使得 `gross - floor(gross * feeBps / 10000) == net`。
  /// @dev 审核费向下取整，同一个净额偶尔对应两个毛额；取较小的那个，多出来的 1 wei 留给用户。
  ///      令 fee = gross - net，则 fee 是满足 fee > (net * feeBps - 10000) / (10000 - feeBps)
  ///      且 fee <= net * feeBps / (10000 - feeBps) 的最小整数。
  function grossForExactNet(uint256 net, uint256 feeBps) public pure returns (uint256) {
    if (feeBps >= _BPS) revert InvalidVettingFee();
    if (feeBps == 0 || net == 0) return net;
    uint256 denom = _BPS - feeBps;
    uint256 prod = net * feeBps;
    uint256 lower = prod < _BPS ? 0 : (prod - _BPS) / denom + 1;
    return net + lower;
  }

  struct NativeConfig {
    IPrivacyPool pool;
    uint256 minimumDeposit;
    uint256 vettingFeeBPS;
  }

  function _nativeConfig() private view returns (NativeConfig memory config) {
    (config.pool, config.minimumDeposit, config.vettingFeeBPS,) = ENTRYPOINT.assetConfig(IERC20(Constants.NATIVE_ASSET));
  }

  /// @dev 把 `amount` 按标准份额存回池。`saleToken == address(0)` 表示买入找零，不发 `SoldPrivately`。
  ///      池关了或没有原生币池：整笔 `PaidOutInstead`。某一份的承诺不可用：只把那一份 `PaidOutInstead`，其余继续。
  ///      承诺数组比实际份数短：整笔回滚（调用方必须为每一份准备承诺）。比 8 长：在入口处已经拒绝。
  function _settleProceeds(
    uint256 amount,
    uint256[] memory precommitments,
    address fallbackTo,
    address saleToken,
    uint256 tokensIn,
    uint256 bnbOut
  ) private {
    if (precommitments.length > MAX_STANDARD_DEPOSITS) {
      revert TooManyPrecommitments(precommitments.length);
    }
    if (amount == 0) return;

    NativeConfig memory config = _nativeConfig();
    if (address(config.pool) == address(0) || config.pool.dead()) {
      _sendBnb(fallbackTo, amount);
      emit PaidOutInstead(fallbackTo, amount);
      return;
    }

    (uint256[] memory grosses, uint256 remainder) =
      splitStandardLots(amount, config.vettingFeeBPS, config.minimumDeposit);
    if (precommitments.length < grosses.length) {
      revert NotEnoughPrecommitments(precommitments.length, grosses.length);
    }
    _settleLots(config.pool, grosses, precommitments, fallbackTo, saleToken, tokensIn, bnbOut);
    if (remainder != 0) {
      _sendBnb(fallbackTo, remainder);
      emit RemainderPaid(fallbackTo, remainder);
    }
  }

  function _settleLots(
    IPrivacyPool pool,
    uint256[] memory grosses,
    uint256[] memory precommitments,
    address fallbackTo,
    address saleToken,
    uint256 tokensIn,
    uint256 bnbOut
  ) private {
    for (uint256 i; i < grosses.length; ++i) {
      _settleLot(pool, grosses[i], precommitments[i], fallbackTo, saleToken, tokensIn, bnbOut);
    }
  }

  function _settleLot(
    IPrivacyPool pool,
    uint256 gross,
    uint256 precommitment,
    address fallbackTo,
    address saleToken,
    uint256 tokensIn,
    uint256 bnbOut
  ) private {
    if (precommitment == 0 || ENTRYPOINT.usedPrecommitments(precommitment)) {
      _sendBnb(fallbackTo, gross);
      emit PaidOutInstead(fallbackTo, gross);
      return;
    }
    if (saleToken != address(0)) emit SoldPrivately(saleToken, fallbackTo, tokensIn, bnbOut, precommitment);
    _depositLot(pool, gross, precommitment, fallbackTo);
  }

  /// @dev 以 `gross` 存入。调用方已经确认承诺可用、池还活着、毛额不低于最小存款额。
  function _depositLot(IPrivacyPool pool, uint256 gross, uint256 precommitment, address fallbackTo) private {
    ENTRYPOINT.deposit{value: gross}(precommitment);

    uint256 label = uint256(keccak256(abi.encodePacked(pool.SCOPE(), pool.nonce()))) % Constants.SNARK_SCALAR_FIELD;
    if (pool.depositors(label) != address(this) || refunds[label].to != address(0)) revert LabelMismatch();
    refunds[label] = Refund({pool: address(pool), to: fallbackTo});

    emit Redeposited(label, precommitment, gross);
  }

  function _sendBnb(address to, uint256 amount) private {
    (bool success,) = to.call{value: amount}('');
    if (!success) revert TransferFailed();
  }
}
