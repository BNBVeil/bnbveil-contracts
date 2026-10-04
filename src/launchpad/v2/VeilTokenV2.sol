// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VeilToken} from "../VeilToken.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title VeilTokenV2
/// @notice VeilToken 的全部规则，另加 EIP-2612 permit。固定总量、无税、无增发、无黑名单、不可升级；
///         毕业前禁止向 PancakeSwap 池地址转入。
/// @dev EIP-1167 克隆与实现合约共用实现的 bytecode，构造函数里的 immutable 会钉在实现合约上，
///      不能用来保存每个克隆的名称。域名用 initialize 写入的 name、版本 "1"、当前 chainId 和代币地址现算。
///      链分叉后 chainId 变化，DOMAIN_SEPARATOR 跟着变，旧签名不能重放。
contract VeilTokenV2 is VeilToken, IERC20Permit, IERC5267 {
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @notice EIP-712 域版本，固定为 "1"
    string public constant VERSION = "1";

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _HASHED_VERSION = keccak256(bytes("1"));

    mapping(address => uint256) public nonces;

    error ERC2612ExpiredSignature(uint256 deadline);
    error ERC2612InvalidSigner(address signer, address owner);

    /// @inheritdoc IERC20Permit
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);

        uint256 nonce = nonces[owner];
        unchecked {
            nonces[owner] = nonce + 1;
        }

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR(), structHash), v, r, s);
        if (signer != owner) revert ERC2612InvalidSigner(signer, owner);
        if (spender == address(0)) revert ZeroAddress();

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /// @inheritdoc IERC20Permit
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(_DOMAIN_TYPEHASH, keccak256(bytes(name)), _HASHED_VERSION, block.chainid, address(this))
            );
    }

    /// @inheritdoc IERC5267
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory eipName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", name, VERSION, block.chainid, address(this), bytes32(0), new uint256[](0));
    }
}
