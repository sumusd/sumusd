// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../../src/SumUSD.sol";
import {SumUSDEngine} from "../../src/SumUSDEngine.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Stateful invariant handler. Drives {SumUSDEngine} through bounded, random sequences of user
///         and admin actions across a fixed actor set. Every engine call that may legitimately revert
///         (mint guard, distress gating, peg band, dust, freeze, etc.) is wrapped in try/catch so the
///         handler itself never reverts; ghost accounting is updated only on success. The one place it
///         may revert is a genuine invariant break (the `redeemMix` fairness check below), which is the
///         intended signal under `fail_on_revert = true`.
///
///         The handler is made the engine owner + guardian in {finishSetup} so it can freeze/unfreeze.
///         When `allowDepeg` is false, prices stay pinned at $1 (the healthy regime); when true, it can
///         move prices and kill feeds to exercise depeg / distress / oracle-fallback paths.
contract EngineHandler is Test {
    SumUSDEngine public immutable engine;
    SumUSD public immutable sumUsd;
    MockOracle public immutable oracle;
    bool public immutable allowDepeg;

    address[] public collaterals;
    address[] public actors;

    uint256 public ghostMinted; // total SumUSD minted across all successful deposits
    uint256 public ghostBurned; // total SumUSD burned across all successful redeems / redeemMix
    bool public redeemMixFair = true; // set false if any redeemMix ever reduced the backing ratio
    bool public singleRedeemNeverInDistress = true; // set false if a single-flavor redeem ever cleared below the line

    constructor(
        SumUSDEngine _engine,
        SumUSD _sumUsd,
        MockOracle _oracle,
        address[] memory _collaterals,
        bool _allowDepeg
    ) {
        engine = _engine;
        sumUsd = _sumUsd;
        oracle = _oracle;
        collaterals = _collaterals;
        allowDepeg = _allowDepeg;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
    }

    /// @dev Called once from the test setUp after ownership is offered: take engine ownership and make
    ///      this handler the guardian, so freeze/unfreeze actions work.
    function finishSetup() external {
        engine.acceptOwnership();
        engine.setGuardian(address(this));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _col(uint256 seed) internal view returns (MockERC20) {
        return MockERC20(collaterals[seed % collaterals.length]);
    }

    // --- user actions ----------------------------------------------------

    function deposit(uint256 actorSeed, uint256 colSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 col = _col(colSeed);
        amount = bound(amount, 1, 1_000_000 * (10 ** col.decimals()));
        col.mint(actor, amount);
        vm.startPrank(actor);
        col.approve(address(engine), amount);
        try engine.deposit(address(col), amount, 0) returns (uint256 minted) {
            ghostMinted += minted;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 colSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = sumUsd.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        // Snapshot the ratio the redemption is actually priced against. The distress latch is an
        // observation-driven state machine (a price move alone does not update it), so the property that
        // matters is not "the flag tracks the ratio at all times" but this: a single-flavor redemption can
        // never SUCCEED below the entry line. `_requireNotDistressed` syncs the latch from the live ratio
        // before gating, so cherry-picking must be impossible there regardless of when it was last poked.
        uint256 ratioBefore = engine.systemCollateralizationRatioBps();
        vm.prank(actor);
        try engine.redeem(collaterals[colSeed % collaterals.length], amount, 0) {
            ghostBurned += amount;
            (uint256 enterBps,,) = engine.distressParams();
            if (ratioBefore < enterBps) singleRedeemNeverInDistress = false;
        } catch {}
    }

    function redeemMix(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 bal = sumUsd.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        uint256 ratioBefore = engine.systemCollateralizationRatioBps();
        uint256 supplyBefore = sumUsd.totalSupply();
        uint256[] memory none = new uint256[](0);

        bool ok;
        vm.prank(actor);
        try engine.redeemMix(amount, none) {
            ok = true;
            ghostBurned += amount;
        } catch {}

        // Fairness: a pro-rata exit must never REDUCE the backing ratio — the pool always keeps at
        // least the redeemer's share (Sum out_i*price_i <= (amount/supply)*totalUsd), so the TRUE ratio
        // is non-decreasing. The reported ratio is an integer bps of a per-flavor FLOORED valuation
        // (`totalCollateralValueUsd` sums independently-floored `collateralValueUsd` terms), so that
        // reading can tick down by at most one wei of value per flavor — i.e. up to
        // `BPS * numFlavors / supply` bps. This is ~0 at any realistic supply and only widens at dust
        // supply (the amount the shrinker drives it to); tolerate exactly that bound so the flag tracks a
        // real economic reduction, not a valuation-floor artifact. Checked by an invariant (not reverted
        // here) so a handler revert can't be misattributed to it.
        uint256 supplyAfter = sumUsd.totalSupply();
        if (ok && supplyBefore > 0 && supplyAfter > 0) {
            uint256 tolBps = (10_000 * collaterals.length) / supplyAfter + 1;
            if (engine.systemCollateralizationRatioBps() + tolBps < ratioBefore) redeemMixFair = false;
        }
    }

    function donate(uint256 actorSeed, uint256 colSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        MockERC20 col = _col(colSeed);
        amount = bound(amount, 1, 1_000_000 * (10 ** col.decimals()));
        col.mint(actor, amount);
        vm.startPrank(actor);
        col.approve(address(engine), amount);
        try engine.donate(address(col), amount) {} catch {}
        vm.stopPrank();
    }

    // --- admin / keeper actions ------------------------------------------

    function freeze(uint256 colSeed) external {
        try engine.freezeCollateral(collaterals[colSeed % collaterals.length]) {} catch {}
    }

    function unfreeze(uint256 colSeed) external {
        try engine.setCollateralEnabled(collaterals[colSeed % collaterals.length], true) {} catch {}
    }

    function refresh() external {
        engine.refreshPrices();
    }

    function pokePrice(uint256 colSeed, uint256 priceSeed) external {
        if (!allowDepeg) return;
        // 1-in-8 kills the feed (price 0 -> reverting oracle); otherwise a price in [$0.80, $1.20].
        uint256 p = priceSeed % 8 == 0 ? 0 : bound(priceSeed, 0.8e18, 1.2e18);
        oracle.setPrice(collaterals[colSeed % collaterals.length], p);
    }
}
