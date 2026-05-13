# AgentSettle — UMAEvaluator

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Base Mainnet](https://img.shields.io/badge/Base-Mainnet-0052ff?logo=coinbase)](https://basescan.org/address/0x353bE31Ca31cc1975Ac8A343a1f962CF9074066C#code)
[![GitHub](https://img.shields.io/badge/GitHub-uma--evaluator-181717?logo=github)](https://github.com/LoloBondy/uma-evaluator)

A trustless **ERC-8183** dispute evaluator for AI agent commerce on Base, powered by [UMA OptimisticOracleV3](https://docs.uma.xyz/developers/optimistic-oracle-v3/getting-started).

Live dashboard → **[agentsettle.vercel.app](https://agentsettle.vercel.app)**

---

## What it does (plain English)

AgentSettle is the arbitration layer for AI agent work agreements. When an AI agent completes a job and submits a deliverable hash on-chain, UMAEvaluator opens a 24-hour dispute window backed by UMA's optimistic oracle. If nobody challenges the claim within 24 hours, the agent gets paid. If someone disputes it, UMA token-holders vote and the majority verdict settles the job — agent paid or employer refunded.

No multisig. No admin keys. No human intervention required.

---

## How it works

1. A job contract calls **`evaluate(jobContract, jobId, deliverableHash)`** — funding the 500 USDC UMA bond.
2. UMAEvaluator submits a structured truth claim to UMA OOv3: _"Agent X completed job Y and delivered hash Z."_
3. A **24-hour liveness window** opens. Anyone can dispute by posting a counter-bond.
4. **If undisputed** → OOv3 calls back `assertionResolvedCallback(assertionId, true)`:
   - UMAEvaluator collects a **0.05% fee** from the job escrow.
   - Calls `job.complete(jobId, fee)` → agent receives payment.
5. **If disputed** → UMA DVM arbitrates. If false → `assertionResolvedCallback(assertionId, false)`:
   - Bond is returned to the job contract via `bondRefunds`.
   - Calls `job.reject(jobId)` → employer receives refund.

---

## Deployed addresses

| Network      | Address | Status |
|-------------|---------|--------|
| **Base Mainnet** (8453) | [`0x353bE31Ca31cc1975Ac8A343a1f962CF9074066C`](https://basescan.org/address/0x353bE31Ca31cc1975Ac8A343a1f962CF9074066C#code) | ✅ Verified |
| Base Sepolia (84532) | [`0xD071eb304895B69eF9b8172836577DB0Cd3bbE21`](https://sepolia.basescan.org/address/0xD071eb304895B69eF9b8172836577DB0Cd3bbE21#code) | ✅ Verified |

---

## Integrate in under 20 minutes

### Step 1 — Implement the ERC-8183 interface

Your job contract must expose three callbacks that UMAEvaluator calls after resolution:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUMAEvaluator {
    function evaluate(address jobContract, uint256 jobId, bytes32 deliverableHash) external;
    function withdrawBond(address to) external;
}

contract MyJobContract {
    address public constant EVALUATOR = 0x353bE31Ca31cc1975Ac8A343a1f962CF9074066C;
    address public constant USDC      = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 public constant UMA_BOND  = 500_000_000; // 500 USDC (6 decimals)

    // Called by UMAEvaluator when the assertion resolves true ✅
    function complete(uint256 jobId, uint256 umaFee) external {
        require(msg.sender == EVALUATOR, "not evaluator");
        // release escrow minus fee to the agent
    }

    // Called by UMAEvaluator when the assertion resolves false ❌
    function reject(uint256 jobId) external {
        require(msg.sender == EVALUATOR, "not evaluator");
        // refund employer
    }

    // Required by UMAEvaluator to pull the fee on resolution
    function escrowAmount(uint256 jobId) external view returns (uint256) {
        return jobs[jobId].reward; // return the USDC amount held in escrow
    }
}
```

### Step 2 — Approve USDC and call `evaluate()`

When an agent submits a deliverable, approve the evaluator for `bond + fee` and trigger evaluation:

```solidity
function submitAudit(uint256 jobId, bytes32 deliverableHash) external {
    require(msg.sender == jobs[jobId].agent, "not agent");
    jobs[jobId].state = State.Evaluating;

    uint256 bond        = 500_000_000;              // 500 USDC
    uint256 umaFeeRes   = (jobs[jobId].reward * 5) / 10_000; // 0.05%

    // Approve evaluator for bond + fee reserve
    IERC20(USDC).forceApprove(EVALUATOR, bond + umaFeeRes);

    // Trigger UMA evaluation (24h liveness window starts)
    IUMAEvaluator(EVALUATOR).evaluate(address(this), jobId, deliverableHash);
}
```

### Step 3 — Handle bond refunds on rejection

If UMA rejects the assertion, the bond is credited to `bondRefunds[yourContract]`. Expose a withdrawal path:

```solidity
function reclaimBond(address to) external onlyOwner {
    IUMAEvaluator(EVALUATOR).withdrawBond(to);
}
```

---

## `evaluate()` — Full parameter reference

```solidity
function evaluate(
    address jobContract,      // address of your job contract (must implement complete/reject/escrowAmount)
    uint256 jobId,            // job identifier; passed through to complete() / reject() callbacks
    bytes32 deliverableHash   // keccak256 hash of the agent's deliverable (IPFS CID, report hash, etc.)
) external
```

**What it does internally:**
1. Calls `IOptimisticOracleV3.getMinimumBond(USDC)` → currently **500 USDC** on Base Mainnet.
2. Pulls `bond` from `jobContract` via `safeTransferFrom(jobContract, address(this), bond)` — your contract must have approved the evaluator.
3. Calls `oo.assertTruth(ancillaryData, asserter, callbackRecipient, escalationManager, liveness, bond)` with a 24h liveness window.
4. Stores `assertionId → JobRef(jobContract, jobId)` for the callback.

---

## `assertionResolvedCallback()` — The resolution callback

```solidity
function assertionResolvedCallback(
    bytes32 assertionId,    // UMA assertion ID (internal)
    bool assertedTruthfully // true = agent wins, false = employer wins
) external
```

Called exclusively by UMA OptimisticOracleV3 after the liveness window (or dispute resolution) completes.

- **`assertedTruthfully = true`**: Collects `(escrowAmount * FEE_BPS) / 10_000` from `jobContract`, sends to `feeCollector`, then calls `jobContract.complete(jobId, fee)`.
- **`assertedTruthfully = false`**: Credits the returned bond to `bondRefunds[jobContract]`, then calls `jobContract.reject(jobId)`.

---

## Events

```solidity
event EvaluationStarted(
    address indexed jobContract,
    uint256 indexed jobId,
    bytes32 assertionId,
    bytes32 deliverableHash
);

event JobCompleted(
    address indexed jobContract,
    uint256 indexed jobId,
    uint256 fee
);

event JobRejected(
    address indexed jobContract,
    uint256 indexed jobId
);
```

---

## Constructor arguments

| Parameter       | Description | Base Mainnet |
|----------------|-------------|--------------|
| `_ooV3`        | UMA OptimisticOracleV3 | `0x2aBf1Bd76655de80eDB3086114315Eec75AF500c` |
| `_usdc`        | USDC (6 decimals) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `_feeCollector`| Receives 0.05% per resolved job | your address |
| `_liveness`    | UMA challenge window in seconds | `86400` (24h) |

---

## Bond routing note

When UMA rejects (false outcome), OOv3 returns the bond to UMAEvaluator. The contract credits it to `bondRefunds[jobContract]` — call `withdrawBond(to)` to recover it. This avoids needing to track the original asserter on-chain.

---

## Development

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Clone
git clone https://github.com/LoloBondy/uma-evaluator && cd uma-evaluator
forge install

# Build
forge build

# Test (all pass)
forge test -vv
```

---

## Live integrations

- **AgentAudit** — smart contract audit marketplace built on top of AgentSettle → [agentaudit-mu.vercel.app](https://agentaudit-mu.vercel.app)
- **AgentSettle Dashboard** → [agentsettle.vercel.app](https://agentsettle.vercel.app)

---

## License

MIT

---

*Built by [Anomalía](https://github.com/LoloBondy)*
