// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {SumUSD} from "../../src/SumUSD.sol";
import {SumUSDEngine} from "../../src/SumUSDEngine.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {EngineHandler} from "./EngineHandler.sol";

/// @notice Shared scaffolding and the robust invariants that must hold in BOTH regimes (healthy and
///         adversarial-with-depeg). Concrete suites below choose the regime via `_init(allowDepeg)`.
abstract contract EngineInvariantBase is Test {
    uint256 internal constant BPS = 10_000;

    SumUSDEngine internal engine;
    SumUSD internal sumUsd;
    MockOracle internal oracle;
    EngineHandler internal handler;

    function _init(bool allowDepeg) internal {
        sumUsd = new SumUSD(address(this));
        engine = new SumUSDEngine(address(this), sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));
        oracle = new MockOracle();

        address[] memory cols = new address[](3);
        cols[0] = address(new MockERC20("Flavor A", "FLAV-A", 6));
        cols[1] = address(new MockERC20("Flavor B", "FLAV-B", 6));
        cols[2] = address(new MockERC20("Flavor C", "FLAV-C", 18));
        uint16[3] memory rates = [uint16(9900), 9900, 9700];
        for (uint256 i; i < 3; ++i) {
            oracle.setPrice(cols[i], 1e18);
            engine.setCollateral(cols[i], true, rates[i], oracle);
        }
        engine.setTiltSlopeBps(500);
        if (allowDepeg) engine.setStalePriceParams(1 days, 100);

        handler = new EngineHandler(engine, sumUsd, oracle, cols, allowDepeg);
        engine.transferOwnership(address(handler));
        handler.finishSetup(); // handler takes engine ownership + becomes guardian

        // Fuzz only the handler's action functions.
        bytes4[] memory sels = new bytes4[](8);
        sels[0] = EngineHandler.deposit.selector;
        sels[1] = EngineHandler.redeem.selector;
        sels[2] = EngineHandler.redeemMix.selector;
        sels[3] = EngineHandler.donate.selector;
        sels[4] = EngineHandler.freeze.selector;
        sels[5] = EngineHandler.unfreeze.selector;
        sels[6] = EngineHandler.refresh.selector;
        sels[7] = EngineHandler.pokePrice.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // --- robust invariants (hold under depeg too) ------------------------

    /// The effective redeem rate is always clamped to at most 100% — over-collateralization can never
    /// be eroded by a redemption returning more than face.
    function invariant_redeemRateNeverExceeds100() public view {
        address[] memory list = engine.listedCollaterals();
        for (uint256 i; i < list.length; ++i) {
            assertLe(engine.currentRedeemRateBps(list[i]), BPS, "effective redeem rate > 100%");
        }
    }

    /// Supply accounting integrity: total supply is exactly what the engine minted minus what it burned.
    function invariant_supplyEqualsMintedMinusBurned() public view {
        assertEq(sumUsd.totalSupply(), handler.ghostMinted() - handler.ghostBurned(), "supply != minted - burned");
    }

    /// The engine is a pure minter/burner; it never custodies SumUSD itself.
    function invariant_engineHoldsNoSumUsd() public view {
        assertEq(sumUsd.balanceOf(address(engine)), 0, "engine holds SumUSD");
    }

    /// The collateral list never exceeds the immutable cap.
    function invariant_collateralCapNeverExceeded() public view {
        assertLe(engine.collateralCount(), 24, "collateral cap exceeded");
    }

    /// The pro-rata distress exit (`redeemMix`) never reduces the backing ratio: every holder gets an
    /// order-independent, fair slice and the ratio stays flat-or-up (rounding keeps dust pooled).
    function invariant_redeemMixNeverReducesRatio() public view {
        assertTrue(handler.redeemMixFair(), "redeemMix reduced the backing ratio");
    }

    /// No broken/dead feed or frozen flavor can brick the load-bearing views (they must never revert).
    function invariant_coreViewsNeverRevert() public view {
        engine.systemCollateralizationRatioBps();
        engine.totalCollateralValueUsd();
        engine.poolNeeds();
        engine.distressClearsAt();
        address[] memory list = engine.listedCollaterals();
        for (uint256 i; i < list.length; ++i) {
            engine.currentRedeemRateBps(list[i]);
            engine.marginalRedeemRateBps(list[i]);
            engine.redeemRateBpsFor(list[i], 1e18);
            engine.collateralValueUsd(list[i]);
            engine.previewRedeem(list[i], 1e18);
        }
    }

    /// Integrated pricing: the rate a given SIZE pays is never better than the marginal quote. This is
    /// what stops a self-created imbalance from being cashed out — unwinding a deposit unwinds the share
    /// that justified its bonus, so a manipulated round trip can never beat an honest one.
    function invariant_sizedRateNeverBeatsMarginal() public view {
        address[] memory list = engine.listedCollaterals();
        for (uint256 i; i < list.length; ++i) {
            uint256 marginal = engine.marginalRedeemRateBps(list[i]);
            assertLe(engine.redeemRateBpsFor(list[i], 1e18), marginal, "sized rate beats marginal (small)");
            assertLe(engine.redeemRateBpsFor(list[i], 1_000e18), marginal, "sized rate beats marginal (large)");
        }
    }

    /// A redemption never hands out more than $1 of mark-to-market value per SumUSD burned. The payout is
    /// price-blind below par (a sub-$1 flavor pays par units, which is what keeps the round-trip arbitrage
    /// closed) but clamped above it, so an above-$1 flavor cannot be stripped from the pool at par.
    /// @dev Bounded against the LIVE price only. The clamp is deliberately live-only, because a dead feed
    ///      must fall back to a flat base rate at par so holders can always exit without the oracle. The
    ///      residual (a flavor that spikes above $1 and then loses its feed pays par units) is the price of
    ///      that liveness guarantee.
    function invariant_neverPaysAbovePar() public view {
        address[] memory list = engine.listedCollaterals();
        for (uint256 i; i < list.length; ++i) {
            (uint256 price, bool ok) = engine.livePriceWad(list[i]);
            if (!ok) continue;
            uint256 out = engine.previewRedeem(list[i], 1e18); // token decimals
            uint256 valueOut = (out * price) / (10 ** _decimalsOf(list[i]));
            assertLe(valueOut, 1e18, "redemption pays more than $1 of value per SumUSD");
        }
    }

    /// A single-flavor (cherry-pick) redemption never SUCCEEDS below the distress entry line. This is the
    /// anti-run property; the `distressed()` flag itself is observation-driven and may lag a pure price
    /// move, but `_requireNotDistressed` re-syncs from the live ratio before gating, so the gate cannot be
    /// stepped around by simply not poking it.
    function invariant_noCherryPickingBelowTheDistressLine() public view {
        assertTrue(handler.singleRedeemNeverInDistress(), "single redeem cleared below the distress line");
    }

    /// A single-flavor redemption never lowers the backing ratio, in ANY regime (prices moving, feeds dying,
    /// stale fallback on). Outside distress the ratio can sit between 99% and par; the effective rate is
    /// capped at that ratio so an exit can never hand out more per SumUSD than the pool holds per SumUSD.
    /// This is the premise behind `redeemBatch`'s single up-front distress check, now enforced.
    function invariant_singleRedeemNeverLowersRatio() public view {
        assertTrue(handler.singleRedeemNeverLoweredRatio(), "single redeem lowered the backing ratio");
    }

    /// The recovery clock only ever runs while the latch is set, and the published clearing time always
    /// agrees with it.
    function invariant_distressLatchConsistent() public view {
        (,, uint256 delay) = engine.distressParams();
        if (!engine.distressed()) {
            assertEq(engine.recoveryStartedAt(), 0, "recovery clock runs while healthy");
            assertEq(engine.distressClearsAt(), 0, "clearing time published while healthy");
        } else if (engine.recoveryStartedAt() != 0) {
            assertEq(engine.distressClearsAt(), engine.recoveryStartedAt() + delay, "clearing time disagrees");
        }
    }

    /// A de-backed flavor contributes exactly nothing to backing, so the solvency ratio reflects only
    /// value that can actually be redeemed and distress triggers honestly.
    function invariant_deBackedFlavorCountsZero() public view {
        address[] memory list = engine.listedCollaterals();
        for (uint256 i; i < list.length; ++i) {
            (,,,, bool excluded) = engine.configs(list[i]);
            if (excluded) assertEq(engine.collateralValueUsd(list[i]), 0, "de-backed value must read 0");
        }
    }

    function _decimalsOf(address token) internal view returns (uint256) {
        (, uint8 dec,,,) = engine.configs(token);
        return dec;
    }
}

/// @notice Healthy regime: prices pinned at $1 (no depeg). Adds the core over-collateralization
///         invariant — with nothing depegged, mark-to-market backing is always >= supply and the ratio
///         never drops below 100%.
contract EngineHealthyInvariants is EngineInvariantBase {
    function setUp() public {
        _init(false);
    }

    function invariant_backingAtLeastSupply() public view {
        assertGe(engine.totalCollateralValueUsd(), sumUsd.totalSupply(), "backing < supply while healthy");
    }

    function invariant_ratioAtLeast100Pct() public view {
        if (sumUsd.totalSupply() == 0) return; // supply 0 => ratio is the "infinite" sentinel
        assertGe(engine.systemCollateralizationRatioBps(), BPS, "ratio < 100% while healthy");
    }
}

/// @notice Adversarial regime: the handler moves prices and kills feeds. Only the robust invariants
///         from the base apply (a real de-peg can legitimately push backing below 100% -> distress);
///         `redeemMix` fairness is enforced per-call inside the handler.
contract EngineDistressInvariants is EngineInvariantBase {
    function setUp() public {
        _init(true);
    }
}
