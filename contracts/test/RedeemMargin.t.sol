// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {RecipientBlockMockERC20} from "./mocks/RecipientBlockMockERC20.sol";

/// @notice Tests for the 2 bps redemption margin, split 1 bp retained (extra backing) / 1 bp routed to a
///         timelock-settable recipient. Uses a single full-rate flavor (base 100%, tilt off) so the margin
///         is isolated from the weight-tilt haircut.
contract RedeemMarginTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal a; // 6 decimals, base rate 100%

    address internal alice = makeAddr("alice");
    address internal recipient = makeAddr("marginRecipient");

    function setUp() public {
        sumUsd = new SumUSD(address(this));
        engine = new SumUSDEngine(address(this), sumUsd); // this contract is owner (stands in for timelock)
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));
        oracle = new MockOracle();
        a = new MockERC20("Flavor A", "FLAV-A", 6);
        oracle.setPrice(address(a), WAD);
        engine.setCollateral(address(a), true, uint16(BPS), oracle); // 100% base, tilt stays 0
    }

    function _deposit(address user, uint256 amount) internal returns (uint256) {
        a.mint(user, amount);
        vm.startPrank(user);
        a.approve(address(engine), amount);
        uint256 minted = engine.deposit(address(a), amount, 0);
        vm.stopPrank();
        return minted;
    }

    // --- split ------------------------------------------------------------

    function test_Margin_SplitBetweenRecipientAndPool() public {
        _deposit(alice, 10_000e6); // 10,000 SumUSD, pool holds 10,000e6 A
        engine.setRedeemMargin(2, 1); // 2 bps total, 1 bp to recipient
        engine.setMarginRecipient(recipient);

        vm.prank(alice);
        uint256 out = engine.redeem(address(a), 1_000e18, 0);

        // gross 1,000e6; margin 2 bps = 0.2e6; to recipient 1 bp = 0.1e6; retained 0.1e6.
        assertEq(out, 999_800000, "redeemer nets gross minus the full 2 bps margin");
        assertEq(a.balanceOf(alice), 999_800000, "redeemer received the net");
        assertEq(a.balanceOf(recipient), 100000, "recipient got the 1 bp routed margin");
        assertEq(a.balanceOf(address(engine)), 9_000_100000, "pool kept 9000 face + 0.1e6 retained margin");
        // Backing value exceeds supply by the retained margin (the surplus is sub-bp, so compare in WAD).
        assertGt(engine.totalCollateralValueUsd(), sumUsd.totalSupply(), "retained margin raises backing above face");
    }

    function test_Margin_PreviewMatchesNetAndBreakdown() public {
        _deposit(alice, 10_000e6);
        engine.setRedeemMargin(2, 1);
        engine.setMarginRecipient(recipient);

        assertEq(engine.previewRedeem(address(a), 1_000e18), 999_800000, "preview equals the net payout");
        (uint256 toRedeemer, uint256 toRecipient, uint256 retained) = engine.previewRedeemMargin(address(a), 1_000e18);
        assertEq(toRedeemer, 999_800000, "breakdown: redeemer net");
        assertEq(toRecipient, 100000, "breakdown: routed margin");
        assertEq(retained, 100000, "breakdown: retained margin");

        vm.prank(alice);
        uint256 out = engine.redeem(address(a), 1_000e18, 0);
        assertEq(out, toRedeemer, "actual payout equals the previewed net");
    }

    function test_Margin_NoRecipient_WholeMarginRetained() public {
        _deposit(alice, 10_000e6);
        engine.setRedeemMargin(2, 1); // routed portion configured, but no recipient set yet

        vm.prank(alice);
        uint256 out = engine.redeem(address(a), 1_000e18, 0);

        assertEq(out, 999_800000, "redeemer still pays the full 2 bps");
        assertEq(a.balanceOf(address(engine)), 9_000_200000, "with no recipient, all 2 bps stays pooled");
    }

    function test_Margin_ZeroByDefault() public {
        _deposit(alice, 10_000e6);
        vm.prank(alice);
        uint256 out = engine.redeem(address(a), 1_000e18, 0);
        assertEq(out, 1_000e6, "no margin configured -> full payout");
    }

    // --- redeemMix is exempt ---------------------------------------------

    function test_Margin_ExemptFromRedeemMix() public {
        _deposit(alice, 1_000e6); // supply 1,000e18, pool 1,000e6
        engine.setRedeemMargin(2, 1);
        engine.setMarginRecipient(recipient);

        oracle.setPrice(address(a), 0.9e18); // backing 90% -> distress -> redeemMix path

        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        uint256[] memory amounts = engine.redeemMix(200e18, none);

        // Pure pro-rata: 200/1000 of the 1,000e6 pool = 200e6, with NO margin taken.
        assertEq(amounts[0], 200e6, "redeemMix pays pro-rata with no margin");
        assertEq(a.balanceOf(alice), 200e6, "redeemer got the full pro-rata slice");
        assertEq(a.balanceOf(recipient), 0, "no margin routed on the distress exit");
    }

    // --- best-effort routing ---------------------------------------------

    function test_Margin_BlockedRecipientDoesNotBlockRedemption() public {
        // Collateral whose issuer has blacklisted the margin recipient.
        RecipientBlockMockERC20 t = new RecipientBlockMockERC20("Blk", "BLK", 6);
        oracle.setPrice(address(t), WAD);
        engine.setCollateral(address(t), true, uint16(BPS), oracle);
        engine.setRedeemMargin(2, 1);
        engine.setMarginRecipient(recipient);
        t.setBlockedTo(recipient); // treasury can't receive this token

        t.mint(alice, 10_000e6);
        vm.startPrank(alice);
        t.approve(address(engine), 10_000e6);
        engine.deposit(address(t), 10_000e6, 0);
        // Redemption still succeeds; the un-routable margin slice just stays pooled.
        uint256 out = engine.redeem(address(t), 1_000e18, 0);
        vm.stopPrank();

        assertEq(out, 999_800000, "redeemer still nets after the margin");
        assertEq(t.balanceOf(recipient), 0, "blocked recipient received nothing");
        // Both margin bps stay pooled (routed slice skipped): 9000 face + 0.2e6.
        assertEq(t.balanceOf(address(engine)), 9_000_200000, "skipped margin slice stays pooled");
    }

    // --- rails & access ---------------------------------------------------

    function test_Margin_Rails() public {
        vm.expectPartialRevert(SumUSDEngine.InvalidRedeemMargin.selector);
        engine.setRedeemMargin(6, 1); // 6 bps > MAX_REDEEM_MARGIN_BPS (5)
        vm.expectPartialRevert(SumUSDEngine.InvalidRedeemMargin.selector);
        engine.setRedeemMargin(5, 6); // routed > total
        engine.setRedeemMargin(5, 5); // ok at the rail
        engine.setRedeemMargin(5, 2); // ok
        engine.setRedeemMargin(1, 1); // ok
        engine.setRedeemMargin(0, 0); // ok (disabled)
    }

    function test_Margin_SettersOnlyOwner() public {
        vm.startPrank(makeAddr("rando"));
        vm.expectRevert();
        engine.setRedeemMargin(2, 1);
        vm.expectRevert();
        engine.setMarginRecipient(makeAddr("x"));
        vm.stopPrank();
    }
}
