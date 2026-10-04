// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VeilDonation
/// @notice 隐私捐款：公开每个活动的捐款总额和笔数，不记录捐款人。
///         - 不托管资金：每笔捐款立即转给活动收款地址，合约里不留钱；
///         - 不记录捐款人：事件里没有捐款人地址。建议经隐私层（RAILGUN Relay Adapt）调用，链上的调用者就是隐私层合约；
///         - 可选择性证明：捐款时可附一个凭证哈希 H(secret)，以后只向需要的人出示 secret，就能证明“这笔是我捐的”。
///         - 没有平台手续费。
contract VeilDonation is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_TITLE_LENGTH = 64;

    struct Campaign {
        address recipient;
        bool active;
        uint64 donations;
        uint256 totalBnb;
        string title;
    }

    uint256 public nextCampaignId = 1;
    mapping(uint256 id => Campaign) public campaigns;
    mapping(uint256 id => mapping(address token => uint256)) public totalToken;
    /// @dev key = keccak256(receiptHash, campaignId, token)；按活动和币种分开累计，别人无法用同一凭证干扰你的捐款
    mapping(bytes32 key => uint256 amount) public receiptAmount;

    event CampaignCreated(uint256 indexed id, address indexed recipient, string title);
    event CampaignClosed(uint256 indexed id);
    event Donated(uint256 indexed id, address indexed token, uint256 amount, bytes32 receiptHash);

    error ZeroAddress();
    error ZeroAmount();
    error TitleTooLong();
    error UnknownCampaign();
    error CampaignInactive();
    error OnlyRecipient();
    error TransferFailed();

    function createCampaign(address recipient, string calldata title) external returns (uint256 id) {
        if (recipient == address(0)) revert ZeroAddress();
        if (bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong();
        id = nextCampaignId++;
        campaigns[id] = Campaign({recipient: recipient, active: true, donations: 0, totalBnb: 0, title: title});
        emit CampaignCreated(id, recipient, title);
    }

    function closeCampaign(uint256 id) external {
        Campaign storage c = _campaign(id);
        if (msg.sender != c.recipient) revert OnlyRecipient();
        c.active = false;
        emit CampaignClosed(id);
    }

    /// @param receiptHash 可选（传 0 表示不留凭证）。= keccak256(abi.encode(secret))
    function donate(uint256 id, bytes32 receiptHash) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        Campaign storage c = _active(id);
        c.totalBnb += msg.value;
        c.donations += 1;
        _recordReceipt(receiptHash, id, address(0), msg.value);
        emit Donated(id, address(0), msg.value, receiptHash);
        (bool ok,) = c.recipient.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice 捐 ERC20（如 USDT）；调用者需先 approve
    function donateToken(uint256 id, IERC20 token, uint256 amount, bytes32 receiptHash) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (address(token) == address(0)) revert ZeroAddress();
        Campaign storage c = _active(id);
        totalToken[id][address(token)] += amount;
        c.donations += 1;
        _recordReceipt(receiptHash, id, address(token), amount);
        emit Donated(id, address(token), amount, receiptHash);
        token.safeTransferFrom(msg.sender, c.recipient, amount);
    }

    /// @notice 验证凭证：出示 secret，返回用它在该活动、该币种上累计捐了多少（token 传 0 表示 BNB）
    function verifyReceipt(bytes32 secret, uint256 id, address token) external view returns (uint256) {
        return receiptAmount[_receiptKey(keccak256(abi.encode(secret)), id, token)];
    }

    function _recordReceipt(bytes32 receiptHash, uint256 id, address token, uint256 amount) private {
        if (receiptHash == bytes32(0)) return;
        receiptAmount[_receiptKey(receiptHash, id, token)] += amount;
    }

    function _receiptKey(bytes32 receiptHash, uint256 id, address token) private pure returns (bytes32) {
        return keccak256(abi.encode(receiptHash, id, token));
    }

    function _campaign(uint256 id) private view returns (Campaign storage c) {
        c = campaigns[id];
        if (c.recipient == address(0)) revert UnknownCampaign();
    }

    function _active(uint256 id) private view returns (Campaign storage c) {
        c = _campaign(id);
        if (!c.active) revert CampaignInactive();
    }
}
