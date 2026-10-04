# BNB Veil Contracts

Solidity sources for the BNB Veil launchpad, native-asset privacy pool, and transaction adapters.

## Developer first buy

The developer's first buy is capped at **5% of the total token supply**. Locking is **optional**:

- `createToken` sends the developer's purchased tokens to `DevLock`, where they vest linearly over **30 days from token creation**.
- `createTokenUnlocked` sends the purchased tokens directly to `devBeneficiary`, without a lock. In this case, `TokenCreated.devLock` is `address(0)`, so anyone can see on-chain that the developer's first-buy allocation is not locked.

Both creation methods enforce the same 5% first-buy cap.

## Contract source references

Addresses follow the [official contract list](https://bnbveil.fun/#/docs). Match types and compiler settings below are those displayed by BscScan when checked on **2026-10-04**.

| Contract | BscScan | Explorer match | Optimizer runs | EVM target |
| --- | --- | --- | ---: | --- |
| VeilPortalV2 | [Source / code](https://bscscan.com/address/0xa1ee0882c4386a203922861ABD5431cf563C38Ea#code) | Exact Match | 200 | Cancun |
| VeilPoolAdapter | [Source / code](https://bscscan.com/address/0x103eF5E44fdA3688DE112F1a5298F2f2e8D9CeEb#code) | Exact Match | 10,000 | Prague |
| PrivacyPoolSimple | [Source / code](https://bscscan.com/address/0xeBe5DabeB05d2c56cd773980de5E1f07C397f5b8#code) | Exact Match | 10,000 | Prague |
| Entrypoint (ERC1967 proxy) | [Source / code](https://bscscan.com/address/0xc6f67152be54024488Fafa7a15507EE14A3DcCFc#code) | Similar Match | 10,000 | Prague |
| WithdrawalVerifier | [Source / code](https://bscscan.com/address/0xFa1F3642BEc1D745beb8d98A476C5Ac6Ae23E577#code) | Similar Match | 10,000 | Prague |
| CommitmentVerifier | [Source / code](https://bscscan.com/address/0xfe12b521a36f9a67A97846C08229f146372BDddA#code) | Similar Match | 10,000 | Prague |
| VeilDonation | [Source / code](https://bscscan.com/address/0x52BEBF99c51a1A7E72eB5ca8345957c75D846E51#code) | Exact Match | 200 | Cancun |
| VeilPoolDonor | [Source / code](https://bscscan.com/address/0x254336B02e2b26Cf66F11B0c51B5d78C660Af3E3#code) | Exact Match | 10,000 | Prague |
| VeilTokenV2 (template) | [Source / code](https://bscscan.com/address/0xcBf584efF77422fb7Dd93E947513cbc1159a5c33#code) | Similar Match | 200 | Cancun |
| DevLock (template) | [Source / code](https://bscscan.com/address/0x042c036593567cc36c6ef52b9fD8F906a9A372f0#code) | Similar Match | 200 | Cancun |

The Entrypoint link is the ERC1967 proxy address, not the implementation contract. Similar Match and Exact Match are distinct explorer statuses; consult each linked page for its current source and verification details.

All linked source pages display Solidity `0.8.28`. The repository's default build configuration is described below; reproducing a specific deployment requires that deployment's complete compiler input, including its own settings, source paths, linked libraries, and constructor arguments.

## Build

Use Foundry with Solidity **0.8.28**. The build configuration was checked with Forge **1.7.1**.
A fresh clone does not include dependencies. Install the pinned dependencies from the repository root **before** running `forge build`:

```sh
forge install --no-git \
  openzeppelin-contracts=OpenZeppelin/openzeppelin-contracts@rev=c64a1edb67b6e3f4a15cca8909c9482ad33a02b0 \
  openzeppelin-contracts-upgradeable=OpenZeppelin/openzeppelin-contracts-upgradeable@rev=e725abddf1e01cf05ace496e950fc8e243cc7cab \
  zk-kit-solidity=privacy-scaling-explorations/zk-kit.solidity@rev=c3b088411b7b27a297d058c3151aa2dc49b9055f \
  poseidon-solidity=vimwitch/poseidon-solidity@rev=8205c97ec4a35a9adb854b70b2c9ba92668d1304

forge build
```

The revisions correspond to OpenZeppelin Contracts and Contracts Upgradeable **5.4.0**, Lean IMT Solidity **2.0.0**, and Poseidon Solidity **0.0.5**. Dependencies are downloaded into the ignored `lib/` directory, not included in this repository.

## Compiler settings

- Solidity: `0.8.28`
- EVM target: `cancun`
- Optimizer: enabled, `200` runs
- Via IR: disabled
- Bytecode metadata: IPFS hash with CBOR metadata enabled

Reproduction requires the same source paths, dependency revisions, remappings, compiler settings, constructor arguments, and linked libraries. These settings are specified by `foundry.toml` and `remappings.txt`; generated artifacts are not included.

## Source layout

- `src/launchpad/`: Portal V2, token implementations, curve mathematics, developer lock, donation contract, and external interfaces.
- `src/privacy-pool/`: pool entrypoint, native-asset pool, state, proof utilities, verifiers, and interfaces.
- `src/adapter/`: trading and donation adapters and their external interfaces.

## Licenses

Each Solidity file retains its original SPDX identifier and notices. The included files use MIT, Apache-2.0, and GPL-3.0 identifiers; no single license overrides those per-file declarations.
