# Chroma Finance — EVM Contracts

Decentralized portfolio management protocol with guardian protection and social recovery.

## Architecture

```
src/
├── core/
│   ├── VaultFactory.sol         # Deploys minimal-proxy PortfolioVaults
│   └── PortfolioVault.sol       # Per-user vault with deposit/withdraw/rebalance
├── modules/
│   ├── GuardianModule.sol       # Guardian assignment and tx approval gates
│   ├── SocialRecoveryModule.sol # Multi-guardian time-delayed recovery
│   └── YieldOptimizer.sol       # Rebalancing orchestration
├── utils/
│   ├── SwapRouter.sol           # Uniswap V3 swap wrapper
│   ├── FeeManager.sol           # Protocol fee collection and distribution
│   └── RiskTierRegistry.sol     # Token risk tier and allocation limits
└── interfaces/
    ├── IVault.sol
    ├── IGuardian.sol
    └── IRecovery.sol
```

## Setup

```bash
cp .env.example .env
# Fill in PRIVATE_KEY, ARBITRUM_RPC_URL, MAINNET_RPC_URL, ARBISCAN_API_KEY
```

## Testing

```bash
# Unit tests
forge test --match-path "test/unit/**"

# Integration tests
forge test --match-path "test/integration/**"

# Fork tests (requires ARBITRUM_RPC_URL)
forge test --match-path "test/fork/**" --fork-url $ARBITRUM_RPC_URL

# All tests with gas report
forge test --gas-report

# Coverage
forge coverage
```

## Deployment

```bash
# Dry run
forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL -vvvv

# Broadcast
forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
```

## Target Chain

**Arbitrum One** (chainId: 42161)

## Local test
# Start Anvil
```bash
anvil \
  --fork-url https://arb1.arbitrum.io/rpc \
  --chain-id 1337 \
  --port 8545
```

# Import Hardhat default wallet if needed
```bash
0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

# Deploy locally
```bash
forge script script/DeployArbitrumFork.s.sol   --rpc-url http://localhost:8545   --broadcast   --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   -vvvv
```

# Copy deployments/local-fork.json to your FE app.

# Enjoy!


## Security

- OpenZeppelin v5 base contracts (ReentrancyGuard, Pausable, SafeERC20, Clones)
- Guardian-gated emergency pause on every vault
- Social recovery requires threshold approvals + 48h time delay
- Risk tier registry caps aggressive allocations at 20% of vault
