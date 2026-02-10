# Angstrom L2

This repository contains the core contracts for the L2 Angstrom hook.

## Build

```shell
$ forge build
```

## Test

```shell
$ forge test
```

## Deployment

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed
- [vanity-miner-rust](https://github.com/xenide/vanity-miner-rust) for mining CREATE3 vanity addresses (used with [sub-zero-contracts](https://github.com/Philogy/sub-zero-contracts))
- Wallet with funds on the target chain

### Vanity Address Mining

We use `vanity-miner-rust` to mine a salt for CREATE3 deployment that results in a desired address property (e.g., leading zeros).

```shell
$ cargo run --release -- --owner <DEPLOYER_ADDRESS> --zeros 6
```

This outputs a `DEPLOY_TOKEN_ID` and `DEPLOY_TOKEN_NONCE` used by the deploy script.

### Signing EIP-712 permit for giving up token  

To sign the permit to give up vanity token so that we can call `SUB_ZERO.claimGivenUpWithSig`, use the following command:

```shell
$ cast wallet sign --data --from-file script/eip712.json
```

Adjust the `script/eip712.json` file with the correct `DEPLOY_TOKEN_ID` and `nonce` accordingly. 
With the output signature, update the signature in the deployment script.

### Network Configuration

Reference `script/config.toml` — currently configured for Base and Unichain with their respective Uniswap V4 PoolManager addresses.

### Deploy Factory

The factory deployment script (`script/AngstromL2Factory.s.sol`) handles:
- Deploying the Huff-based hook address miner
- Claiming the vanity token from Sub Zero (if not already minted)
- Deploying `AngstromL2Factory` via `SUB_ZERO.deploy()`

```shell
$ forge script script/AngstromL2Factory.s.sol --broadcast --sender <SENDER>
```

### Security

- See [audits](./audits) for a list of audits done previously
- See [SECURITY.md](./SECURITY.md) for security policies and disclosures.
