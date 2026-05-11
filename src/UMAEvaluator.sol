// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// UMAEvaluator — ERC-8183 IEvaluator implementation for Base
//
// Evaluation flow:
//   1. evaluate()  is called → posts a yes/no truth assertion to UMA OOv3
//   2. UMA resolves after liveness / dispute and fires assertionResolvedCallback()
//   3. Callback collects a 0.05 % USDC fee and calls complete() or reject()
//      on the originating ERC-8183 job contract.
//
// Changes v3:
//   - OO_V3 and USDC promoted from constants → immutables (_ooV3, _usdc).
//     Pass mainnet or Sepolia addresses at deploy time — no code changes needed.
// ─────────────────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ── Minimal ERC-8183 job-contract interface ───────────────────────────────────
interface IJobContract {
    function complete(uint256 jobId, uint256 fee) external; // deliverable accepted
    function reject(uint256 jobId) external;                // deliverable rejected
    function escrowAmount(uint256 jobId) external view returns (uint256); // USDC escrow (6 dec)
}

// ── ERC-8183 IEvaluator interface ─────────────────────────────────────────────
interface IEvaluator {
    function evaluate(address jobContract, uint256 jobId, bytes32 deliverableHash) external;
}

// ── Minimal UMA OptimisticOracleV3 interface ──────────────────────────────────
interface IOptimisticOracleV3 {
    function assertTruth(
        bytes  memory claim,
        address asserter,
        address callbackRecipient,
        address sovereignSecurity,
        uint64  liveness,
        IERC20  currency,
        uint256 bond,
        bytes32 defaultIdentifier,
        bytes32 domain
    ) external returns (bytes32 assertionId);

    function defaultIdentifier() external view returns (bytes32);
    function getMinimumBond(address currency) external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// UMAEvaluator
// ─────────────────────────────────────────────────────────────────────────────
contract UMAEvaluator is IEvaluator {
    using SafeERC20 for IERC20;

    // ── Protocol constant ─────────────────────────────────────────────────────

    /// @notice 0.05 % fee = 5 basis points.
    uint256 public constant FEE_BPS = 5;

    // ── Immutables (set once at deploy) ──────────────────────────────────────

    /// @notice UMA OptimisticOracleV3 used for assertions and callbacks.
    ///
    ///         Base Mainnet  (8453):  0x88Ad27C41AD06f01153E7Cd9b10cBEdF4616f4d6
    ///           Source: UMAprotocol/protocol/packages/core/networks/8453.json
    ///
    ///         Base Sepolia  (84532): 0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944
    ///           Source: UMAprotocol/protocol/packages/core/networks/84532.json
    address public immutable OO_V3;

    /// @notice ERC-20 token used as the UMA bond currency and for platform fees.
    ///
    ///         Base Mainnet  (8453):  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913  (native USDC, 6 dec)
    ///         Base Sepolia  (84532): 0x036CbD53842c5426634e7929541eC2318f3dCF7e  (testnet USDC, 6 dec)
    address public immutable USDC;

    /// @notice Receives the 0.05 % USDC fee on every successfully resolved job.
    address public immutable feeCollector;

    /// @notice UMA dispute challenge window in seconds.
    ///         Minimum recommended on L2: 7_200 (2 h). Use longer for high-value jobs.
    ///         Set in constructor so each deployment can tune this without redeploying.
    uint64  public immutable liveness;

    // ── Storage ───────────────────────────────────────────────────────────────

    /// @dev Contextual data kept per pending UMA assertion.
    struct AssertionData {
        address jobContract; // originating ERC-8183 job contract
        uint256 jobId;       // job being evaluated
        uint256 bond;        // USDC bond amount posted (returned on resolution)
    }

    /// @notice assertionId → AssertionData for every in-flight UMA assertion.
    mapping(bytes32 => AssertionData) public pendingAssertions;

    /// @notice Tracks active assertion per (jobContract, jobId) to prevent duplicates.
    ///         Value is the assertionId; zero means no active assertion.
    mapping(address => mapping(uint256 => bytes32)) public activeAssertion;

    /// @notice Accumulated USDC bonds returned by OOv3 after rejected assertions.
    ///         Keyed by the job contract address that called evaluate().
    ///         See withdrawBond() — the job contract must implement its own
    ///         withdrawal path to forward these funds to the original asserter.
    mapping(address => uint256) public bondRefunds;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a UMA assertion is posted for a job.
    event DisputeRaised(uint256 indexed jobId, bytes32 indexed assertionId);

    /// @notice Emitted when UMA settles an assertion.
    /// @param outcome true = deliverable accepted, false = rejected.
    /// @param fee     USDC fee collected (0 if rejected).
    event DisputeResolved(uint256 indexed jobId, bool outcome, uint256 fee);

    /// @notice Emitted when an asserter withdraws a refunded bond.
    event BondWithdrawn(address indexed asserter, uint256 amount);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param _ooV3          UMA OptimisticOracleV3 address for the target network.
    ///                         Mainnet : 0x88Ad27C41AD06f01153E7Cd9b10cBEdF4616f4d6
    ///                         Sepolia : 0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944
    /// @param _usdc          USDC token address for the target network.
    ///                         Mainnet : 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    ///                         Sepolia : 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    /// @param _feeCollector  Address that receives the 0.05 % USDC platform fee.
    /// @param _liveness      UMA challenge window in seconds (min 3_600; use 7_200+ on L2).
    constructor(
        address _ooV3,
        address _usdc,
        address _feeCollector,
        uint64  _liveness
    ) {
        require(_ooV3         != address(0), "UMAEvaluator: zero ooV3");
        require(_usdc         != address(0), "UMAEvaluator: zero usdc");
        require(_feeCollector != address(0), "UMAEvaluator: zero feeCollector");
        require(_liveness     >= 3_600,      "UMAEvaluator: liveness too short");
        OO_V3        = _ooV3;
        USDC         = _usdc;
        feeCollector = _feeCollector;
        liveness     = _liveness;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IEvaluator
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Post a UMA yes/no truth assertion for the given job.
     * @dev    Caller must pre-approve this contract to spend the OOv3 minimum
     *         bond in USDC.  Bond is returned to this contract on truthful
     *         resolution and credited to caller via bondRefunds on rejection.
     *         Reverts if an assertion for this (jobContract, jobId) is already pending.
     *
     * @param jobContract     ERC-8183 job contract holding the escrow.
     * @param jobId           Identifier of the job to evaluate.
     * @param deliverableHash keccak256 of the deliverable bytes.
     */
    function evaluate(
        address jobContract,
        uint256 jobId,
        bytes32 deliverableHash
    ) external override {
        require(jobContract != address(0), "UMAEvaluator: zero jobContract");

        // Guard: prevent duplicate simultaneous assertions for the same job.
        require(
            activeAssertion[jobContract][jobId] == bytes32(0),
            "UMAEvaluator: assertion already pending for this job"
        );

        IOptimisticOracleV3 oo = IOptimisticOracleV3(OO_V3);
        IERC20 usdc            = IERC20(USDC);

        // Fetch minimum bond required by OOv3 for this USDC deployment.
        uint256 bond = oo.getMinimumBond(USDC);

        // Pull bond from caller into this contract, then approve OOv3 to spend.
        usdc.safeTransferFrom(msg.sender, address(this), bond);
        usdc.forceApprove(OO_V3, bond);

        // Build human-readable claim that UMA tokenholders can verify off-chain.
        bytes memory claim = abi.encodePacked(
            "Was job ", _uint2str(jobId),
            " completed as specified? Deliverable hash: 0x",
            _bytes32ToHex(deliverableHash),
            ". Job contract: 0x", _addressToHex(jobContract), "."
        );

        // Assert the claim; this contract is both asserter (bond holder)
        // and the callback recipient.
        bytes32 assertionId = oo.assertTruth(
            claim,
            address(this), // asserter  — bond returned here on truth
            address(this), // callback recipient
            address(0),    // no custom escalation manager
            liveness,      // configurable per deployment
            usdc,
            bond,
            oo.defaultIdentifier(),
            bytes32(0)     // generic domain
        );

        // Persist context so the callback can reconstruct job details.
        pendingAssertions[assertionId] = AssertionData(jobContract, jobId, bond);

        // Record active assertion to block duplicates.
        activeAssertion[jobContract][jobId] = assertionId;

        emit DisputeRaised(jobId, assertionId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // UMA callbacks
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Called by UMA OOv3 once an assertion is fully settled.
     * @dev    Only OOv3 may invoke this.  Storage is cleared before any
     *         external call (checks-effects-interactions pattern).
     *         On rejection, the bond OOv3 returns to this contract is credited
     *         to the job contract address so it can be withdrawn via withdrawBond().
     *
     * @param assertionId        Identifier of the resolved assertion.
     * @param assertedTruthfully true → claim accepted; false → claim rejected.
     */
    function assertionResolvedCallback(
        bytes32 assertionId,
        bool    assertedTruthfully
    ) external {
        require(msg.sender == OO_V3, "UMAEvaluator: caller not OOv3");

        AssertionData memory data = pendingAssertions[assertionId];
        require(data.jobContract != address(0), "UMAEvaluator: unknown assertion");

        // Clear all state before external calls (reentrancy hygiene).
        delete pendingAssertions[assertionId];
        delete activeAssertion[data.jobContract][data.jobId];

        IJobContract job = IJobContract(data.jobContract);
        uint256 fee;

        if (assertedTruthfully) {
            // Compute 0.05 % of job escrow as the platform fee.
            uint256 escrow = job.escrowAmount(data.jobId);
            fee = (escrow * FEE_BPS) / 10_000;

            // Transfer fee from job contract escrow → feeCollector.
            // The job contract must have pre-approved this evaluator for USDC.
            if (fee > 0) {
                IERC20(USDC).safeTransferFrom(data.jobContract, feeCollector, fee);
            }

            // Notify job contract: deliverable accepted.
            // The returned bond (from OOv3 → this contract) sits in our USDC
            // balance and can be reused as bond for the next evaluate() call.
            job.complete(data.jobId, fee);
        } else {
            // Assertion rejected — credit the returned bond to the job contract
            // address so it can be withdrawn.  OOv3 has already transferred
            // the bond back to address(this) before making this callback.
            bondRefunds[data.jobContract] += data.bond;

            // Notify job contract: deliverable rejected; no fee charged.
            job.reject(data.jobId);
        }

        emit DisputeResolved(data.jobId, assertedTruthfully, fee);
    }

    /**
     * @notice Called by UMA OOv3 when an assertion enters dispute.
     * @dev    No state change needed; UMA escalates to the DVM automatically
     *         and then fires assertionResolvedCallback() with the final verdict.
     *         Must exist to satisfy OOv3's full callback interface.
     */
    function assertionDisputedCallback(bytes32 /* assertionId */) external {
        // Intentionally empty — DVM handles the dispute.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bond withdrawal
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw USDC bonds that OOv3 returned after rejected assertions.
     * @dev    msg.sender must be the job contract address that called evaluate().
     *         That contract should expose its own function to forward funds onward
     *         to the original human asserter.
     * @param to Recipient address for the refunded USDC.
     */
    function withdrawBond(address to) external {
        uint256 amount = bondRefunds[msg.sender];
        require(amount > 0, "UMAEvaluator: no bond to withdraw");
        bondRefunds[msg.sender] = 0; // zero before transfer (CEI)
        IERC20(USDC).safeTransfer(to, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev uint256 → decimal ASCII string.
    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v; uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    /// @dev bytes32 → 64-char lowercase hex ASCII (no "0x" prefix).
    function _bytes32ToHex(bytes32 d) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes memory r = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            r[i*2]   = h[uint8(d[i] >> 4)];
            r[i*2+1] = h[uint8(d[i] & 0x0f)];
        }
        return string(r);
    }

    /// @dev address → 40-char lowercase hex ASCII (no "0x" prefix).
    function _addressToHex(address addr) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes20 b = bytes20(addr);
        bytes memory r = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            r[i*2]   = h[uint8(b[i] >> 4)];
            r[i*2+1] = h[uint8(b[i] & 0x0f)];
        }
        return string(r);
    }
}
