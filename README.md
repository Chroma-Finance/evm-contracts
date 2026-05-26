# Chroma Finance — EVM Contracts

Decentralized portfolio management protocol with guardian protection and social recovery.

## Architecture

```
src/
├── core/
│   ├── VaultFactory.sol         # Deploys minimal-proxy PortfolioVaults; wires shared modules
│   ├── PortfolioVault.sol       # Per-user vault (EIP-1167 proxy) with deposit/withdraw
│   └── EventNotifier.sol        # Centralized event emission; authorized per vault by factory
├── modules/
│   ├── GuardianModule.sol       # EIP-712 gasless withdrawal approval
│   ├── SocialRecoveryModule.sol # Multi-guardian time-delayed ownership recovery
│   └── YieldOptimizer.sol       # Yield boost stub (Phase 3)
├── utils/
│   ├── SwapRouter.sol           # Uniswap V3 wrapper with Chainlink slippage protection
│   ├── FeeManager.sol           # Protocol fee collection and distribution
│   └── RiskTierRegistry.sol     # Predefined risk tiers: assets, weights, Chainlink feeds
└── interfaces/
    ├── IVault.sol
    ├── IGuardian.sol
    ├── IRecovery.sol
    ├── ISwapRouter.sol
    └── IEventNotifier.sol
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
forge script script/DeployArbitrumFork.s.sol --rpc-url $ARBITRUM_RPC_URL -vvvv

# Broadcast
forge script script/DeployArbitrumFork.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
```

**Target chain:** Arbitrum One (chainId: 42161)

## Local Development

### 1. Start Anvil (Arbitrum mainnet fork)

```bash
anvil \
  --fork-url https://arb1.arbitrum.io/rpc \
  --chain-id 1337 \
  --port 8545
```

### 2. Test wallet — Anvil account #0

Add this private key to your wallet or `.env`:

```
0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`

### 3. Deploy

```bash
forge script script/DeployArbitrumFork.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  -vvvv
```

### 4. Use the manifest

`deployments/local-fork.json` is written automatically. Copy it to your frontend app.

### Latest local deployment (`deployments/local-fork.json`)

| Contract              | Address                                      |
|-----------------------|----------------------------------------------|
| VaultFactory          | `0xfBBeFB950B26EB363b3D8B83891f6ee01EAE3854` |
| VaultImplementation   | `0x24026406E9b4e94ad39b57b55A859c3F88d423BA` |
| GuardianModule        | `0xB652A99B9C526590090fA164A0473Df77F1EfD85` |
| SocialRecoveryModule  | `0x993522600E90EA64D0b9e9D64372D15D8c5ABc4C` |
| SwapRouter            | `0xd04E1bEC2591718fe3DE42Bada5f7927007592CB` |
| RiskTierRegistry      | `0xb519Df32D51b9905928de40ae0119113C2a0a139` |
| EventNotifier         | `0x8b77b047dB446BE4d6aCBc5BC49297DE2Dab768F` |
| FeeManager            | `0x10587895313D365bB26fAB830E925bf021851738` |

**Tokens (Arbitrum One — live addresses):**

| Token | Address                                      |
|-------|----------------------------------------------|
| USDC  | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| USDT  | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` |
| DAI   | `0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1` |
| WBTC  | `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` |
| WETH  | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |

## Security

- OpenZeppelin v5 base contracts (ReentrancyGuard, SafeERC20, Clones)
- Guardian-gated withdrawal approval via EIP-712 signatures
- Social recovery requires threshold approvals + 48h time delay
- Chainlink oracle validation: 1h staleness threshold, 0.5% max slippage
- Token whitelist enforced in SwapRouter — malicious tokens rejected at swap
