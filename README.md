# SVR Liquidation Wrapper — ListaDAO Integration on BNB Chain

A lightweight wrapper contract that enables [Chainlink SVR](https://docs.chain.link/data-feeds/svr-feeds) liquidations on [ListaDAO](https://lista.org/) (Moolah Lending) via the [Atlas](https://github.com/FastLane-Labs/atlas) protocol.

## The Problem

ListaDAO's Liquidator contract only accepts liquidation calls from **pre-approved (whitelisted) addresses**. In the Atlas SVR flow, the direct caller is the searcher's solver contract and the transaction is submitted by a Chainlink node operator — neither is a fixed whitelistable address. This wrapper solves that by becoming the single whitelisted address on ListaDAO and validating inbound calls before forwarding them.

## Full SVR Flow

The integration test (`test_svrMetacallOracleUpdateAndLiquidation`) exercises the complete production flow in a single atomic Atlas `metacall`:

```
Chainlink NOP (bundler) submits Atlas metacall
    │
    ▼
1. _preOpsCall (ChainlinkSvrDAppControl)
    ├── Validates bundler is whitelisted (or authorized on oracle)
    ├── Validates userOp.from is the authorized userOp signer
    ├── Validates userOp calls DAppControl.update()
    ├── Validates target oracle is whitelisted
    └── Validates oracle function selector is allowed
    │
    ▼
2. UserOp executes: Oracle Price Update
    ├── ExecutionEnvironment calls DAppControl.update(oracle, callData)
    ├── DAppControl calls ChainlinkSvrDAppExecutor.execute(oracle, callData)
    └── Executor calls Oracle.forward() → price updated on-chain
    │
    ▼
3. SolverOp executes: ListaDAO Liquidation
    ├── Atlas calls winning solver via ExecutionEnvironment
    ├── SolverBase.atlasSolverCall() → SVRListaSolver.executeLiquidation()
    ├── Solver calls SVRLiquidationWrapper.liquidate()
    │   ├── Validates msg.sender is approved solver
    │   ├── Validates tx.origin is approved NOP (= bundler)
    │   └── Forwards to ListaDAO Liquidator
    │       ├── ListaDAO sees wrapper as caller → whitelist passes
    │       ├── Collateral transferred to wrapper
    │       ├── onMorphoLiquidate callback → wrapper pulls loan tokens from solver
    │       └── Wrapper approves Liquidator to pull loan tokens
    └── Collateral forwarded to solver, loan tokens sent to Liquidator
    │
    ▼
4. _allocateValueCall (ChainlinkSvrDAppControl)
    ├── OEV distributed to Fastlane (configurable %)
    ├── OEV distributed to block builder (configurable %)
    └── Remaining OEV sent to protocol destination
```

## Contracts

### Core (to deploy)

| Contract | Location | Description |
|---|---|---|
| `SVRLiquidationWrapper.sol` | `src/` | Core wrapper. Whitelisted on ListaDAO. Validates callers (dual access control), forwards liquidations, handles token routing and Morpho callback. |
| `SVRListaSolver.sol` | `src/` | Atlas solver (inherits `SolverBase`). Called during `metacall`, invokes the wrapper. |

### Chainlink SVR Reference (not ours to deploy)

| Contract | Location | Description |
|---|---|---|
| `ChainlinkSvrDAppControl.sol` | `src/svr/` | Production DAppControl from [atlas-chainlink-external](https://github.com/smartcontractkit/atlas-chainlink-external). Handles preOps validation (bundler, oracle, selector whitelist), OEV allocation, and oracle updates via the executor. |
| `ChainlinkSvrDAppExecutor.sol` | `src/svr/` | Stable executor authorized on oracles. Forwards calls from DAppControl to oracles. Allows DAppControl upgrades without re-authorization. |

### Test Mocks

| Contract | Location | Description |
|---|---|---|
| `MockListaLiquidator.sol` | `src/` | Simulates ListaDAO's whitelisted Morpho-style liquidation with callback. |
| `MockOracle` | `test/` | Simulates a Chainlink oracle with `IAuthorizedForwarder` interface. |

### Key Addresses (BNB Chain Mainnet)

| Contract | Address |
|---|---|
| ListaDAO Moolah (core) | `0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C` |
| ListaDAO Liquidator | `0x6a87C15598929B2db22cF68a9a0dDE5Bf297a59a` |
| BrokerLiquidator | `0x3AA647a1e902833b61E503DbBFbc58992daa4868` |
| Atlas (v1.6.4) | `0x21B7d28B882772A1Cfe633Daee6f42ebb95DeC4E` |
| DappControl | `0x7D50b32444609A9B53BcF208c159C8d0d0767835` |

## Wrapper Functions

| Function | Access | Description |
|---|---|---|
| `liquidate()` | Approved solver + approved NOP | Pass-through to ListaDAO Liquidator with dual validation |
| `onMorphoLiquidate()` | Liquidator only | Callback during liquidation — pulls loan tokens from solver |
| `addApprovedSolver()` | Owner | Register a searcher's solver contract |
| `removeApprovedSolver()` | Owner | Remove a solver from the approved list |
| `addApprovedNOP()` | Owner | Register a Chainlink node operator EOA |
| `removeApprovedNOP()` | Owner | Remove a node operator |
| `recoverToken()` | Owner | Emergency token recovery |

## ChainlinkSvrDAppControl Configuration

The `ChainlinkSvrDAppControl` used in integration tests mirrors the production contract with these Atlas CallConfig flags:

| Flag | Value | Purpose |
|---|---|---|
| `requirePreOps` | `true` | Validates bundler, oracle, selector, and userOp signer before execution |
| `reuseUserOp` | `true` | Oracle update executes regardless of solver outcome |
| `verifyCallChainHash` | `true` | DAppOp must commit to exact set of solverOps (prevents reordering) |
| `requireFulfillment` | `true` | At least one solver must succeed for the transaction to complete |

Key configuration during deployment:
- **Bundler whitelist**: Chainlink NOPs authorized to submit metacalls
- **Oracle whitelist**: Chainlink oracles that can be updated via SVR
- **Allowed selectors**: Only `IAuthorizedForwarder.forward()` by default
- **Authorized userOp signer**: Chainlink node that creates oracle update userOps
- **OEV shares**: Configurable split between Fastlane, block builder, and protocol

## Test Coverage

**17 tests total, all passing. No RPC or fork required.**

### Unit Tests (15)
- Access control: rejects unapproved solvers, unapproved NOPs, both invalid
- Admin functions: add/remove solvers and NOPs, owner-only enforcement
- Token recovery
- Successful liquidation with full token flow verification
- Callback data handling
- Liquidator whitelist enforcement
- Callback caller-only restriction
- End-to-end token flow (collateral -> solver, loan tokens -> liquidator, wrapper ends clean)

### Integration Tests (2)
- **Full SVR metacall flow** (`test_svrMetacallOracleUpdateAndLiquidation`): Deploys Atlas + ChainlinkSvrDAppControl + ChainlinkSvrDAppExecutor + MockOracle. Builds and signs UserOperation (oracle update) + SolverOperation (liquidation) + DAppOperation (with callChainHash). Executes the complete chain. Verifies both oracle price update AND liquidation token balances.
- **Unauthorized bundler rejection** (`test_svrRejectsUnauthorizedBundler`): Verifies that `_preOpsCall` rejects metacalls from non-whitelisted bundlers, and the oracle price remains unchanged.

## Setup

```bash
# Install Foundry (if not installed)
curl -L https://foundry.paradigm.xyz | bash
source ~/.zshenv
foundryup

# Clone
git clone --recurse-submodules https://github.com/deoalade/svr-lista-poc.git
cd svr-lista-poc

# Build
forge build

# Test
forge test -vv
```

> **Why `--recurse-submodules`?** This repo uses git submodules for its dependencies (forge-std, OpenZeppelin, Atlas). The `--recurse-submodules` flag clones those alongside the main repo so Foundry can resolve imports.

## What's Left Before Mainnet

- [x] **Full SVR DAppControl integration** — ChainlinkSvrDAppControl + Executor in test suite
- [ ] **BNB Chain fork test** against real ListaDAO contracts to verify actual token flows
- [ ] **Flash liquidation test** — callback is implemented but needs dedicated testing with the flash path
- [ ] **Pre-liquidation support** — partial position closure before standard threshold
- [ ] **BrokerLiquidator integration** (`0x3AA6...`) — handles broker markets, may need separate wrapper or multi-target support
- [ ] **NOP EOA list** from Jacob Greene (Chainlink NOP addresses submitting Atlas transactions on BNB Chain)
- [ ] **Gas profiling** under real BNB Chain conditions
- [ ] **Security audit**

## Dependencies

- [forge-std](https://github.com/foundry-rs/forge-std)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) (Ownable, SafeERC20)
- [Atlas](https://github.com/FastLane-Labs/atlas) (SolverBase, DAppControl, Atlas infrastructure)
- [atlas-chainlink-external](https://github.com/smartcontractkit/atlas-chainlink-external) (ChainlinkSvrDAppControl, ChainlinkSvrDAppExecutor — reference copies in `src/svr/`)
