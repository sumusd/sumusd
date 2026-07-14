// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ImmutableTimelock} from "../src/ImmutableTimelock.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract ImmutableTimelockTest is Test {
    uint256 internal constant DELAY = 48 hours;

    ImmutableTimelock internal timelock;
    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal flavorA;

    address internal gov = makeAddr("gov"); // executor (multisig)
    address internal deployer = address(this);

    function setUp() public {
        timelock = new ImmutableTimelock(DELAY, gov);

        sumUsd = new SumUSD(deployer);
        engine = new SumUSDEngine(deployer, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));
        oracle = new MockOracle();
        flavorA = new MockERC20("Flavor A", "FLAV-A", 6);
        oracle.setPrice(address(flavorA), 1e18);

        // Hand the engine to the timelock (Ownable2Step): deployer offers, timelock accepts via a
        // queued call after the delay. After this the deployer has no power over the engine.
        engine.transferOwnership(address(timelock));
        bytes memory acceptCall = abi.encodeWithSignature("acceptOwnership()");
        vm.prank(gov);
        timelock.queue(address(engine), acceptCall, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.prank(gov);
        timelock.execute(address(engine), acceptCall, bytes32(0));

        assertEq(engine.owner(), address(timelock), "timelock owns the engine");
    }

    function _listCall() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            SumUSDEngine.setCollateral.selector, address(flavorA), true, uint16(9900), IPriceOracle(address(oracle))
        );
    }

    function test_Delay_IsImmutable() public view {
        assertEq(timelock.DELAY(), DELAY);
        // There is no setDelay function — the value is fixed at construction (compile-time guarantee).
    }

    function test_Queue_ThenExecuteAfterDelay() public {
        bytes memory data = _listCall();
        vm.prank(gov);
        timelock.queue(address(engine), data, bytes32(0));

        vm.warp(block.timestamp + DELAY);
        vm.prank(gov);
        timelock.execute(address(engine), data, bytes32(0));

        (bool enabled,, uint16 rate,,) = engine.configs(address(flavorA));
        assertTrue(enabled);
        assertEq(rate, 9900, "param change landed only after the delay");
    }

    function test_Execute_RevertsBeforeDelay() public {
        bytes memory data = _listCall();
        vm.prank(gov);
        timelock.queue(address(engine), data, bytes32(0));

        vm.warp(block.timestamp + DELAY - 1); // one second early
        vm.prank(gov);
        vm.expectRevert(ImmutableTimelock.NotReady.selector);
        timelock.execute(address(engine), data, bytes32(0));
    }

    function test_OnlyExecutor_CanQueue() public {
        vm.expectRevert(ImmutableTimelock.NotExecutor.selector);
        timelock.queue(address(engine), _listCall(), bytes32(0));
    }

    function test_DirectEngineCall_Reverts_NoBypass() public {
        // Neither the deployer nor anyone else can change the engine without going through the timelock.
        vm.expectRevert();
        engine.setCollateral(address(flavorA), true, 9900, oracle);
    }

    function test_Cancel_PreventsExecution() public {
        bytes memory data = _listCall();
        vm.startPrank(gov);
        timelock.queue(address(engine), data, bytes32(0));
        timelock.cancel(address(engine), data, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(ImmutableTimelock.NotReady.selector);
        timelock.execute(address(engine), data, bytes32(0));
        vm.stopPrank();
    }

    function test_RenounceExecutor_FreezesForever() public {
        vm.prank(gov);
        timelock.renounceExecutor();
        assertEq(timelock.executor(), address(0));
        // No one can ever queue again -> the engine's parameters are frozen permanently.
        vm.prank(gov);
        vm.expectRevert(ImmutableTimelock.NotExecutor.selector);
        timelock.queue(address(engine), _listCall(), bytes32(0));
    }
}
