# UMAEvaluator

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A decentralised **ERC-8183** dispute evaluator for AI agent commerce on Base, powered by the [UMA OptimisticOracleV3](https://docs.uma.xyz/developers/optimistic-oracle-v3/getting-started).

---

## What it does

UMAEvaluator allows any ERC-8183 job contract to outsource deliverable verification to UMA's optimistic oracle:

1. **`evaluate(jobContract, jobId, deliverableHash)`** — a caller posts a USDC bond and submits a human-readable truth assertion to UMA OOv3.
2. UMA's 2-hour liveness window opens for disputers. If undisputed, the assertion settles as true; if disputed, UMA's Data Verification Mechanism (DVM) arbitrates.
3. **`assertionResolvedCallback(assertionId, assertedTruthfully)`** — OOv3 calls back with the verdict:
   - **True** → collects a 0.05 % USDC fee from the job escrow, sends it to `feeCollector`, then calls `job.complete()`.
   - **False** → credits the returned bond to the job contract via `bondRefunds`, then calls `job.reject()`.

---

## Why it exists

AI agent commerce requires trustless, permissionless arbitration for off-chain deliverables. UMAEvaluator bridges ERC-8183 job contracts to UMA's battle-tested optimistic dispute layer, enabling any protocol to add decentralised evaluation without building its own adjudication system. Each deployment is network-agnostic — pass the correct OOv3 and USDC addresses at construction time.

---

## Constructor arguments

| Parameter       | Description                                                             | Base Mainnet (8453)                          | Base Sepolia (84532)                         |
|----------------|-------------------------------------------------------------------------|----------------------------------------------|----------------------------------------------|
| `_ooV3`        | UMA OptimisticOracleV3                                                  | `0x88Ad27C41AD06f01153E7Cd9b10cBEdF4616f4d6` | `0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944` |
| `_usdc`        | USDC token (6 decimals)                                                 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| `_feeCollector`| Receives the 0.05 % platform fee on each resolved job                   | Your address                                 | Your address                                 |
| `_liveness`    | UMA challenge window in seconds (min 3 600; recommended 7 200 on L2)   | `7200`                                       | `7200`                                       |

---

## Integration note — bond routing via `withdrawBond()`

When UMA rejects an assertion (false outcome), OOv3 returns the bond to `UMAEvaluator`. The contract credits this amount to `bondRefunds[jobContract]` rather than the original human asserter, because the evaluator has no record of who funded the bond.

**Job contracts that call `evaluate()` must expose their own withdrawal path:**

```solidity
// Inside your ERC-8183 job contract:
function reclaimBond(address to) external onlyOwnerOrAssertingParty {
    IUMAEvaluator(evaluator).withdrawBond(to);
}
```

`withdrawBond(address to)` follows the Checks-Effects-Interactions pattern: the `bondRefunds` balance is zeroed before the USDC transfer, making it reentrancy-safe.

---

## Deployed addresses

| Network      | Address                                                                                                                                          |
|-------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| Base Sepolia | [`0xD071eb304895B69eF9b8172836577DB0Cd3bbE21`](https://sepolia.basescan.org/address/0xD071eb304895B69eF9b8172836577DB0Cd3bbE21#code) (verified) |
| Base Mainnet | _coming soon_                                                                                                                                    |

---

## Development

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Build
forge build

# Test (12 tests, all pass)
forge test -vv
```

---

## License

MIT
