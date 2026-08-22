// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ImmutableTimelock} from "../../src/ImmutableTimelock.sol";

contract PingTarget {
    uint256 public pings;

    function ping() external {
        pings++;
    }
}

/// @notice Symbolic (halmos) properties of {ImmutableTimelock}: the delay / grace window and the
///         executor-vs-canceller split hold for every timestamp and every caller.
contract ImmutableTimelockHalmos is Test {
    uint256 internal constant DELAY = 96 hours;
    uint256 internal constant GRACE = 14 days;
    uint256 internal constant T0 = 1_700_000_000;

    ImmutableTimelock internal timelock;
    PingTarget internal target;
    address internal executor = address(0xE0);
    address internal canceller = address(0xCA);
    bytes internal data = abi.encodeCall(PingTarget.ping, ());
    bytes32 internal salt = bytes32(uint256(1));
    uint256 internal readyAt;

    function setUp() public {
        vm.warp(T0);
        target = new PingTarget();
        timelock = new ImmutableTimelock(DELAY, GRACE, executor, canceller);
        vm.prank(executor);
        timelock.queue(address(target), data, salt);
        readyAt = T0 + DELAY;
    }

    /// @dev A queued operation executes iff `readyAt <= now <= readyAt + GRACE`: never early, never late.
    function check_execute_onlyInsideWindow(uint256 t) public {
        vm.assume(t >= T0 && t < type(uint64).max);
        vm.warp(t);
        vm.prank(executor);
        (bool ok,) = address(timelock).call(abi.encodeCall(timelock.execute, (address(target), data, salt)));
        bool inWindow = t >= readyAt && t <= readyAt + GRACE;
        assertEq(ok, inWindow);
        assertEq(target.pings(), inWindow ? 1 : 0);
    }

    /// @dev Only the executor can execute, at any time.
    function check_execute_onlyExecutor(address caller, uint256 t) public {
        vm.assume(caller != executor);
        vm.assume(t >= T0 && t < type(uint64).max);
        vm.warp(t);
        vm.prank(caller);
        (bool ok,) = address(timelock).call(abi.encodeCall(timelock.execute, (address(target), data, salt)));
        assertFalse(ok);
        assertEq(target.pings(), 0);
    }

    /// @dev Exactly the executor and the canceller can veto a queued operation; nobody else.
    function check_cancel_executorOrCancellerOnly(address caller) public {
        vm.prank(caller);
        (bool ok,) = address(timelock).call(abi.encodeCall(timelock.cancel, (address(target), data, salt)));
        bool allowed = caller == executor || caller == canceller;
        assertEq(ok, allowed);
        bytes32 id = timelock.operationId(address(target), data, salt);
        assertEq(timelock.eta(id), allowed ? 0 : readyAt);
    }

    /// @dev The canceller has no power to queue; only the executor does.
    function check_queue_onlyExecutor(address caller, bytes32 otherSalt) public {
        vm.assume(caller != executor);
        vm.prank(caller);
        (bool ok,) = address(timelock).call(abi.encodeCall(timelock.queue, (address(target), data, otherSalt)));
        assertFalse(ok);
    }
}
