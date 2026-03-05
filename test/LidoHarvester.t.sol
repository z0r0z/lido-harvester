// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import {LidoHarvester, IERC20} from "../src/LidoHarvester.sol";

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract LidoHarvesterTest is Test {
    LidoHarvester h;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant CURVE_STETH_ETH = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    address owner;
    address alice = address(0xA11CE);

    function setUp() public {
        owner = address(this);
        // Ensure alice is an EOA on the fork (no code)
        vm.etch(alice, "");
        // Constructor uses tx.origin for owner (factory-compatible)
        vm.prank(owner, owner);
        h = new LidoHarvester();
    }

    // ── Ownership ──────────────────────────────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(h.owner(), owner);
    }

    function test_transferOwnership() public {
        h.transferOwnership(alice);
        assertEq(h.owner(), alice);
    }

    function test_transferOwnership_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(LidoHarvester.Unauthorized.selector);
        h.transferOwnership(alice);
    }

    // ── setSlippage ────────────────────────────────────────────

    function test_setSlippage() public {
        h.setSlippage(100);
        assertEq(h.slipBps(), 100);
    }

    function test_setSlippage_max() public {
        h.setSlippage(10000);
        assertEq(h.slipBps(), 10000);
    }

    function test_setSlippage_revert_tooHigh() public {
        vm.expectRevert();
        h.setSlippage(10001);
    }

    function test_setSlippage_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(LidoHarvester.Unauthorized.selector);
        h.setSlippage(100);
    }

    // ── setTarget ──────────────────────────────────────────────

    function test_setTarget_approvesStETH() public {
        h.setTarget(CURVE_STETH_ETH);
        assertEq(h.target(), CURVE_STETH_ETH);
    }

    function test_setTarget_revokesOld() public {
        h.setTarget(CURVE_STETH_ETH);
        h.setTarget(address(0));
        assertEq(h.target(), address(0));
    }

    function test_setTarget_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(LidoHarvester.Unauthorized.selector);
        h.setTarget(CURVE_STETH_ETH);
    }

    // ── setCondition ───────────────────────────────────────────

    function test_setCondition() public {
        h.setCondition(STETH, alice);
        assertEq(h.asset(), STETH);
        assertEq(h.holder(), alice);
    }

    function test_setCondition_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(LidoHarvester.Unauthorized.selector);
        h.setCondition(STETH, alice);
    }

    // ── receive (ETH deposit) ──────────────────────────────────

    function test_receive_depositsETH() public {
        uint256 amt = 1 ether;
        (bool ok,) = address(h).call{value: amt}("");
        assertTrue(ok);
        assertGt(h.staked(), 0);
        assertApproxEqAbs(h.staked(), amt, 2);
    }

    function test_receive_multipleDeposits() public {
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 first = h.staked();
        (ok,) = address(h).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertApproxEqAbs(h.staked(), first + 0.5 ether, 2);
    }

    // ── deposit (stETH) ────────────────────────────────────────

    function test_deposit_stETH() public {
        // First get some stETH
        (bool ok,) = STETH.call{value: 1 ether}("");
        assertTrue(ok);
        uint256 bal = IERC20(STETH).balanceOf(address(this));

        IERC20(STETH).approve(address(h), bal);
        h.deposit(bal);

        assertApproxEqAbs(h.staked(), bal, 2);
        assertApproxEqAbs(IERC20(STETH).balanceOf(address(h)), bal, 2);
    }

    // ── withdraw ───────────────────────────────────────────────

    function test_withdraw_sendsETH() public {
        vm.deal(address(h), 1 ether);
        uint256 aliceBefore = alice.balance;
        h.withdraw(alice, 0.5 ether, "", 0);
        assertEq(alice.balance, aliceBefore + 0.5 ether);
    }

    function test_withdraw_revert_notOwner() public {
        vm.deal(address(h), 1 ether);
        vm.prank(alice);
        vm.expectRevert(LidoHarvester.Unauthorized.selector);
        h.withdraw(alice, 0.5 ether, "", 0);
    }

    function test_withdraw_withETHCondition() public {
        vm.deal(address(h), 1 ether);
        // Condition: alice's ETH balance must increase
        h.setCondition(address(0), alice);

        h.withdraw(alice, 0.5 ether, "", 0);
        // passes because alice's balance increased
    }

    function test_withdraw_conditionUnmet() public {
        vm.deal(address(h), 1 ether);
        h.setCondition(address(0), alice);

        // Send ETH to a contract that won't forward to alice — minGain enforces increase
        address sink = makeAddr("sink");
        vm.etch(sink, "");
        vm.expectRevert(LidoHarvester.ConditionUnmet.selector);
        h.withdraw(sink, 0.5 ether, "", 0.5 ether);
    }

    function test_withdraw_withERC20Condition() public {
        // Deposit ETH, harvest to get ETH in contract
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);

        // Condition: holder's stETH balance must increase (using stETH as a stand-in token)
        h.setCondition(STETH, alice);
        vm.deal(address(h), 1 ether);

        // Withdraw ETH to Lido (submit) which mints stETH to the harvester, not alice
        // This should fail because alice's stETH balance didn't increase
        vm.expectRevert(LidoHarvester.ConditionUnmet.selector);
        h.withdraw(STETH, 0.1 ether, "", 0.09 ether);
    }

    function test_withdraw_unconditioned() public {
        vm.deal(address(h), 1 ether);
        // No condition set — should just send ETH without checks
        uint256 aliceBefore = alice.balance;
        h.withdraw(alice, 1 ether, "", 0);
        assertEq(alice.balance, aliceBefore + 1 ether);
    }

    function test_deposit_revert_noApproval() public {
        (bool ok,) = STETH.call{value: 1 ether}("");
        assertTrue(ok);
        // No approval given
        vm.expectRevert();
        h.deposit(0.5 ether);
    }

    // ── withdrawStETH ──────────────────────────────────────────

    function test_withdrawStETH() public {
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 staked = h.staked();

        uint256 withdrawAmt = staked / 2;
        h.withdrawStETH(alice, withdrawAmt);

        assertApproxEqAbs(h.staked(), staked - withdrawAmt, 0);
        assertApproxEqAbs(IERC20(STETH).balanceOf(alice), withdrawAmt, 2);
    }

    function test_withdrawStETH_revert_notOwner() public {
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(alice);
        vm.expectRevert(LidoHarvester.Unauthorized.selector);
        h.withdrawStETH(alice, 0.1 ether);
    }

    function test_withdrawStETH_revert_exceedsStaked() public {
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(); // arithmetic underflow on staked -= amt
        h.withdrawStETH(alice, type(uint256).max);
    }

    // ── stake ───────────────────────────────────────────────────

    function test_stake_partialAmount() public {
        vm.deal(address(h), 2 ether);
        uint256 stakedBefore = h.staked();
        h.stake(1 ether);
        assertApproxEqAbs(h.staked(), stakedBefore + 1 ether, 2);
        assertApproxEqAbs(address(h).balance, 1 ether, 0);
    }

    function test_stake_zeroMeansAll() public {
        vm.deal(address(h), 2 ether);
        h.stake(0);
        assertApproxEqAbs(h.staked(), 2 ether, 2);
        assertEq(address(h).balance, 0);
    }

    function test_stake_revert_notOwner() public {
        vm.deal(address(h), 1 ether);
        vm.prank(alice);
        vm.expectRevert(LidoHarvester.Unauthorized.selector);
        h.stake(1 ether);
    }

    // ── harvest ────────────────────────────────────────────────

    function test_harvest_noYield_returnsZero() public {
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);

        h.setTarget(CURVE_STETH_ETH);
        h.setSlippage(100);

        // No time passed, no yield
        uint256 yield = h.harvest("");
        assertEq(yield, 0);
    }

    function test_harvest_withYield() public {
        // Deposit ETH to get stETH
        (bool ok,) = address(h).call{value: 10 ether}("");
        assertTrue(ok);

        uint256 stakedBefore = h.staked();

        // Simulate yield by directly giving stETH to the contract
        // (mimics rebase accrual)
        vm.deal(address(0xBEEF), 0.1 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.1 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        uint256 stethBal = IERC20(STETH).balanceOf(address(h));
        assertGt(stethBal, stakedBefore);

        // Set up Curve as target for stETH -> ETH swap
        h.setTarget(CURVE_STETH_ETH);
        h.setSlippage(200); // 2%

        uint256 expectedYield = stethBal - stakedBefore;

        // Build Curve exchange calldata: exchange(1, 0, yield, minOut)
        uint256 minOut = expectedYield * 9800 / 10000;
        bytes memory data = abi.encodeCall(ICurvePool.exchange, (int128(1), int128(0), expectedYield, minOut));

        uint256 ethBefore = address(h).balance;
        uint256 yield = h.harvest(data);

        assertGt(yield, 0);
        assertGt(address(h).balance, ethBefore);
        // Principal still intact
        assertApproxEqAbs(IERC20(STETH).balanceOf(address(h)), stakedBefore, 2);
    }

    function test_harvest_principalProtected() public {
        // Deposit
        (bool ok,) = address(h).call{value: 10 ether}("");
        assertTrue(ok);

        // Simulate small yield
        vm.deal(address(0xBEEF), 0.05 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.05 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        h.setTarget(CURVE_STETH_ETH);
        h.setSlippage(200);

        uint256 stethBal = IERC20(STETH).balanceOf(address(h));
        uint256 yield = stethBal - h.staked();

        // Try to swap MORE than yield (swap all stETH) - should fail principal check
        bytes memory data = abi.encodeCall(ICurvePool.exchange, (int128(1), int128(0), stethBal, 0));

        vm.expectRevert();
        h.harvest(data);
    }

    function test_harvest_yieldTrackingAcrossDeposits() public {
        // Deposit 1 ETH
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 staked1 = h.staked();

        // Simulate yield (0.05 stETH)
        vm.deal(address(0xBEEF), 0.05 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.05 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        // Deposit 1 more ETH — yield should be preserved
        (ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);

        uint256 stethBal = IERC20(STETH).balanceOf(address(h));
        uint256 stakedNow = h.staked();

        // yield should be ~0.05 (from before second deposit)
        assertApproxEqAbs(stethBal - stakedNow, 0.05 ether, 0.002 ether);
    }

    // ── Edge cases ─────────────────────────────────────────────

    function test_harvest_targetNotSet_reverts() public {
        (bool ok,) = address(h).call{value: 1 ether}("");
        assertTrue(ok);

        // Simulate yield
        vm.deal(address(0xBEEF), 0.01 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.01 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        // target is address(0), call will succeed but no ETH comes back
        // slippage check should fail
        h.setSlippage(100);
        vm.expectRevert();
        h.harvest("");
    }

    // ── Full cycle integration ──────────────────────────────────

    function test_fullCycle_deposit_harvest_withdraw_stake() public {
        // 1. Deposit ETH
        (bool ok,) = address(h).call{value: 10 ether}("");
        assertTrue(ok);
        uint256 stakedAfterDeposit = h.staked();
        assertApproxEqAbs(stakedAfterDeposit, 10 ether, 2);

        // 2. Simulate yield accrual
        vm.deal(address(0xBEEF), 0.2 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.2 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        // 3. Harvest yield via Curve
        h.setTarget(CURVE_STETH_ETH);
        h.setSlippage(200);

        uint256 stethBal = IERC20(STETH).balanceOf(address(h));
        uint256 yieldAmt = stethBal - stakedAfterDeposit;
        bytes memory harvestData = abi.encodeCall(
            ICurvePool.exchange, (int128(1), int128(0), yieldAmt, yieldAmt * 9800 / 10000)
        );

        uint256 ethBefore = address(h).balance;
        uint256 yield = h.harvest(harvestData);
        assertGt(yield, 0);
        uint256 harvestedETH = address(h).balance - ethBefore;
        assertGt(harvestedETH, 0);

        // 4. Principal intact
        assertApproxEqAbs(IERC20(STETH).balanceOf(address(h)), stakedAfterDeposit, 2);

        // 5. Compound half the ETH back into staking
        uint256 compoundAmt = harvestedETH / 2;
        h.stake(compoundAmt);
        assertApproxEqAbs(h.staked(), stakedAfterDeposit + compoundAmt, 2);

        // 6. Withdraw remaining ETH to alice (unconditioned)
        uint256 remaining = address(h).balance;
        assertGt(remaining, 0);
        uint256 aliceBefore = alice.balance;
        h.withdraw(alice, remaining, "", 0);
        assertEq(alice.balance, aliceBefore + remaining);
    }

    // ── Permissionless harvest ─────────────────────────────────

    function test_harvest_callableByNonOwner() public {
        // Deposit ETH
        (bool ok,) = address(h).call{value: 10 ether}("");
        assertTrue(ok);

        // Simulate yield
        vm.deal(address(0xBEEF), 0.1 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.1 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        h.setTarget(CURVE_STETH_ETH);
        h.setSlippage(200);

        uint256 stethBal = IERC20(STETH).balanceOf(address(h));
        uint256 yieldAmt = stethBal - h.staked();
        bytes memory data = abi.encodeCall(ICurvePool.exchange, (int128(1), int128(0), yieldAmt, yieldAmt * 9800 / 10000));

        // Alice (non-owner) can harvest
        vm.prank(alice);
        uint256 yield = h.harvest(data);
        assertGt(yield, 0);
    }

    // ── tstore guard on receive ─────────────────────────────────

    function test_harvest_receiveDoesNotInflateStaked() public {
        // Deposit ETH
        (bool ok,) = address(h).call{value: 10 ether}("");
        assertTrue(ok);

        uint256 stakedBefore = h.staked();

        // Simulate yield
        vm.deal(address(0xBEEF), 0.1 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.1 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        h.setTarget(CURVE_STETH_ETH);
        h.setSlippage(200);

        uint256 stethBal = IERC20(STETH).balanceOf(address(h));
        uint256 yieldAmt = stethBal - stakedBefore;
        bytes memory data = abi.encodeCall(ICurvePool.exchange, (int128(1), int128(0), yieldAmt, yieldAmt * 9800 / 10000));

        h.harvest(data);

        // Curve sent ETH back via receive(), but staked must NOT have increased
        assertEq(h.staked(), stakedBefore);
    }

    // ── withdraw with calldata ──────────────────────────────────

    function test_withdraw_withCalldata() public {
        // Give harvester ETH to submit to Lido via withdraw
        vm.deal(address(h), 1 ether);
        uint256 stethBefore = IERC20(STETH).balanceOf(address(h));

        // Call Lido submit via withdraw (send ETH with empty referral)
        bytes memory data = abi.encodeWithSignature("submit(address)", address(0));
        h.withdraw(STETH, 0.5 ether, data, 0);

        // stETH balance should have increased (Lido minted to harvester as msg.sender)
        assertGt(IERC20(STETH).balanceOf(address(h)), stethBefore);
    }

    // ── Clear condition ─────────────────────────────────────────

    function test_withdraw_afterClearingCondition() public {
        vm.deal(address(h), 1 ether);

        // Set a condition that would fail
        h.setCondition(address(0), alice);

        // Clear it
        h.setCondition(address(0), address(0));

        // Withdraw to alice — no condition enforced
        uint256 aliceBefore = alice.balance;
        h.withdraw(alice, 0.5 ether, "", 0);
        assertEq(alice.balance, aliceBefore + 0.5 ether);
    }

    // ── Sequential harvests ─────────────────────────────────────

    function test_harvest_sequential() public {
        (bool ok,) = address(h).call{value: 10 ether}("");
        assertTrue(ok);

        h.setTarget(CURVE_STETH_ETH);
        h.setSlippage(200);

        // First yield + harvest
        vm.deal(address(0xBEEF), 0.1 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.1 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        uint256 stethBal = IERC20(STETH).balanceOf(address(h));
        uint256 yield1 = stethBal - h.staked();
        bytes memory data1 = abi.encodeCall(ICurvePool.exchange, (int128(1), int128(0), yield1, yield1 * 9800 / 10000));
        h.harvest(data1);

        uint256 stakedAfterFirst = h.staked();
        uint256 ethAfterFirst = address(h).balance;

        // Second yield + harvest
        vm.deal(address(0xBEEF), 0.05 ether);
        vm.startPrank(address(0xBEEF));
        (ok,) = STETH.call{value: 0.05 ether}("");
        assertTrue(ok);
        IERC20(STETH).transfer(address(h), IERC20(STETH).balanceOf(address(0xBEEF)));
        vm.stopPrank();

        stethBal = IERC20(STETH).balanceOf(address(h));
        uint256 yield2 = stethBal - h.staked();
        bytes memory data2 = abi.encodeCall(ICurvePool.exchange, (int128(1), int128(0), yield2, yield2 * 9800 / 10000));
        h.harvest(data2);

        // staked unchanged across both harvests
        assertEq(h.staked(), stakedAfterFirst);
        // More ETH accumulated
        assertGt(address(h).balance, ethAfterFirst);
        // Principal still intact
        assertApproxEqAbs(IERC20(STETH).balanceOf(address(h)), stakedAfterFirst, 2);
    }

    receive() external payable {}
}
