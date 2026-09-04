// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice Tests for multi-flavor batch redemption ({redeemBatch}) and its quote ({previewRedeemBatch}).
///         The batch prices every leg on ONE pre-batch basket snapshot, so it is solvency-equivalent to a
///         run of single {redeem} calls and the preview matches the payout leg-for-leg.
contract RedeemBatchTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DISTRESS_RATIO_BPS = 9900;

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal a; // 6 decimals, base 99%
    MockERC20 internal b; // 6 decimals, base 99%
    MockERC20 internal c; // 18 decimals, base 97%

    address internal alice = makeAddr("alice");
    address internal recipient = makeAddr("marginRecipient");

    function setUp() public {
        sumUsd = new SumUSD(address(this));
        engine = new SumUSDEngine(address(this), sumUsd); // owner (stands in for the timelock)
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        oracle = new MockOracle();
        a = new MockERC20("Flavor A", "FLAV-A", 6);
        b = new MockERC20("Flavor B", "FLAV-B", 6);
        c = new MockERC20("Flavor C", "FLAV-C", 18);
        oracle.setPrice(address(a), WAD);
        oracle.setPrice(address(b), WAD);
        oracle.setPrice(address(c), WAD);

        engine.setCollateral(address(a), true, 9900, oracle);
        engine.setCollateral(address(b), true, 9900, oracle);
        engine.setCollateral(address(c), true, 9700, oracle);
    }

    function _deposit(address user, MockERC20 token, uint256 amount) internal returns (uint256 minted) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(engine), amount);
        minted = engine.deposit(address(token), amount, 0);
        vm.stopPrank();
    }

    /// A balanced pool (equal weights) leaves every flavor in the parity band at its flat base rate.
    function _seedBalanced() internal {
        _deposit(alice, a, 1_000e6); // 1,000 SumUSD, pool +1,000e6 A
        _deposit(alice, b, 1_000e6); // 1,000 SumUSD, pool +1,000e6 B
        _deposit(alice, c, 1_000e18); // 1,000 SumUSD, pool +1,000e18 C
        // alice now holds 3,000 SumUSD.
    }

    function _addr2(address x, address y) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = x;
        arr[1] = y;
    }

    function _u2(uint256 x, uint256 y) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = x;
        arr[1] = y;
    }

    // --- equivalence & preview -------------------------------------------------

    function test_Batch_MatchesPreviewLegForLeg() public {
        _seedBalanced();
        address[] memory cols = _addr2(address(a), address(b));
        uint256[] memory amts = _u2(100e18, 100e18);

        uint256[] memory preview = engine.previewRedeemBatch(cols, amts);

        vm.prank(alice);
        uint256[] memory outs = engine.redeemBatch(cols, amts, _u2(0, 0));

        assertEq(outs.length, 2, "one output per leg");
        assertEq(outs[0], preview[0], "leg A payout matches its preview");
        assertEq(outs[1], preview[1], "leg B payout matches its preview");
        // Base 99% at par, 6-decimal flavors, margin off: 100 SumUSD -> 99 units.
        assertEq(outs[0], 99e6, "leg A: 99% of 100 face");
        assertEq(outs[1], 99e6, "leg B: 99% of 100 face");
    }

    function test_Batch_EqualsSumOfSingleRedeems() public {
        // Fork the same starting state two ways: one batch call vs two single redeems, same order.
        uint256 snap = vm.snapshotState();

        _seedBalanced();
        vm.prank(alice);
        uint256[] memory outs = engine.redeemBatch(_addr2(address(a), address(b)), _u2(100e18, 100e18), _u2(0, 0));
        uint256 aFromBatch = a.balanceOf(alice);
        uint256 bFromBatch = b.balanceOf(alice);
        uint256 supplyAfterBatch = sumUsd.totalSupply();

        vm.revertToState(snap);

        _seedBalanced();
        vm.startPrank(alice);
        uint256 out0 = engine.redeem(address(a), 100e18, 0);
        uint256 out1 = engine.redeem(address(b), 100e18, 0);
        vm.stopPrank();

        assertEq(outs[0], out0, "batch leg A == single redeem A");
        assertEq(outs[1], out1, "batch leg B == single redeem B");
        assertEq(a.balanceOf(alice), aFromBatch, "same A received either way");
        assertEq(b.balanceOf(alice), bFromBatch, "same B received either way");
        assertEq(sumUsd.totalSupply(), supplyAfterBatch, "same SumUSD burned either way");
    }

    function test_Batch_BurnsTotalAndPaysEachLeg() public {
        _seedBalanced();
        uint256 supplyBefore = sumUsd.totalSupply();

        vm.prank(alice);
        engine.redeemBatch(_addr2(address(a), address(c)), _u2(200e18, 300e18), _u2(0, 0));

        assertEq(sumUsd.totalSupply(), supplyBefore - 500e18, "burned the sum of both legs");
        assertEq(a.balanceOf(alice), 198e6, "A leg: 99% of 200");
        assertEq(c.balanceOf(alice), 291e18, "C leg: 97% of 300 (18 decimals)");
    }

    function test_Batch_AppliesFeePerLeg() public {
        _seedBalanced();
        engine.setRedeemMargin(2, 1); // 2 bps total, 1 bp routed
        engine.setMarginRecipient(recipient);

        address[] memory cols = _addr2(address(a), address(b));
        uint256[] memory amts = _u2(1_000e18, 1_000e18);
        uint256[] memory preview = engine.previewRedeemBatch(cols, amts);

        vm.prank(alice);
        uint256[] memory outs = engine.redeemBatch(cols, amts, _u2(0, 0));

        // gross 990e6 per leg (99% base); minus 2 bps margin = 990e6 - 0.198e6 = 989.802e6.
        assertEq(outs[0], 989_802000, "leg A nets gross minus 2 bps");
        assertEq(outs[1], 989_802000, "leg B nets gross minus 2 bps");
        assertEq(outs[0], preview[0], "margin-inclusive preview matches leg A payout");
        assertEq(outs[1], preview[1], "margin-inclusive preview matches leg B payout");
        assertEq(a.balanceOf(recipient), 99000, "leg A routed 1 bp of the 990 gross");
        assertEq(b.balanceOf(recipient), 99000, "leg B routed 1 bp of the 990 gross");
    }

    // --- distress gate ---------------------------------------------------------

    function test_Batch_RevertsInDistress() public {
        _seedBalanced();
        // Drop flavor C's price so backing falls below the 99% distress line (3000 supply, ~2000+ backing).
        oracle.setPrice(address(c), 0.4e18); // 1000 A + 1000 B + 400 C = 2400 / 3000 = 80%
        assertLt(engine.systemCollateralizationRatioBps(), DISTRESS_RATIO_BPS, "system is distressed");

        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeemBatch(_addr2(address(a), address(b)), _u2(100e18, 100e18), _u2(0, 0));
    }

    // --- input validation ------------------------------------------------------

    function test_Batch_RevertsLengthMismatch() public {
        _seedBalanced();
        address[] memory cols = _addr2(address(a), address(b));
        vm.prank(alice);
        vm.expectRevert(SumUSDEngine.BatchLengthMismatch.selector);
        engine.redeemBatch(cols, _u2(100e18, 100e18), _u1(0)); // minOuts too short
    }

    function test_Batch_RevertsEmpty() public {
        _seedBalanced();
        vm.prank(alice);
        vm.expectRevert(SumUSDEngine.BatchLengthMismatch.selector);
        engine.redeemBatch(new address[](0), new uint256[](0), new uint256[](0));
    }

    function test_PreviewBatch_RevertsLengthMismatch() public {
        _seedBalanced();
        vm.expectRevert(SumUSDEngine.BatchLengthMismatch.selector);
        engine.previewRedeemBatch(_addr2(address(a), address(b)), _u1(100e18));
    }

    // --- per-leg failures revert the whole batch (atomic) ----------------------

    function test_Batch_PerLegSlippageRevertsAll() public {
        _seedBalanced();
        // Leg B demands more than its 99% base rate returns -> SlippageExceeded, reverting the batch.
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.SlippageExceeded.selector);
        engine.redeemBatch(_addr2(address(a), address(b)), _u2(100e18, 100e18), _u2(0, 100e6));
    }

    function test_Batch_UnlistedLegRevertsAll() public {
        _seedBalanced();
        MockERC20 outside = new MockERC20("Outside", "OUT", 6);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEnabled.selector);
        engine.redeemBatch(_addr2(address(a), address(outside)), _u2(100e18, 100e18), _u2(0, 0));
    }

    function test_Batch_ZeroAmountLegRevertsAll() public {
        _seedBalanced();
        vm.prank(alice);
        vm.expectRevert(SumUSDEngine.ZeroAmount.selector);
        engine.redeemBatch(_addr2(address(a), address(b)), _u2(100e18, 0), _u2(0, 0));
    }

    function test_Batch_InsufficientPoolLegRevertsAll() public {
        _seedBalanced();
        // Leg B asks for more B than the pool holds (1,000 units); gross 1,485 > 1,000 available.
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.InsufficientPool.selector);
        engine.redeemBatch(_addr2(address(a), address(b)), _u2(100e18, 1_500e18), _u2(0, 0));
    }

    function test_Batch_AtomicOnRevert() public {
        _seedBalanced();
        uint256 supplyBefore = sumUsd.totalSupply();
        // Leg A succeeds in isolation, but leg B (unlisted) reverts -> nothing settles, including leg A.
        MockERC20 outside = new MockERC20("Outside", "OUT", 6);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEnabled.selector);
        engine.redeemBatch(_addr2(address(a), address(outside)), _u2(100e18, 100e18), _u2(0, 0));

        assertEq(sumUsd.totalSupply(), supplyBefore, "no SumUSD burned when a leg reverts");
        assertEq(a.balanceOf(alice), 0, "no collateral paid when a leg reverts");
    }

    function _u1(uint256 x) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = x;
    }

    /// A batch may name the same flavor twice. On chain the second leg sees the pool balance the first leg
    /// left behind (so a scarce flavor prices worse on the second leg); the preview must replay that same
    /// draw-down instead of quoting both legs on the untouched balance, or preview != payout.
    function test_PreviewBatch_MatchesRepeatedFlavorLegs() public {
        engine.setTiltSlopeBps(500);
        engine.setRedeemMargin(2, 1);
        engine.setMarginRecipient(recipient);
        _deposit(alice, a, 1_000e6);
        _deposit(alice, b, 1_000e6);
        _deposit(alice, c, 300e18); // C at 13% of the basket: below the 16.7% knee, convex penalty live

        address[] memory cols = _addr2(address(c), address(c));
        uint256[] memory amts = _u2(50e18, 50e18);
        uint256[] memory quoted = engine.previewRedeemBatch(cols, amts);
        vm.prank(alice);
        uint256[] memory paid = engine.redeemBatch(cols, amts, _u2(0, 0));

        assertLt(paid[1], paid[0], "second leg prices on the thinner pool");
        assertEq(quoted[0], paid[0], "leg 1 preview == payout");
        assertEq(quoted[1], paid[1], "leg 2 preview == payout");
    }
}
