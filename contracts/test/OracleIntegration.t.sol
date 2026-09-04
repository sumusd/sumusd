// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice End-to-end wiring of the {SumUSDEngine} to the production {ChainlinkOracleAdapter}, proving
///         the intended conservative failure mode: when a feed goes stale the adapter fails closed, so
///         deposits of that flavor revert (peg guard calls the oracle directly) while the engine's
///         try/catch values it at 0 — keeping it REDEEMABLE at its flat base rate so holders never get
///         trapped. Healthy flavors are unaffected, and minting self-heals when the feed recovers.
contract OracleIntegrationTest is Test {
    uint256 internal constant WAD = 1e18;

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    ChainlinkOracleAdapter internal adapter;

    MockERC20 internal a; // 6 decimals
    MockERC20 internal b; // 6 decimals
    MockAggregatorV3 internal feedA;
    MockAggregatorV3 internal feedB;

    address internal owner = makeAddr("owner");
    uint32 internal constant STALENESS = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(owner);
        sumUsd = new SumUSD(owner);
        engine = new SumUSDEngine(owner, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        adapter = new ChainlinkOracleAdapter(owner);
        a = new MockERC20("Flavor A", "FLAV-A", 6);
        b = new MockERC20("Flavor B", "FLAV-B", 6);
        feedA = new MockAggregatorV3(8, 1e8, block.timestamp);
        feedB = new MockAggregatorV3(8, 1e8, block.timestamp);
        adapter.setFeed(address(a), address(feedA), STALENESS, 1.1e18);
        adapter.setFeed(address(b), address(feedB), STALENESS, 1.1e18);

        engine.setCollateral(address(a), true, 9900, adapter);
        engine.setCollateral(address(b), true, 9900, adapter);
        vm.stopPrank();
    }

    function _deposit(address user, MockERC20 t, uint256 amount) internal returns (uint256) {
        t.mint(user, amount);
        vm.startPrank(user);
        t.approve(address(engine), amount);
        uint256 minted = engine.deposit(address(t), amount, 0);
        vm.stopPrank();
        return minted;
    }

    function test_HealthyFeeds_MintAndRedeemWork() public {
        assertEq(_deposit(makeAddr("u"), a, 100e6), 100e18, "fresh feed -> 1:1 mint");
        assertEq(engine.collateralValueUsd(address(a)), 100e18, "priced at $1 via adapter");
        assertEq(engine.systemCollateralizationRatioBps(), 10_000, "100% backed");
    }

    function test_StaleFeed_ValuesAtZeroAndBlocksItsDeposit() public {
        _deposit(makeAddr("lp"), a, 10_000e6); // large healthy flavor keeps backing up
        _deposit(makeAddr("u"), b, 100e6); // small flavor whose feed we will kill

        // B's feed goes stale (heartbeat missed).
        feedB.setUpdatedAt(block.timestamp - STALENESS - 1);

        // The adapter fails closed for B, so the engine values B at 0 (conservative, not stale-$1).
        assertEq(engine.collateralValueUsd(address(b)), 0, "stale feed -> 0 value");
        assertEq(engine.collateralValueUsd(address(a)), 10_000e18, "healthy feed unaffected");

        // A deposit of B reverts: the deposit peg-guard reads the oracle directly and it fails closed.
        b.mint(makeAddr("u2"), 100e6);
        vm.startPrank(makeAddr("u2"));
        b.approve(address(engine), 100e6);
        vm.expectPartialRevert(ChainlinkOracleAdapter.StalePrice.selector);
        engine.deposit(address(b), 100e6, 0);
        vm.stopPrank();
    }

    function test_StaleFeed_HoldersStillRedeemAtBase() public {
        _deposit(makeAddr("lp"), a, 10_000e6);
        address u = makeAddr("u");
        _deposit(u, b, 100e6);

        feedB.setUpdatedAt(block.timestamp - STALENESS - 1); // B feed dead

        // Backing stays above the distress line (B is small), so single-flavor redeem is allowed and
        // B falls back to its flat base rate at par via the engine try/catch — the holder is not trapped.
        vm.prank(u);
        uint256 out = engine.redeem(address(b), 100e18, 0);
        assertEq(out, 99e6, "dead-feed flavor redeems at base 99% at par");
        // The views agree with the payout (dead-feed fallback), per the #11 fix.
        assertEq(engine.currentRedeemRateBps(address(b)), 9900, "view quotes base, not 0");
    }

    function test_FeedRecovery_MintingSelfHeals() public {
        _deposit(makeAddr("lp"), a, 10_000e6);
        _deposit(makeAddr("u"), b, 100e6);

        feedB.setUpdatedAt(block.timestamp - STALENESS - 1); // stale
        // Deposit of B blocked while stale.
        b.mint(makeAddr("u2"), 1e6);
        vm.startPrank(makeAddr("u2"));
        b.approve(address(engine), 1e6);
        vm.expectPartialRevert(ChainlinkOracleAdapter.StalePrice.selector);
        engine.deposit(address(b), 1e6, 0);
        vm.stopPrank();

        // Feed publishes a fresh round -> deposits of B work again, no admin action needed.
        feedB.setAnswer(1e8, block.timestamp);
        assertEq(_deposit(makeAddr("u3"), b, 1e6), 1e18, "deposit self-heals on feed recovery");
    }

    // -----------------------------------------------------------------
    // WEAKNESS (fixed): the adapter used to REJECT a live price below an absolute "sane floor" ($0.90).
    // Combined with the engine's stale-price fallback, a genuine crash past that floor read exactly like
    // a feed outage: the flavor was valued at its last-good price minus 1% for the whole grace window,
    // backing looked healthy, and the pick-your-flavor redeem stayed open — the first-redeemer run the
    // distress gate exists to stop. A live LOW price is now passed through and valued as-is (the
    // conservative direction); only an implausibly HIGH answer is rejected.
    // -----------------------------------------------------------------
    function test_Fix_CrashBelowOldSaneFloorIsValuedNotMasked() public {
        vm.prank(owner);
        engine.setStalePriceParams(6 hours, 100); // reference fallback config
        _deposit(makeAddr("lp"), a, 10_000e6);
        address u = makeAddr("u");
        _deposit(u, b, 5_000e6); // B is one third of the pool
        engine.refreshPrices(); // last-good cache warm (anyone can keep it warm every block)

        // B's issuer collapses: the feed publishes a FRESH $0.50. True backing = (10,000 + 2,500) / 15,000.
        feedB.setAnswer(0.5e8, block.timestamp);

        assertEq(engine.collateralValueUsd(address(b)), 2_500e18, "a live low price is used as-is, never masked");
        assertEq(engine.systemCollateralizationRatioBps(), 8333, "backing reflects the crash");
        engine.pokeDistress();
        assertTrue(engine.distressed(), "a real crash trips distress immediately");

        // Cherry-picking the healthy flavor is sealed; holders share the loss via redeemMix.
        vm.prank(u);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(a), 1_000e18, 0);
    }
}
