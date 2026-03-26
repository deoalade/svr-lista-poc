# SVR Liquidation Wrapper — ListaDAO Integration on BNB Chain

A lightweight wrapper contract that enables [Chainlink SVR](https://docs.chain.link/data-feeds/svr-feeds) liquidations on [ListaDAO](https://lista.org/) (Moolah Lending) via the [Atlas](https://github.com/FastLane-Labs/atlas) protocol.

## The Problem

ListaDAO's Liquidator contract only accepts liquidation calls from **pre-approved (whitelisted) addresses**. In the Atlas SVR flow, the direct caller is the searcher's solver contract and the transaction is submitted by a Chainlink node operator — neither is a fixed whitelistable address. This wrapper solves that by becoming the single whitelisted address on ListaDAO and validating inbound calls before forwarding them.

## How It Works

```
Chainlink NOP submits Atlas metacall (oracle update + searcher liquidation)
    │
    ▼
Atlas calls winning searcher's solver contract (SVRListaSolver)
    │
    ▼
Solver calls SVRLiquidationWrapper.liquidate()
    │
    ├── Validates msg.sender is an approved solver
    ├── Validates tx.origin is an approved Chainlink NOP
    │
    ▼
Wrapper forwards call to ListaDAO Liquidator
    │
    ├── ListaDAO sees wrapper as caller → whitelist passes
    ├── Collateral transferred to wrapper
    ├── onMorphoLiquidate callback → wrapper pulls loan tokens from solver
    ├── Wrapper approves Liquidator to pull loan tokens
    │
    ▼
Collateral forwarded back to solver, loan tokens sent to Liquidator
```

## Contracts

| Contract | Description |
|---|---|
| `SVRLiquidationWrapper.sol` | Core wrapper. Whitelisted on ListaDAO. Validates callers, forwards liquidations, handles token routing and Morpho callback. |
| `SVRListaSolver.sol` | Atlas solver (inherits `SolverBase`). Called during `metacall`, invokes the wrapper. |
| `MockListaLiquidator.sol` | Test mock simulating ListaDAO's whitelisted Morpho-style liquidation. Not for deployment. |

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
- End-to-end token flow (collateral → solver, loan tokens → liquidator, wrapper ends clean)

### Integration Tests (2)
- Full Atlas `metacall` flow: deploys Atlas infrastructure, builds and signs UserOperation + SolverOperation + DAppOperation, executes the complete chain (Atlas → ExecutionEnvironment → SolverBase → SVRListaSolver → SVRLiquidationWrapper → MockListaLiquidator), verifies all token balances

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

## What's Left Before Mainnet

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
- [Atlas](https://github.com/FastLane-Labs/atlas) (SolverBase, Atlas test infrastructure)
