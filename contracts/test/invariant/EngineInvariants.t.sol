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
        address[] memory list = engine.listedCollaterals();
        for (uint256 i; i < list.length; ++i) {
            engine.currentRedeemRateBps(list[i]);
            engine.collateralValueUsd(list[i]);
            engine.previewRedeem(list[i], 1e18);
        }
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
