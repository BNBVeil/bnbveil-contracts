# BNB Veil Contracts

Solidity sources for the BNB Veil launchpad, native-asset privacy pool, and transaction adapters.

## Build

Use Foundry with Solidity **0.8.28**. The build configuration was checked with Forge **1.7.1**.
Install the pinned dependencies from the repository root:

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
