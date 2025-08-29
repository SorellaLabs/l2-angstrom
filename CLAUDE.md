# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Angstrom L2 is a Uniswap V4 hook-based MEV protection system for rollups with priority fee ordering. Unlike the original Angstrom, L2 operates entirely on-chain through hooks, leveraging the rollup's priority fee auction mechanism for MEV protection.

## Key Architecture Changes (L2 vs Original)

- **Hook-Only Design**: No off-chain components or custom order types - all functionality through Uniswap V4 hooks
- **On-Chain ToB Calculation**: Top-of-block bid calculation happens entirely within the hook
- **Priority Fee MEV Tax**: Protection via `tax = priority_fee * assumed_gas * tax_multiple`
- **Rollup-Specific**: Only deployable to rollups adhering to priority fee ordering

## Key Commands

### Build & Test

```bash
# Verify everything compiles
forge build

# Test (FFI required for Python scripts)
forge test # Run all tests
forge test -vvv # Verbose output
forge test --match-test <name>  # Run specific test
forge test --match-contract <name> # Run specific set of tests

# Format
forge fmt                              # Format Solidity code
```

## Angstrom L2 Implementation

### Core Contract (`src/AngstromL2.sol`)
- Implements `IBeforeSwapHook` and `IAfterSwapHook` from Uniswap V4
- Inherits from `UniConsumer` for Uniswap integration
- Hook permissions configured for MEV tax collection

### MEV Tax Mechanism
```solidity
SWAP_TAXED_GAS = 100_000        // Fixed gas estimate for swaps
SWAP_MEV_TAX_FACTOR = 49        // Tax rate = 49/50 = 98%
tax = priority_fee * SWAP_TAXED_GAS * SWAP_MEV_TAX_FACTOR
```

### Hook Permissions Required
- `beforeInitialize`: Constrain to ETH pools
- `beforeSwap`: Tax ToB transactions
- `afterSwap`: Distribute rewards
- `beforeSwapReturnDelta`: Charge MEV tax
- `afterAddLiquidity/afterRemoveLiquidity`: Tax JIT liquidity
- `afterAddLiquidityReturnDelta/afterRemoveLiquidityReturnDelta`: Charge JIT MEV tax

### Key Functions
- `beforeSwap()`: Calculates and charges MEV tax on first swap of block
- `afterSwap()`: Distributes collected tax to LPs
- `_getSwapTaxAmount()`: Calculates tax based on priority fee


## Reusable Components from Original Angstrom

### Modules (`src/modules/`)
- **UniConsumer.sol**: Base Uniswap V4 integration (already used)
- **PoolUpdates.sol**: Pool state management (may be adapted)

### Libraries (`src/libraries/`)
- **TickLib.sol**: Tick math utilities
- **X128MathLib.sol**: Fixed-point math for rewards
- **RayMathLib.sol**: Ray math for precise calculations

### Types (`src/types/`)
- **PoolRewards.sol**: Reward calculation logic (adaptable for tax distribution)
- **Asset.sol**: Asset pair representation

### Interfaces (`src/interfaces/`)
- **IUniV4.sol**: Interface/library for efficiently retrieving state from Uniswap via it's `extsload` & `exttload` methods (use instead of Uniswap's `StateLibrary.sol`), use this as Uniswap doesn't have view methods for most of its state

## Workflow for Implementing New Features and Components
1. Think about how the new feature is going to be used and plan out appropriate tests
2. Write appropriate unit tests, make sure to test under high fidelity conditions
3. Define any external interface necessary to be able to compile the tests
4. Run the new tests, they should fail
5. Implement the actual feature, progressively run the tests to ensure they pass & everything compiles
6. Task is complete once the feature has sufficient tests, is implemented and all tests pass

## Design Principles

### Security
- The implementation being sound and airtight is the primary concern, everything else is secondary
- Avoid inline assembly unless specified otherwise

#### Additional Testing Guidelines
- Aim for a maximum fidelity environment in tests (real deployments, real transactions to setup desired states)
- leverage existing mocks & helpers for easier testing:
    - `test/_mocks/RouterActor.sol`: Mocks router that can add/remove liquidity & execute swaps
    - `test/_mocks/InvasiveV4.sol`: Uniswap V4 pool manager with real view methods so you can easily query state and compare to result from more optimized "real" state fetchers

### Modularity Through Custom Types & Data Structures
- utility types & data structures should be placed in `src/types`
- type/struct defined at file top-level, next to library with name `library <type name>Lib`
- use `using <type name>Lib for <type name> global;` declaration to ensure methods can easily be used with `value.method` syntax

### Readability & Auditability
- Avoid redundant comments
- If functionality is not self-explanatory, use longer variable & function names and/or split into more functions
- Only use comments to document top-level functions & methods