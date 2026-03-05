# LidoHarvester [![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](https://opensource.org/licenses/MIT) [![solidity](https://img.shields.io/badge/solidity-%5E0.8.34-black)](https://docs.soliditylang.org/en/v0.8.34/) [![Foundry](https://img.shields.io/badge/Built%20with-Foundry-000000.svg)](https://getfoundry.sh/)

A minimal Solidity contract for harvesting Lido stETH yield. Accepts ETH or stETH deposits, tracks principal via a basis counter, and allows permissionless conversion of accrued yield back to ETH through a configurable swap target (e.g., Curve stETH/ETH pool).

## How It Works

1. **Deposit** — Send ETH (auto-converted to stETH) or transfer stETH directly. The `staked` counter tracks your principal.
2. **Yield accrues** — Lido rebases increase the contract's stETH balance above `staked`.
3. **Harvest** — Anyone can call `harvest()` with swap calldata for the configured target. The yield portion of stETH is swapped to ETH. Slippage and principal protection checks are enforced post-swap.
4. **Withdraw** — Owner can withdraw harvested ETH via `withdraw()`, optionally enforcing a balance-increase condition on a specified holder/asset.
5. **Compound** — Owner can re-stake harvested ETH back into stETH via `stake()`.

## Key Features

- **Permissionless harvesting** — `harvest()` has no access control, enabling keeper/bot automation
- **Principal protection** — Post-harvest invariant ensures stETH balance still covers `staked`
- **Slippage control** — Configurable `slipBps` enforces minimum ETH received from swaps
- **Transient storage guard** — Uses EIP-1153 `tstore`/`tload` to prevent `receive()` from inflating `staked` during harvest callbacks
- **Conditional withdrawals** — Owner can require that a withdraw call increases a holder's ETH or ERC20 balance by a minimum amount

## Contract Interface

| Function | Access | Description |
|---|---|---|
| `receive()` | Anyone | Deposit ETH (auto-stakes to stETH) |
| `deposit(uint256)` | Anyone | Deposit stETH (requires prior approval) |
| `harvest(bytes)` | Anyone | Swap accrued yield to ETH via target |
| `stake(uint256)` | Owner | Convert contract ETH to stETH (0 = all) |
| `withdraw(address,uint256,bytes,uint256)` | Owner | Send ETH with optional calldata and balance condition |
| `withdrawStETH(address,uint256)` | Owner | Withdraw stETH, reducing `staked` |
| `setTarget(address)` | Owner | Set swap target (grants stETH approval) |
| `setSlippage(uint16)` | Owner | Set max slippage in basis points (0-10000) |
| `setCondition(address,address)` | Owner | Set asset/holder for withdraw conditions |
| `transferOwnership(address)` | Owner | Transfer contract ownership |

## Blueprint

```txt
lib
├── forge-std — https://github.com/foundry-rs/forge-std
src
├── LidoHarvester.sol — Harvester contract
test
└── LidoHarvester.t.sol — Fork tests (Ethereum mainnet)
```

## Getting Started

Install Foundry:

```sh
curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup
```

Build and test:

```sh
forge build
forge test
```

Tests run against an Ethereum mainnet fork (configured in `foundry.toml` via `eth_rpc_url`). To use a different RPC:

```sh
forge test --fork-url https://your-rpc-endpoint.com
```

## Deployment

[`0x0000000000883fEE47BfC9879478955eef9539dA`](https://etherscan.io/address/0x0000000000883fEE47BfC9879478955eef9539dA#code)

## Security

Audited by [Zellic V12](https://zellic.ai/) AI scan — [report](./audit/zellic-V12-AI-scan/z0r0z_lido_harvester__main_89d9448_findings_2026-03-05-findings.md). No valid findings.

## Disclaimer

*These smart contracts and testing suite are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of anything provided herein or through related user interfaces. This repository and related code have not been audited and as such there can be no assurance anything will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk.*

## License

See [LICENSE](./LICENSE) for more details.
