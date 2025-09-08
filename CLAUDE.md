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

```bash
forge test          # Run all tests (Must be run and fully pass to claim a feature is complete)
forge test -vvv     # Verbose output & traces for debugging when tests fail
forge test --match-test <name>  # During development: Run specific tests to speedup iteration
forge test --match-contract <name> # During development: Run specific set of tests to speedup iteration

forge fmt                           # Regularly format to make sure code is clean
forge lint                          # Run regularly to ensure stuff is clean
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

### Key Functions
- `beforeSwap()`: Calculates and charges MEV tax on first swap of block
- `afterSwap()`: Distributes collected tax to LPs
- `_getSwapTaxAmount()`: Calculates tax based on priority fee


## Reusable Components from Original Angstrom
### Modules (`src/modules/`)
- **UniConsumer.sol**: Base Uniswap V4 integration (already used)

### Libraries (`src/libraries/`)
- **TickLib.sol**: Tick math utilities
- **X128MathLib.sol**: Fixed-point math for rewards

### Interfaces (`src/interfaces/`)
- **IUniV4.sol**: Library for efficiently retrieving state from Uniswap's `PoolManager`. `PoolManager` doesn't have view methods so this library provides a local interface that automatically computes the relevant storage slots, dispatches to `extsload` / `exttload` methods and decodes to the appropriate types. Used by importing and then adding a `using IUniV4 for (UniV4Inspector/IPoolManager);` declaration to the library or contract

## Workflow for Implementing New Features and Components
1. Think about how the new feature is going to be used and plan out appropriate tests
2. Write appropriate unit tests, make sure to test under high fidelity conditions
3. Define any external interface necessary to be able to compile the tests
4. Run the new tests, they should fail
5. Implement the actual feature, progressively run the tests to ensure they pass & everything compiles
6. Task is complete once the feature is implemented, has sufficient tests and *all* of the codebase's tests pass including the new ones

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

## General tips
- only use console logs for debugging purposes
- `assertTrue` & `assertFalse` for asserting boolean values
- code should be self explanatory, use more descriptive variable and function names if functionality is unclear
- comments should mainly be used to explain hidden implementation details for problems that intuitively look simple 
- add short descriptions to assertions so we can tell which ones failed if they do
- in business logic use `if (!(condition_expected_to_be_true)) revert <AppropriateCustomError>();` for checks
- in tests use `assertTrue` / `assertFalse` / `assertEq` for test outcomes, use require with an error string to assert conditions for a test utility for example

## Common Mistakes to Avoid
- **Fix Issues Directly**: When encountering bugs or incompatibilities (like version conflicts or ETH handling issues), fix them directly rather than documenting as limitations. You have full permission to modify any file in the codebase to make things work
- **Slot0 Usage**: The `IUniV4.getSlot0()` method returns a `Slot0` struct, not individual components. Access fields using methods like `slot0.sqrtPriceX96()` rather than trying to destructure
- **CREATE2 Factory**: Don't create your own CREATE2 factory - use the existing `_newFactory()` helper from `HookDeployer` or the `CREATE2_FACTORY` constant from forge-std
- **Hook Deployment**: Use the existing `deployAngstromL2` helper from BaseTest rather than trying to manually deploy hooks - it handles the CREATE2 address mining for proper hook permissions
- Cleanup no longer needed console.log statements once you're done
- Use `/// forge-lint: disable-next-line(directives)` to silence lints, only do so if explicitly directed