// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/UMAEvaluator.sol";

// ── Mock USDC (minimal ERC-20) ────────────────────────────────────────────────
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockUSDC: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "MockUSDC: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "MockUSDC: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ── Mock OOv3 ─────────────────────────────────────────────────────────────────
contract MockOO {
    uint256 public constant MIN_BOND = 1_000e6; // 1000 USDC

    bytes32 public lastAssertionId;
    address public usdcToken;

    constructor(address _usdc) {
        usdcToken = _usdc;
    }

    function defaultIdentifier() external pure returns (bytes32) {
        return keccak256("ASSERT_TRUTH");
    }

    function getMinimumBond(address) external pure returns (uint256) {
        return MIN_BOND;
    }

    // Pulls the bond from caller (the UMAEvaluator) and returns a deterministic assertionId.
    function assertTruth(
        bytes  memory,
        address,
        address,
        address,
        uint64,
        IERC20,
        uint256 bond,
        bytes32,
        bytes32
    ) external returns (bytes32 assertionId) {
        MockUSDC(usdcToken).transferFrom(msg.sender, address(this), bond);
        assertionId = keccak256(abi.encodePacked(block.timestamp, msg.sender, bond));
        lastAssertionId = assertionId;
    }

    // Simulate OOv3 resolving an assertion — returns bond to evaluator then calls callback.
    function resolve(address evaluator, bytes32 assertionId, bool truthfully) external {
        MockUSDC(usdcToken).transfer(evaluator, MIN_BOND);
        UMAEvaluator(evaluator).assertionResolvedCallback(assertionId, truthfully);
    }
}

// ── Mock Job Contract ─────────────────────────────────────────────────────────
contract MockJob {
    MockUSDC public usdc;
    bool public completed;
    bool public rejected;
    uint256 public feeReceived;
    uint256 public escrow;

    constructor(address _usdc, uint256 _escrow) {
        usdc = MockUSDC(_usdc);
        escrow = _escrow;
    }

    function escrowAmount(uint256) external view returns (uint256) {
        return escrow;
    }

    function complete(uint256, uint256 fee) external {
        completed = true;
        feeReceived = fee;
    }

    function reject(uint256) external {
        rejected = true;
    }

    // Approve the evaluator to pull the fee on complete path.
    function approveEvaluator(address evaluator, uint256 amount) external {
        usdc.approve(evaluator, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Test suite
// ─────────────────────────────────────────────────────────────────────────────
contract UMAEvaluatorTest is Test {
    MockUSDC  usdc;
    MockOO    oo;
    MockJob   job;
    UMAEvaluator evaluator;

    address feeCollector = address(0xFEE);
    address caller       = address(0xCAFE);

    uint64  constant LIVENESS = 7_200;
    uint256 constant ESCROW   = 100_000e6; // 100k USDC escrow

    function setUp() public {
        usdc      = new MockUSDC();
        oo        = new MockOO(address(usdc));
        evaluator = new UMAEvaluator(address(oo), address(usdc), feeCollector, LIVENESS);
        job       = new MockJob(address(usdc), ESCROW);

        // Fund the MockOO so it can return bonds on resolution.
        usdc.mint(address(oo), 10_000_000e6);

        // Give caller enough USDC to post bonds and approve the evaluator.
        usdc.mint(caller, 10 * MockOO(oo).MIN_BOND());
        vm.prank(caller);
        usdc.approve(address(evaluator), type(uint256).max);
    }

    // ── 1. Constructor reverts on zero address ────────────────────────────────

    function test_constructor_revertOnZeroOo() public {
        vm.expectRevert("UMAEvaluator: zero ooV3");
        new UMAEvaluator(address(0), address(usdc), feeCollector, LIVENESS);
    }

    function test_constructor_revertOnZeroUsdc() public {
        vm.expectRevert("UMAEvaluator: zero usdc");
        new UMAEvaluator(address(oo), address(0), feeCollector, LIVENESS);
    }

    function test_constructor_revertOnZeroFeeCollector() public {
        vm.expectRevert("UMAEvaluator: zero feeCollector");
        new UMAEvaluator(address(oo), address(usdc), address(0), LIVENESS);
    }

    function test_constructor_revertOnLivenessTooShort() public {
        vm.expectRevert("UMAEvaluator: liveness too short");
        new UMAEvaluator(address(oo), address(usdc), feeCollector, 3_599);
    }

    function test_constructor_setsImmutables() public view {
        assertEq(evaluator.OO_V3(),        address(oo));
        assertEq(evaluator.USDC(),         address(usdc));
        assertEq(evaluator.feeCollector(), feeCollector);
        assertEq(evaluator.liveness(),     LIVENESS);
    }

    // ── 2. Duplicate evaluate() guard ────────────────────────────────────────

    function test_evaluate_revertOnDuplicate() public {
        vm.prank(caller);
        evaluator.evaluate(address(job), 1, keccak256("deliverable"));

        vm.prank(caller);
        vm.expectRevert("UMAEvaluator: assertion already pending for this job");
        evaluator.evaluate(address(job), 1, keccak256("deliverable"));
    }

    function test_evaluate_allowsNewJobAfterResolution() public {
        vm.prank(caller);
        evaluator.evaluate(address(job), 1, keccak256("v1"));
        bytes32 id = oo.lastAssertionId();

        // Resolve it (true) so the guard clears.
        usdc.mint(address(job), 1_000e6); // give job USDC for fee
        job.approveEvaluator(address(evaluator), 1_000e6);
        oo.resolve(address(evaluator), id, true);

        // Same (jobContract, jobId) should now be allowed again.
        vm.prank(caller);
        evaluator.evaluate(address(job), 1, keccak256("v2"));
    }

    // ── 3. assertionResolvedCallback true path ────────────────────────────────

    function test_callback_truePath_feeTransferAndComplete() public {
        vm.prank(caller);
        evaluator.evaluate(address(job), 42, keccak256("hash"));
        bytes32 id = oo.lastAssertionId();

        // Expected fee: 5 bps of 100_000e6 = 50e6
        uint256 expectedFee = (ESCROW * 5) / 10_000;

        // Job contract must pre-approve the evaluator to pull the fee.
        usdc.mint(address(job), expectedFee);
        job.approveEvaluator(address(evaluator), expectedFee);

        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        oo.resolve(address(evaluator), id, true);

        // Job marked complete with correct fee.
        assertTrue(job.completed(), "job not completed");
        assertEq(job.feeReceived(), expectedFee, "wrong fee");

        // Fee transferred to feeCollector.
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, expectedFee, "collector balance wrong");

        // State cleaned up.
        (address jc,,) = evaluator.pendingAssertions(id);
        assertEq(jc, address(0), "pendingAssertions not cleared");
        assertEq(evaluator.activeAssertion(address(job), 42), bytes32(0), "activeAssertion not cleared");
    }

    // ── 4. assertionResolvedCallback false path ───────────────────────────────

    function test_callback_falsePath_bondRefundCredited() public {
        vm.prank(caller);
        evaluator.evaluate(address(job), 99, keccak256("hash2"));
        bytes32 id = oo.lastAssertionId();

        uint256 bond = MockOO(oo).MIN_BOND();

        oo.resolve(address(evaluator), id, false);

        // Job marked rejected, no fee.
        assertTrue(job.rejected(), "job not rejected");

        // Bond credited to job contract address.
        assertEq(evaluator.bondRefunds(address(job)), bond, "bond refund not credited");

        // State cleaned up.
        (address jc,,) = evaluator.pendingAssertions(id);
        assertEq(jc, address(0), "pendingAssertions not cleared");
    }

    // ── 5. withdrawBond() CEI correctness ─────────────────────────────────────

    function test_withdrawBond_sendsUSDCAndClears() public {
        // Set up a false resolution to credit a refund.
        vm.prank(caller);
        evaluator.evaluate(address(job), 7, keccak256("hash3"));
        bytes32 id = oo.lastAssertionId();
        oo.resolve(address(evaluator), id, false);

        uint256 bond = MockOO(oo).MIN_BOND();
        address recipient = address(0xBEEF);

        uint256 recipientBefore = usdc.balanceOf(recipient);

        vm.prank(address(job));
        evaluator.withdrawBond(recipient);

        assertEq(usdc.balanceOf(recipient) - recipientBefore, bond, "recipient did not receive bond");
        assertEq(evaluator.bondRefunds(address(job)), 0, "refund not zeroed (CEI violation)");
    }

    function test_withdrawBond_revertWhenNothingOwed() public {
        vm.prank(address(job));
        vm.expectRevert("UMAEvaluator: no bond to withdraw");
        evaluator.withdrawBond(address(0xBEEF));
    }

    // ── Caller-not-OOv3 guard ─────────────────────────────────────────────────

    function test_callback_revertIfCallerNotOo() public {
        vm.expectRevert("UMAEvaluator: caller not OOv3");
        evaluator.assertionResolvedCallback(bytes32(0), true);
    }
}
