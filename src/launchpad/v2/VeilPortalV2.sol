// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {VeilTokenV2} from "./VeilTokenV2.sol";
import {DevLock} from "../DevLock.sol";
import {CurveMath} from "../CurveMath.sol";
import {INonfungiblePositionManager, IPancakeV3Pool, IWBNB} from "../interfaces/IPancakeV3.sol";

/// @title VeilPortalV2
/// @notice 规则与已部署的 VeilPortal 相同：开发者 ≤5%、单笔 ≤3%、16 BNB 毕业、按毕业价初始化 V3 池、LP 销毁。
///         代币模板换成带 EIP-2612 permit 的 VeilTokenV2。合约不检查调用者身份。
///         买卖函数都带 `to` 参数、不依赖 msg.sender 身份，因此可以被隐私层（如 RAILGUN Relay Adapt）
///         在“解屏蔽 → 买卖 → 重新屏蔽”的同一笔交易里调用，链上的交易者就是隐私层合约而不是个人地址。
contract VeilPortalV2 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ---------------- 常量（发射规则，部署后不可改） ---------------- */
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant VIRTUAL_BNB = 8 ether;
    uint256 public constant VIRTUAL_TOKEN = 1_073_000_000 ether;
    uint256 public constant GRADUATE_BNB = 16 ether;
    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 100; // 曲线手续费 1%
    uint256 public constant DEV_CAP_BPS = 500; // 开发者硬上限 5%
    uint256 public constant MAX_TX_BPS = 300; // 曲线期单笔买入 ≤ 3%
    uint64 public constant DEV_LOCK_DURATION = 30 days;
    uint24 public constant POOL_FEE = 2500; // PancakeSwap V3 0.25% 档
    /// @dev 事件里的字符串大约 8 gas/字节，1024 字节约 1 万 gas，再长就回滚
    uint256 public constant MAX_METADATA_URI_BYTES = 1024;
    int24 public constant TICK_LOWER = -887250; // 全区间（tickSpacing = 50）
    int24 public constant TICK_UPPER = 887250;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /* ---------------- 外部依赖 ---------------- */
    address public immutable tokenImplementation;
    address public immutable devLockImplementation;
    INonfungiblePositionManager public immutable positionManager;
    IWBNB public immutable wbnb;

    address public feeRecipient;
    /// @notice 尚未提取的手续费合计。买卖和毕业尘埃只在这里记账，不在交易过程中转出。
    uint256 public accruedFees;
    /// @notice 记在某个接收方名下的未提取手续费。归属在费用发生时按当时的 feeRecipient 写定。
    mapping(address recipient => uint256 amount) public feesOf;

    struct Market {
        uint256 x; // 虚拟 + 已募集 BNB
        uint256 y; // 曲线剩余（含虚拟）代币
        uint256 raised; // 已募集净 BNB（不含手续费）
        uint256 sold; // 已售出代币
        address pool; // 预先初始化的 PancakeSwap V3 池
        address devLock;
        bool graduated;
    }

    mapping(address token => Market) public markets;

    /* ---------------- 事件 ---------------- */
    event TokenCreated(
        address indexed token,
        address indexed devLock,
        address pool,
        uint256 devTokens,
        string name,
        string symbol,
        string metadataURI
    );
    event Trade(
        address indexed token,
        address indexed to,
        bool isBuy,
        uint256 bnbAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 raised
    );
    event Graduated(
        address indexed token,
        address indexed pool,
        uint256 lpTokenId,
        uint256 bnbLiquidity,
        uint256 tokenLiquidity,
        uint256 burned
    );
    event FeeRecipientUpdated(address indexed feeRecipient);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    /* ---------------- 错误 ---------------- */
    error DevCapExceeded(uint256 devTokens, uint256 cap);
    error TxCapExceeded(uint256 tokensOut, uint256 cap);
    error UnknownToken();
    error AlreadyGraduated();
    error Slippage(uint256 out, uint256 minOut);
    error ZeroAmount();
    error ZeroAddress();
    error PoolPriceMismatch();
    error InsufficientReserve();
    error TransferFailed();
    error MetadataTooLong(uint256 length);

    constructor(INonfungiblePositionManager positionManager_, IWBNB wbnb_, address feeRecipient_, address owner_)
        Ownable(owner_)
    {
        if (address(positionManager_) == address(0) || address(wbnb_) == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        positionManager = positionManager_;
        wbnb = wbnb_;
        feeRecipient = feeRecipient_;
        tokenImplementation = address(new VeilTokenV2());
        devLockImplementation = address(new DevLock());
    }

    /* ======================================================================
                                    建币
       ====================================================================== */

    /// @notice 预测代币地址，前端据此搜索靓号后缀 salt
    function predictTokenAddress(address creator, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(tokenImplementation, _salt(creator, salt), address(this));
    }

    /// @notice 创建代币；msg.value 为开发者首笔买入（可为 0），买到的代币必须 ≤ 5% 总量，否则整笔回滚。
    ///         买到的代币进锁仓合约，30 天内线性释放。
    /// @param devBeneficiary 开发者锁仓受益地址（建议使用隐身地址）
    /// @param metadataURI 代币元数据。最长 1024 字节，超出回滚
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address devBeneficiary,
        string calldata metadataURI
    ) external payable nonReentrant returns (address token) {
        token = _create(name, symbol, salt, devBeneficiary, metadataURI, true);
    }

    /// @notice 同 createToken，但开发者买到的代币直接发给 devBeneficiary，不锁仓。
    ///         事件里 devLock 为零地址，买家可以据此看出开发者持仓没有锁。5% 上限不变。
    function createTokenUnlocked(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address devBeneficiary,
        string calldata metadataURI
    ) external payable nonReentrant returns (address token) {
        token = _create(name, symbol, salt, devBeneficiary, metadataURI, false);
    }

    function _create(
        string calldata name,
        string calldata symbol,
        bytes32 salt,
        address devBeneficiary,
        string calldata metadataURI,
        bool lockDev
    ) internal returns (address token) {
        if (devBeneficiary == address(0)) revert ZeroAddress();
        if (bytes(metadataURI).length > MAX_METADATA_URI_BYTES) revert MetadataTooLong(bytes(metadataURI).length);
        // salt 绑定调用者，防止别人抢注同一个靓号地址
        token = Clones.cloneDeterministic(tokenImplementation, _salt(msg.sender, salt));
        VeilTokenV2(token).initialize(name, symbol, TOTAL_SUPPLY, address(this));
        _openMarket(token, name, symbol, devBeneficiary, metadataURI, lockDev);
    }

    /// @dev 和 createToken 拆开，避免再带上 salt 时栈太深
    function _openMarket(
        address token,
        string calldata name,
        string calldata symbol,
        address devBeneficiary,
        string calldata metadataURI,
        bool lockDev
    ) internal {
        Market storage m = markets[token];
        m.x = VIRTUAL_BNB;
        m.y = VIRTUAL_TOKEN;
        m.pool = _initPool(token);
        VeilTokenV2(token).setDexPool(m.pool);
        uint256 devTokens = _takeDevBuy(m, msg.value);
        address lock = lockDev ? _lockDev(token, devTokens, devBeneficiary) : _payDev(token, devTokens, devBeneficiary);
        emit TokenCreated(token, lock, m.pool, devTokens, name, symbol, metadataURI);
    }

    function _lockDev(address token, uint256 devTokens, address devBeneficiary) internal returns (address lock) {
        lock = Clones.clone(devLockImplementation);
        markets[token].devLock = lock;
        if (devTokens > 0) IERC20(token).safeTransfer(lock, devTokens);
        DevLock(lock).initialize(IERC20(token), devBeneficiary, devTokens, DEV_LOCK_DURATION);
    }

    /// @dev 不锁仓：devLock 留空，代币直接给受益地址。
    function _payDev(address token, uint256 devTokens, address devBeneficiary) internal returns (address) {
        if (devTokens > 0) IERC20(token).safeTransfer(devBeneficiary, devTokens);
        return address(0);
    }

    function _takeDevBuy(Market storage m, uint256 value) internal returns (uint256 devTokens) {
        if (value == 0) return 0;
        uint256 fee = (value * FEE_BPS) / BPS;
        uint256 net = value - fee;
        devTokens = CurveMath.tokensForBnb(m.x, m.y, net);
        uint256 cap = (TOTAL_SUPPLY * DEV_CAP_BPS) / BPS;
        if (devTokens > cap) revert DevCapExceeded(devTokens, cap);
        _applyBuy(m, net, devTokens);
        _accrue(fee);
    }

    /* ======================================================================
                                    交易
       ====================================================================== */

    /// @notice 买入。达到毕业额时只吃到刚好毕业所需的 BNB，多余部分退回 `to`，然后自动毕业
    function buy(address token, uint256 minTokensOut, address to)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        Market storage m = _open(token);

        uint256 fee = (msg.value * FEE_BPS) / BPS;
        uint256 net = msg.value - fee;
        uint256 refund;
        uint256 remaining = GRADUATE_BNB - m.raised;
        if (net >= remaining) {
            net = remaining;
            uint256 gross = CurveMath.ceilDiv(net * BPS, BPS - FEE_BPS);
            if (gross > msg.value) gross = msg.value;
            fee = gross - net;
            refund = msg.value - gross;
        }

        tokensOut = CurveMath.tokensForBnb(m.x, m.y, net);
        uint256 cap = (TOTAL_SUPPLY * MAX_TX_BPS) / BPS;
        if (tokensOut > cap) revert TxCapExceeded(tokensOut, cap);
        if (tokensOut < minTokensOut) revert Slippage(tokensOut, minTokensOut);

        _applyBuy(m, net, tokensOut);
        _accrue(fee);
        emit Trade(token, to, true, net + fee, tokensOut, fee, m.raised);

        IERC20(token).safeTransfer(to, tokensOut);
        if (m.raised >= GRADUATE_BNB) _graduate(token, m);
        // 退款放在最后：把 BNB 交给外部地址之前，毕业等所有状态都已落定
        if (refund > 0) _sendBnb(to, refund);
    }

    /// @notice 卖出。调用者需事先 approve，或由持币人 permit 给本合约后再自己调用
    function sell(address token, uint256 tokensIn, uint256 minBnbOut, address to)
        external
        nonReentrant
        returns (uint256 bnbOut)
    {
        if (tokensIn == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        Market storage m = _open(token);

        uint256 gross = CurveMath.bnbForSell(m.x, m.y, tokensIn);
        if (gross > m.raised) revert InsufficientReserve();
        uint256 fee = (gross * FEE_BPS) / BPS;
        bnbOut = gross - fee;
        if (bnbOut < minBnbOut) revert Slippage(bnbOut, minBnbOut);

        m.x -= gross;
        m.y += tokensIn;
        m.raised -= gross;
        m.sold -= tokensIn;
        _accrue(fee);
        emit Trade(token, to, false, gross, tokensIn, fee, m.raised);

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        _sendBnb(to, bnbOut);
    }

    /* ---------------- 报价 ---------------- */

    function quoteBuy(address token, uint256 bnbIn) external view returns (uint256 tokensOut, uint256 refund) {
        Market storage m = markets[token];
        if (m.x == 0) revert UnknownToken();
        if (m.graduated) revert AlreadyGraduated();
        uint256 net = bnbIn - (bnbIn * FEE_BPS) / BPS;
        uint256 remaining = GRADUATE_BNB - m.raised;
        if (net >= remaining) {
            net = remaining;
            uint256 gross = CurveMath.ceilDiv(net * BPS, BPS - FEE_BPS);
            refund = bnbIn > gross ? bnbIn - gross : 0;
        }
        tokensOut = CurveMath.tokensForBnb(m.x, m.y, net);
    }

    /// @notice 当前单笔最多能投入多少 BNB（含手续费）而不触发 3% 单笔上限；留 1% 余量吸收取整误差
    function maxBuyBnb(address token) external view returns (uint256) {
        Market storage m = markets[token];
        if (m.x == 0) revert UnknownToken();
        if (m.graduated) return 0;
        uint256 cap = (TOTAL_SUPPLY * MAX_TX_BPS) / BPS;
        uint256 net = CurveMath.bnbForTokens(m.x, m.y, cap);
        return (net * 99 * BPS) / (100 * (BPS - FEE_BPS));
    }

    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 bnbOut) {
        Market storage m = markets[token];
        if (m.x == 0) revert UnknownToken();
        if (m.graduated) revert AlreadyGraduated();
        uint256 gross = CurveMath.bnbForSell(m.x, m.y, tokensIn);
        bnbOut = gross - (gross * FEE_BPS) / BPS;
    }

    /// @notice 毕业时的目标价格（与路径无关：x 永远等于 虚拟BNB + 已募集）
    function graduationSqrtPriceX96(address token) public view returns (uint160) {
        uint256 xG = VIRTUAL_BNB + GRADUATE_BNB;
        uint256 yG = CurveMath.ceilDiv(VIRTUAL_BNB * VIRTUAL_TOKEN, xG);
        // 价格 = xG / yG（BNB / 代币），按 token0/token1 排序转换
        (uint256 num, uint256 den) = token < address(wbnb) ? (xG, yG) : (yG, xG);
        return uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
    }

    /* ---------------- 管理 ---------------- */

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    /// @notice 把当前 feeRecipient 名下已累计的手续费转给该地址。任何人都可以代为触发。
    ///         不包含以前的接收方名下尚未提取的金额；更换 feeRecipient 不会改写那些份额。
    function withdrawFees() external nonReentrant {
        _withdrawFees(feeRecipient);
    }

    /// @notice 把 `recipient` 名下已累计的手续费转给该地址。转账失败只回滚这次提取。
    function withdrawFees(address recipient) external nonReentrant {
        _withdrawFees(recipient);
    }

    /* ======================================================================
                                    内部
       ====================================================================== */

    function _open(address token) private view returns (Market storage m) {
        m = markets[token];
        if (m.x == 0) revert UnknownToken();
        if (m.graduated) revert AlreadyGraduated();
    }

    function _applyBuy(Market storage m, uint256 net, uint256 tokensOut) private {
        m.x += net;
        m.y -= tokensOut;
        m.raised += net;
        m.sold += tokensOut;
    }

    /// @dev 发币时就按“毕业价”创建并初始化池子；配合代币的 PoolLocked 规则，毕业前池价无法被操纵。
    ///      如果有人抢先用别的价格初始化了同一个池子，这里直接回滚（换个 salt 重新发即可）。
    function _initPool(address token) private returns (address pool) {
        (address t0, address t1) = token < address(wbnb) ? (token, address(wbnb)) : (address(wbnb), token);
        uint160 target = graduationSqrtPriceX96(token);
        pool = positionManager.createAndInitializePoolIfNecessary(t0, t1, POOL_FEE, target);
        (uint160 current,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (current != target) revert PoolPriceMismatch();
    }

    function _graduate(address token, Market storage m) private {
        m.graduated = true;
        VeilTokenV2(token).markGraduated();

        uint256 bnbLiq = m.raised;
        // 按最终曲线价配比代币：tokens = raised * y / x
        uint256 tokenLiq = Math.mulDiv(bnbLiq, m.y, m.x);
        (uint256 lpId, uint256 usedToken, uint256 usedBnb) = _mintFullRange(token, tokenLiq, bnbLiq);

        // LP 销毁：NFT 转入黑洞地址，流动性永久锁定
        positionManager.transferFrom(address(this), DEAD, lpId);

        // 未用完的 WBNB 尘埃解包后记入当时的手续费，不在毕业交易里转给接收方
        uint256 dust = wbnb.balanceOf(address(this));
        if (dust > 0) {
            wbnb.withdraw(dust);
            _accrue(dust);
        }
        uint256 leftover = VeilTokenV2(token).balanceOf(address(this));
        if (leftover > 0) VeilTokenV2(token).burnFromPortal(leftover);

        emit Graduated(token, m.pool, lpId, usedBnb, usedToken, leftover);
    }

    function _mintFullRange(address token, uint256 tokenLiq, uint256 bnbLiq)
        private
        returns (uint256 lpId, uint256 usedToken, uint256 usedBnb)
    {
        wbnb.deposit{value: bnbLiq}();
        IERC20(address(wbnb)).forceApprove(address(positionManager), bnbLiq);
        IERC20(token).forceApprove(address(positionManager), tokenLiq);

        bool tokenIs0 = token < address(wbnb);
        (uint256 a0, uint256 a1) = tokenIs0 ? (tokenLiq, bnbLiq) : (bnbLiq, tokenLiq);
        (uint256 id,, uint256 used0, uint256 used1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIs0 ? token : address(wbnb),
                token1: tokenIs0 ? address(wbnb) : token,
                fee: POOL_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: (a0 * 99) / 100,
                amount1Min: (a1 * 99) / 100,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        IERC20(token).forceApprove(address(positionManager), 0);
        IERC20(address(wbnb)).forceApprove(address(positionManager), 0);
        (lpId, usedToken, usedBnb) = tokenIs0 ? (id, used0, used1) : (id, used1, used0);
    }

    /// @dev 只接受本合约调用 WBNB.withdraw 时退回的尘埃。其他直接转账会让余额偏离储备加未提取手续费。
    receive() external payable {
        if (msg.sender != address(wbnb)) revert TransferFailed();
    }

    function _accrue(uint256 fee) private {
        if (fee == 0) return;
        accruedFees += fee;
        feesOf[feeRecipient] += fee;
    }

    function _withdrawFees(address recipient) private {
        uint256 amount = feesOf[recipient];
        if (amount == 0) revert ZeroAmount();
        feesOf[recipient] = 0;
        accruedFees -= amount;
        emit FeesWithdrawn(recipient, amount);
        _sendBnb(recipient, amount);
    }

    function _sendBnb(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}
