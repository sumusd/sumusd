// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {SumUSD} from "./SumUSD.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title SumUSDEngine
/// @notice Core vault that aggregates multiple whitelisted, GENIUS-Act-compliant stablecoin
///         "flavors" into a single over-collateralized USD token, {SumUSD}.
///
/// @dev Pooled peg-stability-module model:
///      - Anyone may `deposit` an accepted collateral and receive freshly minted SumUSD.
///      - Anyone may `redeem` SumUSD for any accepted collateral the pool currently holds.
///      - Collateral is pooled (not tracked per-user), so SumUSD is fungible USD backed by
///        the whole basket rather than a claim on a specific deposit.
///
///      Over-collateralization mechanism:
///        - Deposits are a raw 1:1 unit swap (decimal-normalized): 1 unit of any accepted
///          collateral mints exactly 1 SumUSD, independent of the oracle price — all flavors are
///          treated as perfectly fungible $1 units. Redemptions are likewise a fungible 1:1 unit
///          swap (minus the haircut) — the oracle never prices the swap on either side; it is used
///          only for the deposit peg-band guard (below), the backing ratio, and weighing each
///          flavor's basket share for the redemption tilt. (Trade-off:
///          within the peg band a deposit can mint up to MAX_DEPOSIT_PRICE_DEVIATION_BPS more
///          SumUSD than the USD value actually deposited; the band keeps that bounded.)
///        - Redemptions apply a per-collateral haircut via a base `redeemRateBps` (<= 100%): burning 1
///          SumUSD returns only `redeemRateBps` worth of collateral. More conservatively rated flavors
///          can carry a steeper base haircut.
///      Each redemption therefore leaves residual value in the pool, so the system trends
///      above 100% backing over time. That surplus is locked as permanent backing — there is
///      no margin or sweep path to extract it.
///
///      Weight-tilted haircut with a parity band (the basket's only balance mechanism). Each
///      flavor has an equal-weight target (1 / number of funded collaterals). A WIDE parity band is
///      tolerated first: a flavor redeems at its base
///      `redeemRateBps` (no tilt) while its weight sits between 1/2x and 2x its target. Only beyond
///      the band does the tilt engage, measured from the band edge so the rate is continuous:
///        - ABOVE 2x target: a small linear "overweight discount" (smaller haircut), capped at 100%.
///        - BELOW 1/2x target: a CONVEX "underweight premium" (larger haircut) that grows steeply as
///          the flavor nears depletion — so draining a scarce flavor is self-defeating (the last
///          units return almost nothing) yet never reverts: every flavor stays redeemable.
///      The rate is clamped to [0, 100%], so a redemption never returns more than the burned face
///      value (over-collateralization is preserved). `tiltSlopeBps = 0` => flat haircut everywhere.
///      Deposits are uncapped; {poolNeeds} surfaces the most under-represented flavor so the frontend
///      can steer fresh deposits toward balance.
///
///      Mint guard: `deposit` reverts (UnderCollateralized) whenever systemCollateralizationRatioBps()
///      is below MIN_MINT_RATIO_BPS (99%), so no new SumUSD is minted into an under-backed pool. The
///      slack below 100% accommodates collateral that normally trades just under $1. Redemptions stay
///      open so holders can still exit.
///
///      Distress mode (anti-run): below DISTRESS_ENTER_RATIO_BPS (99%) the system LATCHES into distress,
///      the pick-your-flavor `redeem` is disabled, and holders exit via `redeemMix` — a pro-rata claim
///      returning sumUsd/totalSupply of EVERY collateral. This shares the shortfall equally regardless of
///      redemption order (no first-redeemer advantage), keeps the backing ratio flat as holders exit, and
///      needs no oracle. The latch clears only once backing holds at/above DISTRESS_EXIT_RATIO_BPS
///      (100.25%) for DISTRESS_RECOVERY_DELAY: a par redemption at a rate equal to the current ratio is
///      ratio-NEUTRAL, so a bare threshold crossed once by a dust donation would otherwise stay crossed
///      through an unlimited cherry-picking drain.
///
///      Governance: there is intentionally NO global pause — deposits and redemptions can never be
///      halted wholesale by an admin. Collateral configuration (`setCollateral`,
///      `setCollateralEnabled`, `setTiltSlopeBps`) is `onlyOwner`; in production the owner is an
///      {ImmutableTimelock} (deployer EOA renounced), so every change is queued and waits the
///      timelock's immutable delay before landing. The one fast lever is a `guardian` that can
///      `freezeCollateral` (disable a single collateral) instantly — a narrow brake that only stops
///      exposure, never moves value and never re-enables (un-freezing is owner/timelock-only). A
///      frozen collateral is dropped from the active weight set but still counts toward backing and
///      **stays redeemable** — its tilt is kept in the penalty direction only (scarcity can discount
///      it, a freeze never raises its rate), so even freezing every flavor can never trap holders.
///      The safety-rail constants (peg band, mint ratio) are immutable with no setter at all.
contract SumUSDEngine is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @notice Maximum deviation from $1.00 (WAD) a collateral's oracle price may show and still
    ///         allow a deposit/mint, in basis points. Redemptions are intentionally NOT gated by
    ///         this, so holders can always exit during a depeg.
    uint256 internal constant MAX_DEPOSIT_PRICE_DEVIATION_BPS = 50; // 0.5%
    /// @notice Minimum system collateralization required to mint, in bps. Below this, deposits
    ///         revert. 9900 (99%) leaves slack for collateral that normally trades just under $1,
    ///         while still pausing mints during a genuine de-peg.
    /// @dev LOAD-BEARING COUPLING with `MAX_DEPOSIT_PRICE_DEVIATION_BPS`, asserted in the constructor:
    ///      par minting accepts collateral worth as little as `BPS - MAX_DEPOSIT_PRICE_DEVIATION_BPS`
    ///      (currently $0.9950) while minting a full $1 of supply, so an unbounded sequence of worst-case
    ///      in-band deposits drives the backing ratio ASYMPTOTICALLY toward that floor and no further.
    ///      Keeping `MIN_MINT_RATIO_BPS <= BPS - MAX_DEPOSIT_PRICE_DEVIATION_BPS` is what makes it
    ///      impossible to grief the system into distress with deposits alone. The current 50 bps of slack
    ///      is the whole margin: widening the peg band to 100 bps would silently delete it.
    uint256 internal constant MIN_MINT_RATIO_BPS = 9900; // 99%
    /// @notice Distress ENTRY line. Below this backing ratio the system latches into distress mode:
    ///         minting is already frozen (== MIN_MINT_RATIO_BPS) and single-flavor `redeem` is disabled
    ///         in favor of {redeemMix} — a pro-rata claim on the whole basket that shares the shortfall
    ///         equally across holders, removing the first-redeemer advantage / run incentive. Entry is
    ///         instant (a safety action never waits).
    uint256 internal constant DISTRESS_ENTER_RATIO_BPS = 9900; // 99%
    /// @notice Distress EXIT line, strictly above the entry line. Once latched, distress mode clears only
    ///         after backing has held at or above THIS ratio for `DISTRESS_RECOVERY_DELAY`. The gap is
    ///         deliberate hysteresis: without it, a bare threshold could be re-crossed by a dust
    ///         {donate}, and because a par redemption at an effective rate equal to the current ratio is
    ///         ratio-NEUTRAL, that single crossing would then unlock an unlimited cherry-picking drain
    ///         that never re-trips the gate. Requiring a real recapitalization above 100% closes that.
    uint256 internal constant DISTRESS_EXIT_RATIO_BPS = 10_025; // 100.25%
    /// @notice How long backing must hold at/above `DISTRESS_EXIT_RATIO_BPS` before distress mode clears.
    ///         Stops a single-block oracle blip from re-opening single-flavor redemption. Holders are
    ///         never trapped by the wait: {redeemMix} stays open for the whole of distress mode.
    uint256 internal constant DISTRESS_RECOVERY_DELAY = 6 hours;
    /// @notice Minimum USD value (WAD) a collateral must hold to count toward the tilt's `funded` count
    ///         and enabled-basket total. `funded` sets the equal-weight target and therefore BOTH parity
    ///         band edges, so without a floor anyone could shift every rate in the basket by dusting an
    ///         empty listed flavor (1 wei of a 6-decimal token values at 1e12 WAD, i.e. non-zero). It also
    ///         removes the cliff at the bottom of a drain, where a flavor rounding to zero value would
    ///         otherwise jump every other flavor's edges. Backing accounting is unaffected: a sub-floor
    ///         balance still counts in full toward `totalCollateralValueUsd`.
    uint256 internal constant MIN_FUNDED_VALUE_WAD = 1e18; // $1.00
    /// @notice Immutable sanity rails on a collateral's base `redeemRateBps`. Governance may tune
    ///         the base rate, but only within [95%, 100%]: the upper bound preserves
    ///         over-collateralization (a redemption can never return more than face), the lower
    ///         bound caps the base haircut at 5% so governance can never set a punitive/near-zero
    ///         payout. (The convex tilt can still push the *effective* rate below this on a badly
    ///         under-represented flavor; these rails bound only the configurable base.)
    uint256 internal constant MIN_REDEEM_RATE_BPS = 9500; // 95% (max 5% base haircut)
    uint256 internal constant MAX_REDEEM_RATE_BPS = BPS; // 100% (never returns more than face)
    /// @notice Immutable sanity rail on the global `tiltSlopeBps`. Caps how steep the convex
    ///         premium / linear discount can get, so governance can never set a slope that makes
    ///         normally-imbalanced flavors effectively unredeemable (rate → 0). 0 stays valid (flat).
    uint256 internal constant MAX_TILT_SLOPE_BPS = 5000;
    /// @notice Maximum number of listed collaterals. Bounds the basket-wide loops
    ///         (`deposit`/`redeem`/`_basketSnapshot`/`poolNeeds`) so their gas
    ///         can never grow without limit. Drained, disabled collaterals can be removed to free a
    ///         slot ({removeCollateral}).
    uint256 internal constant MAX_COLLATERALS = 24;
    /// @notice Immutable cap on a listed collateral's decimals. Every GENIUS-Act payment stablecoin uses
    ///         6 or 18; values above 18 would strain the engine's `10 ** decimals` unit math, so they are
    ///         rejected by the listing probe ({_probeCollateral}).
    uint8 internal constant MAX_COLLATERAL_DECIMALS = 18;
    /// @notice Immutable sanity rail on the total `redeemMarginBps`. Caps the redemption margin governance
    ///         can impose (on top of the tilt haircut) at 5 bps (0.05%), so no admin can set a punitive
    ///         exit margin. 0 stays valid (no margin). The routable portion is separately capped at `redeemMarginBps`.
    uint256 internal constant MAX_REDEEM_MARGIN_BPS = 5; // 0.05%
    /// @notice Immutable cap on the stale-price grace window (see {stalePriceGraceSeconds}), so
    ///         governance can never let a collateral be valued at a price older than this.
    uint256 internal constant MAX_STALE_PRICE_GRACE = 1 days;

    /// @notice Per-collateral risk parameters and pricing.
    struct CollateralConfig {
        bool enabled; // whether deposits/redemptions are allowed
        uint8 decimals; // cached token decimals, read once on listing
        uint16 redeemRateBps; // base collateral value returned per 1 SumUSD on redemption; <= BPS => over-collateralized
        IPriceOracle oracle; // USD price feed (18-decimal WAD)
        bool backingExcluded; // "siloed": value not counted toward backing/tilt (see setCollateralBackingExcluded)
    }

    /// @notice The aggregated stablecoin minted/burned by this engine.
    SumUSD public immutable sumUsd;

    /// @notice Risk config per collateral token.
    mapping(address token => CollateralConfig config) public configs;
    /// @notice All collateral tokens ever listed (entries are never removed, only disabled).
    address[] public collateralList;

    /// @notice Sensitivity of the redemption haircut to basket imbalance, in bps. 0 disables the
    ///         tilt (flat haircut). Higher values reward/penalize off-target redemptions more.
    uint16 public tiltSlopeBps;

    /// @notice Address that can instantly freeze (disable) a single collateral via {freezeCollateral}.
    ///         A fast, narrow safety brake — it can only stop exposure, never move value or re-enable.
    address public guardian;

    /// @notice Total redemption margin (bps of the gross payout) taken on single-flavor {redeem}, ON TOP
    ///         of the weight-tilt haircut. 0 disables the margin. Railed to `MAX_REDEEM_MARGIN_BPS`. The
    ///         distress exit {redeemMix} is intentionally exempt (it stays margin/haircut/oracle-free).
    uint16 public redeemMarginBps;
    /// @notice Portion of `redeemMarginBps` routed to {marginRecipient}; the remainder stays in the pool as
    ///         extra backing (an additional haircut). Must be <= `redeemMarginBps`. With the reference
    ///         2 bps / 1 bp config: 1 bp is paid to the recipient and 1 bp is retained as backing.
    uint16 public marginToRecipientBps;
    /// @notice Recipient of the routed margin portion. Settable only by the owner (the 96h timelock). While
    ///         unset (`address(0)`), the routed portion also stays in the pool, so no value leaves.
    address public marginRecipient;

    /// @notice Stale-price fallback (anti-distress-on-outage). When a collateral's LIVE feed is
    ///         unavailable, it is valued for the BACKING/tilt math at its last-good price minus
    ///         `stalePriceHaircutBps`, but only for `stalePriceGraceSeconds` after that last good read;
    ///         after the grace window it values at 0 (the fully-conservative default). This stops a
    ///         *transient* feed outage from cratering `systemCollateralizationRatioBps()` and tripping
    ///         the whole system into distress. `stalePriceGraceSeconds == 0` disables the fallback.
    ///         It NEVER covers the deposit peg guard (live-only, fail-closed) or the redemption payout
    ///         (par, oracle-independent). Owner-settable, railed to `MAX_STALE_PRICE_GRACE`.
    uint32 public stalePriceGraceSeconds;
    /// @notice Conservative haircut applied to a last-good price when it is used as the stale fallback.
    uint16 public stalePriceHaircutBps;
    /// @notice Last live, non-zero price recorded for a collateral, and when it was recorded. Warmed by
    ///         deposits/redemptions of that flavor and by the permissionless {refreshPrices} keeper hook.
    mapping(address token => uint256 priceWad) public lastGoodPriceWad;
    mapping(address token => uint256 timestamp) public lastGoodPriceAt;

    /// @notice Whether the system is latched into distress mode. Set the moment backing is observed below
    ///         `DISTRESS_ENTER_RATIO_BPS`; cleared only once backing has held at/above
    ///         `DISTRESS_EXIT_RATIO_BPS` for `DISTRESS_RECOVERY_DELAY`. While true, single-flavor
    ///         {redeem}/{redeemBatch} revert and holders exit pro-rata via {redeemMix}.
    bool public distressed;
    /// @notice Timestamp at which backing was first observed at/above `DISTRESS_EXIT_RATIO_BPS` during the
    ///         current distress episode; 0 while not counting down. Reset to 0 whenever a reading falls
    ///         back below the exit line, so the recovery window must be held continuously.
    uint64 public recoveryStartedAt;

    /// @notice Block-start reference for the enabled-basket total (see {_basketRefTotalUsd}). The first
    ///         state-changing call in a block records the total it observed BEFORE its own effect; later
    ///         calls in the same block price the tilt against whichever of (spot, this reference) is less
    ///         favorable to the redeemer. Without it, one deposit could collapse every other flavor's
    ///         measured share below the convex knee and drive their redemption rates to zero for the rest
    ///         of the block.
    uint64 public basketRefBlock;
    uint192 public basketRefTotalUsd;

    event CollateralListed(address indexed token, uint16 redeemRateBps, address oracle);
    event CollateralUpdated(address indexed token, bool enabled, uint16 redeemRateBps, address oracle);
    event Deposited(address indexed user, address indexed collateral, uint256 amountIn, uint256 sumUsdOut);
    event Redeemed(address indexed user, address indexed collateral, uint256 sumUsdIn, uint256 amountOut);
    event RedeemedMix(address indexed user, uint256 sumUsdIn, uint256[] amountsOut);
    event Donated(address indexed from, address indexed collateral, uint256 amount);
    event TiltSlopeUpdated(uint16 tiltSlopeBps);
    event GuardianUpdated(address indexed guardian);
    event CollateralFrozen(address indexed token, address indexed by);
    event CollateralRemoved(address indexed token);
    event CollateralBackingExcludedSet(address indexed token, bool excluded);
    event RedeemMarginUpdated(uint16 redeemMarginBps, uint16 marginToRecipientBps);
    event MarginRecipientUpdated(address indexed marginRecipient);
    event RedeemMarginPaid(
        address indexed collateral, address indexed recipient, uint256 toRecipient, uint256 retained
    );
    event StalePriceParamsUpdated(uint32 graceSeconds, uint16 haircutBps);
    event PriceRecorded(address indexed token, uint256 priceWad, uint256 at);
    event DistressEntered(uint256 ratioBps);
    event DistressRecoveryStarted(uint256 ratioBps, uint256 clearsAt);
    event DistressRecoveryReset(uint256 ratioBps);
    event DistressCleared(uint256 ratioBps);

    error CollateralNotEnabled(address token);
    error ZeroAmount();
    error SlippageExceeded(uint256 actual, uint256 minExpected);
    error InsufficientPool(address token, uint256 requested, uint256 available);
    error InvalidRedeemRate(uint16 redeemRateBps);
    error InvalidOracle();
    error PriceOutOfBand(address token, uint256 priceWad);
    error UnderCollateralized(uint256 ratioBps);
    error NotGuardian();
    error InvalidTiltSlope(uint16 tiltSlopeBps);
    error CollateralCapReached(uint256 max);
    error CollateralStillEnabled(address token);
    error CollateralNotEmpty(address token);
    error InvalidCollateralDecimals(uint8 decimals);
    error CollateralProbeFailed(address token);
    error UseRedeemMix(uint256 ratioBps);
    error NotDistressed(uint256 ratioBps);
    error MinOutLengthMismatch();
    error BatchLengthMismatch();
    error ZeroCollateralOut(uint256 sumUsdAmount);
    error InvalidRedeemMargin(uint16 redeemMarginBps, uint16 marginToRecipientBps);
    error InvalidStalePriceParams(uint32 graceSeconds, uint16 haircutBps);
    error CollateralBackingExcluded(address token);
    error MintDisabledInDistress(uint256 ratioBps);

    /// @param admin   Owner of the engine (risk admin / governance).
    /// @param _sumUsd The SumUSD token. The engine must be granted MINTER_ROLE on it separately.
    constructor(address admin, SumUSD _sumUsd) Ownable(admin) {
        require(address(_sumUsd) != address(0), "engine: sumUsd=0");
        // The anti-dilution bound in MIN_MINT_RATIO_BPS: worst-case in-band deposits can only drive backing
        // toward (BPS - MAX_DEPOSIT_PRICE_DEVIATION_BPS), so the mint floor must sit at or below it.
        require(MIN_MINT_RATIO_BPS <= BPS - MAX_DEPOSIT_PRICE_DEVIATION_BPS, "engine: mint floor above peg band");
        require(DISTRESS_EXIT_RATIO_BPS > DISTRESS_ENTER_RATIO_BPS, "engine: distress hysteresis inverted");
        sumUsd = _sumUsd;
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    /// @notice Deposit `amount` of `collateral` and mint SumUSD as a raw 1:1 unit swap, normalized
    ///         for the token's decimals. The oracle price does not affect the minted amount; it only
    ///         gates the peg-band guard. One unit of any accepted collateral mints one SumUSD.
    /// @dev Reverts `UnderCollateralized` if system backing is below `MIN_MINT_RATIO_BPS` (99%);
    ///      no new SumUSD is issued into an under-backed pool. First deposit at zero supply is always
    ///      allowed. Also reverts `MintDisabledInDistress` while the distress latch is set, whatever the
    ///      ratio: the latched regime is exit-only (see {_syncDistress}); recapitalization is {donate}.
    /// @param collateral Accepted collateral token.
    /// @param amount     Amount of collateral to deposit (in the token's own decimals).
    /// @param minSumUsdOut Minimum SumUSD to accept (guards against fee-on-transfer shortfalls).
    /// @return minted Amount of SumUSD minted to the caller.
    function deposit(address collateral, uint256 amount, uint256 minSumUsdOut)
        external
        nonReentrant
        returns (uint256 minted)
    {
        CollateralConfig memory c = configs[collateral];
        if (!c.enabled) revert CollateralNotEnabled(collateral);
        // A de-backed ("siloed") flavor contributes 0 to backing, so minting against it 1:1 would dilute
        // every holder on the spot. Exclusion and the guardian freeze are separate levers on separate
        // timelocks, so the deposit path enforces the pairing rather than relying on governance to.
        if (c.backingExcluded) revert CollateralBackingExcluded(collateral);
        if (amount == 0) revert ZeroAmount();

        // One basket pass serves the mint guard, the distress latch, and the block-start tilt reference.
        // Read BEFORE the transfer, so the reference this call may record is the pre-deposit total.
        (uint256 backingUsd, uint256 enabledUsd,) = _basketSnapshot();
        _touchBasketRef(enabledUsd);
        uint256 ratioBps = _ratioBps(backingUsd);
        _syncDistress(ratioBps);

        // Mint guard: do not issue new SumUSD while backing is below MIN_MINT_RATIO_BPS.
        // Checked on the pre-deposit snapshot; bootstrap (supply == 0) reads as fully backed.
        if (ratioBps < MIN_MINT_RATIO_BPS) revert UnderCollateralized(ratioBps);
        // No minting into a latched system either. While distressed the only exit is the haircut-free
        // pro-rata {redeemMix}; a par-minted deposit taken straight back out through it would be the
        // peg-band mint arbitrage with no haircut to bound it, and (before the par cap) it was the loop
        // that skimmed the surplus during recovery and reset the clock. Recap is {donate}, not minting.
        if (distressed) revert MintDisabledInDistress(ratioBps);

        uint256 balBefore = IERC20(collateral).balanceOf(address(this));
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        // Use the actually-received amount so fee-on-transfer tokens can never over-mint.
        uint256 received = IERC20(collateral).balanceOf(address(this)) - balBefore;

        // Reject mints when the collateral has drifted too far from its $1.00 peg. The peg guard is
        // live-only (fail-closed): an unpriceable feed reverts here and is never covered by the
        // stale-price fallback. Past the guard the price is fresh and in-band, so cache it as last-good.
        uint256 priceWad = c.oracle.getPriceWad(collateral);
        _requirePeggedForDeposit(collateral, priceWad);
        _writeLastGood(collateral, priceWad);

        minted = _normalizeTo18(received, c); // raw 1:1 unit swap, decimal-normalized; oracle does not price the mint
        if (minted < minSumUsdOut) revert SlippageExceeded(minted, minSumUsdOut);

        sumUsd.mint(msg.sender, minted);
        emit Deposited(msg.sender, collateral, received, minted);
    }

    /// @notice Burn `sumUsdAmount` of SumUSD and redeem `collateral` from the pool.
    /// @dev Fungible 1:1 payout minus the weight-tilted haircut: the redeemer receives the effective
    ///      `redeemRateBps` (base tilted by basket imbalance) of the burned amount in collateral
    ///      UNITS at par ($1 = 1 unit), decimal-normalized — the oracle price does not price the
    ///      payout. The haircut stays as backing. See {currentRedeemRateBps} for the rate quote.
    ///      Redemption stays available for a FROZEN (disabled) collateral too — with the tilt applied
    ///      in the PENALTY direction only (scarcity can still discount it, but a freeze never raises its
    ///      rate above base; see {_redeemRateFor}) — so a guardian freeze (even of every flavor) can
    ///      never trap holders. An unpriceable flavor falls back to its flat base rate; only an unlisted
    ///      collateral cannot be redeemed.
    /// @param collateral Accepted collateral token to receive.
    /// @param sumUsdAmount Amount of SumUSD to burn.
    /// @param minCollateralOut Minimum collateral to accept (token decimals).
    /// @return collateralOut Amount of collateral sent to the caller.
    function redeem(address collateral, uint256 sumUsdAmount, uint256 minCollateralOut)
        external
        nonReentrant
        returns (uint256 collateralOut)
    {
        // Below the distress line, single-flavor (cherry-pick) redemption is disabled to stop the
        // first-redeemer run; holders exit pro-rata via {redeemMix}.
        (uint256 totalUsd, uint256 funded, uint256 ratioBps) = _requireNotDistressed();
        collateralOut = _redeemOne(collateral, sumUsdAmount, minCollateralOut, totalUsd, funded, ratioBps);
    }

    /// @notice Redeem several flavors in one transaction: burn `sumUsdAmounts[i]` for `collaterals[i]`,
    ///         each priced and paid exactly as an individual {redeem} would be.
    /// @dev Every leg is priced on ONE pre-batch basket snapshot (`_basketSnapshot` read once), so
    ///      {previewRedeemBatch} matches the payout leg-for-leg and the ordering of the legs does not
    ///      change any rate. Each leg still clamps its rate to <= 100% AND to the backing ratio (see
    ///      {_capAtBacking}) and keeps the haircut, so the batch can never return more than face and never
    ///      lowers backing (it is solvency-equivalent to N separate {redeem} calls). The distress gate is
    ///      checked ONCE up front — a redemption can never reduce the backing ratio, so a batch that starts
    ///      in normal mode stays in it. The whole batch is atomic: any leg
    ///      that reverts (unlisted, dust, slippage, insufficient pool) reverts the entire call. Use single
    ///      {redeem} in distress; below the distress line this reverts `UseRedeemMix` (use {redeemMix}).
    /// @param collaterals Accepted collateral tokens to receive, one per leg.
    /// @param sumUsdAmounts SumUSD to burn per leg (aligned to `collaterals`).
    /// @param minOuts Minimum collateral to accept per leg, token decimals (aligned to `collaterals`).
    /// @return collateralOuts Collateral sent to the caller per leg.
    function redeemBatch(address[] calldata collaterals, uint256[] calldata sumUsdAmounts, uint256[] calldata minOuts)
        external
        nonReentrant
        returns (uint256[] memory collateralOuts)
    {
        uint256 n = collaterals.length;
        if (n == 0 || sumUsdAmounts.length != n || minOuts.length != n) revert BatchLengthMismatch();
        // One snapshot both gates the batch and prices every leg.
        (uint256 totalUsd, uint256 funded, uint256 ratioBps) = _requireNotDistressed();
        collateralOuts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            collateralOuts[i] = _redeemOne(collaterals[i], sumUsdAmounts[i], minOuts[i], totalUsd, funded, ratioBps);
        }
    }

    /// @dev One redemption leg, shared by {redeem} and {redeemBatch}. Prices `sumUsdAmount` of `collateral`
    ///      at its live weight-tilt rate over the given basket snapshot (`totalUsd`, `funded`, capped at
    ///      `ratioBps`), applies the margin, burns, sends the net to `msg.sender`, and settles the margin.
    ///      The caller performs the distress gate once (this does not). Reverts on an unlisted collateral,
    ///      zero amount, dust, slippage, or insufficient pool.
    function _redeemOne(
        address collateral,
        uint256 sumUsdAmount,
        uint256 minCollateralOut,
        uint256 totalUsd,
        uint256 funded,
        uint256 ratioBps
    ) internal returns (uint256 collateralOut) {
        CollateralConfig memory c = configs[collateral];
        if (address(c.oracle) == address(0)) revert CollateralNotEnabled(collateral); // unlisted
        if (sumUsdAmount == 0) revert ZeroAmount();

        uint256 available = IERC20(collateral).balanceOf(address(this));

        // Effective haircut from the weight tilt, priced on the POST-redemption basket (see
        // {_liveRedeemRateBps}). The oracle is read only to weigh the flavor's basket share and to clamp
        // an above-$1 payout — it does NOT price the par conversion. An unpriceable flavor can't be
        // weighed, so it redeems at the flat base rate. A FROZEN (disabled) flavor keeps the tilt in the
        // PENALTY direction only. The views quote the same function, so a quote can never diverge.
        // Warms the last-good price cache for the touched flavor as a side effect.
        uint256 effectiveRedeemRateBps =
            _redeemRateWithRecord(collateral, c, available, sumUsdAmount, totalUsd, funded, ratioBps);

        // Fungible 1:1 payout: burning N SumUSD returns N * effectiveRate units of collateral,
        // decimal-normalized at par ($1 = 1 unit). The oracle price does not enter the conversion.
        uint256 grossOut = _toUnits((sumUsdAmount * effectiveRedeemRateBps) / BPS, c);
        // Redemption margin (bps of the gross payout) on top of the tilt haircut, deducted from the
        // redeemer; the routed portion goes to `marginRecipient` and the rest stays pooled as extra
        // backing. {redeemMix} (the distress exit) is exempt. Settled after the burn by {_settleRedeemMargin}.
        collateralOut = grossOut - (grossOut * redeemMarginBps) / BPS; // net to the redeemer

        // Zero-payout guard. A payout of zero is tolerated ONLY when the flavor is already priced to zero
        // at the MARGIN — a genuinely dust-scarce pool, where there is nothing left to give and the tilt is
        // not "gating" anything. That preserves the liveness carve-out (the holder simply exits via another
        // flavor, since SumUSD is a fungible claim, or via {redeemMix} in distress).
        // Otherwise the zero came from SIZE: either dust input too small for the token's decimals, or a
        // request larger than the convex curve will serve now that the tilt is priced on the
        // post-redemption basket. Both revert rather than burning the holder's SumUSD for nothing; the
        // holder redeems a smaller amount or a different flavor.
        if (collateralOut == 0 && _liveRedeemRateBps(collateral, c, available, 0, totalUsd, funded, ratioBps) != 0) {
            revert ZeroCollateralOut(sumUsdAmount);
        }
        if (collateralOut < minCollateralOut) revert SlippageExceeded(collateralOut, minCollateralOut);
        // The full gross must be available (net to redeemer + routed margin both come out of it; any
        // retained margin just stays pooled), so checking gross conservatively covers both transfers.
        if (grossOut > available) revert InsufficientPool(collateral, grossOut, available);

        sumUsd.burn(msg.sender, sumUsdAmount);
        IERC20(collateral).safeTransfer(msg.sender, collateralOut);
        _settleRedeemMargin(collateral, grossOut); // routes the margin portion (best-effort) and emits
        emit Redeemed(msg.sender, collateral, sumUsdAmount, collateralOut);
    }

    /// @dev Advance the distress latch, revert if it is set, and hand back the enabled-basket stats plus the
    ///      backing ratio so the caller can price its legs without a second pass over the basket.
    ///      Single-flavor {redeem}/{redeemBatch} are disabled while distressed; holders exit pro-rata via
    ///      {redeemMix}. Also records the block-start tilt reference (pre-redemption, since redemptions only
    ///      shrink the basket and the reference is only ever used on its conservative side).
    function _requireNotDistressed() internal returns (uint256 enabledUsd, uint256 funded, uint256 ratioBps) {
        (enabledUsd, funded, ratioBps) = _quoteSnapshot();
        _touchBasketRef(enabledUsd);
        _syncDistress(ratioBps);
        if (distressed) revert UseRedeemMix(ratioBps);
    }

    /// @dev The basket snapshot in the shape every redemption quote needs: the enabled-basket tilt stats and
    ///      the backing ratio (which caps the effective rate, see {_capAtBacking}). One basket pass.
    function _quoteSnapshot() internal view returns (uint256 enabledUsd, uint256 funded, uint256 ratioBps) {
        uint256 backingUsd;
        (backingUsd, enabledUsd, funded) = _basketSnapshot();
        ratioBps = _ratioBps(backingUsd);
    }

    /// @notice Advance the distress latch from the current backing ratio without transacting. Permissionless
    ///         keeper hook: distress ENTRY is instant, but clearing it requires backing to hold at/above
    ///         `DISTRESS_EXIT_RATIO_BPS` for `DISTRESS_RECOVERY_DELAY`, and that countdown only advances when
    ///         someone observes it. Every state-changing entry point calls this internally; this is the
    ///         zero-cost way to start or finish the countdown when the system is otherwise idle.
    function pokeDistress() external {
        _syncDistress(systemCollateralizationRatioBps());
    }

    /// @dev The distress state machine. Entry is immediate and unconditional (a safety action never waits).
    ///      Exit requires backing at/above the strictly-higher exit line, held continuously for the recovery
    ///      delay: any reading below the exit line restarts the clock. The hysteresis matters because a par
    ///      redemption at an effective rate equal to the current ratio is ratio-NEUTRAL, so a bare threshold
    ///      crossed once by a dust {donate} would stay crossed through an unlimited cherry-picking drain.
    function _syncDistress(uint256 ratioBps) internal {
        if (!distressed) {
            if (ratioBps < DISTRESS_ENTER_RATIO_BPS) {
                distressed = true;
                recoveryStartedAt = 0;
                emit DistressEntered(ratioBps);
            }
            return;
        }
        if (ratioBps < DISTRESS_EXIT_RATIO_BPS) {
            if (recoveryStartedAt != 0) {
                recoveryStartedAt = 0;
                emit DistressRecoveryReset(ratioBps);
            }
            return;
        }
        if (recoveryStartedAt == 0) {
            recoveryStartedAt = uint64(block.timestamp);
            emit DistressRecoveryStarted(ratioBps, block.timestamp + DISTRESS_RECOVERY_DELAY);
            return;
        }
        if (block.timestamp - recoveryStartedAt >= DISTRESS_RECOVERY_DELAY) {
            distressed = false;
            recoveryStartedAt = 0;
            emit DistressCleared(ratioBps);
        }
    }

    /// @notice When distress mode would clear if backing holds at/above `DISTRESS_EXIT_RATIO_BPS`; 0 while
    ///         not distressed or while the recovery countdown has not started. For UIs and monitors.
    function distressClearsAt() external view returns (uint256) {
        if (!distressed || recoveryStartedAt == 0) return 0;
        return uint256(recoveryStartedAt) + DISTRESS_RECOVERY_DELAY;
    }

    /// @notice The distress thresholds and recovery delay, for UIs and monitors.
    function distressParams() external pure returns (uint256 enterBps, uint256 exitBps, uint256 recoveryDelay) {
        return (DISTRESS_ENTER_RATIO_BPS, DISTRESS_EXIT_RATIO_BPS, DISTRESS_RECOVERY_DELAY);
    }

    /// @notice Pro-rata "redeem the mix": burn `sumUsdAmount` and receive `sumUsdAmount / totalSupply`
    ///         of EVERY listed collateral (enabled and frozen), capped at $1.00 of backing per SumUSD.
    ///         Only callable when the system is distressed (see {distressed} and the hysteresis in
    ///         {_syncDistress}); it is the fair, order-independent exit that shares the shortfall equally
    ///         across all holders (no first-redeemer advantage).
    /// @dev Payout is ownership math — no haircut, no tilt — with ONE oracle-derived input, used on the
    ///      conservative side only: while the backing ratio is above 100% (the recovery window after a
    ///      recap) every slice is scaled by `1/ratio` ({_mixCapBps}), so a SumUSD never exits with more
    ///      than $1.00 of backing. Below par the slices are the raw pro-rata share and dead feeds (which
    ///      can only LOWER the ratio) can never shrink a payout, so the oracle-free exit is intact where it
    ///      matters. Without the cap, the surplus above par was fully extractable during every recovery
    ///      window and each extraction reset the recovery clock; with it the excess stays pooled, so every
    ///      exit RAISES backing and shortens recovery. `minOut` is per-collateral slippage protection on
    ///      the (capped) slice: pass an empty array to skip, or one of length `collateralList.length`
    ///      aligned to {listedCollaterals}.
    ///      A flavor whose transfer FAILS (e.g. the issuer blacklisted the engine) is SKIPPED, not
    ///      reverted, so one non-transferable collateral can never brick the whole exit; its slice
    ///      stays pooled and the returned `amounts[i]` is 0 for any skipped flavor.
    /// @return amounts Units of each listed collateral actually sent, in `collateralList` order.
    function redeemMix(uint256 sumUsdAmount, uint256[] calldata minOut)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        (uint256 backingUsd,,) = _basketSnapshot();
        uint256 ratioBps = _ratioBps(backingUsd);
        _syncDistress(ratioBps);
        if (!distressed) revert NotDistressed(ratioBps);
        if (sumUsdAmount == 0) revert ZeroAmount();

        uint256 len = collateralList.length;
        if (minOut.length != 0 && minOut.length != len) revert MinOutLengthMismatch();

        uint256 supply = sumUsd.totalSupply(); // > 0 (caller holds sumUsdAmount)
        amounts = new uint256[](len);
        uint256 nonZero;
        for (uint256 i; i < len; ++i) {
            // A flavor whose balance can't even be READ (bricked token) is treated as an empty slice, for the
            // same reason a failing transfer is skipped below: one broken collateral must never block the exit.
            (uint256 poolBalance,) = _tryBalanceOf(collateralList[i]);
            uint256 out = _capMixSlice((poolBalance * sumUsdAmount) / supply, supply, backingUsd);
            amounts[i] = out;
            if (out != 0) ++nonZero;
            if (minOut.length != 0 && out < minOut[i]) revert SlippageExceeded(out, minOut[i]);
        }
        // Dust guard, mirroring single {redeem}: never burn SumUSD for zero of everything. Partial zeros
        // stay allowed, since an empty or non-transferable flavor must still be skippable.
        if (nonZero == 0) revert ZeroCollateralOut(sumUsdAmount);

        sumUsd.burn(msg.sender, sumUsdAmount); // amounts computed from pre-burn supply above
        for (uint256 i; i < len; ++i) {
            // Skip (don't revert) a failing transfer so one non-transferable flavor can't block the
            // whole pro-rata exit; the skipped slice stays pooled and amounts[i] is reported as 0.
            if (amounts[i] != 0 && !_tryTransfer(collateralList[i], msg.sender, amounts[i])) {
                amounts[i] = 0;
            }
        }
        emit RedeemedMix(msg.sender, sumUsdAmount, amounts);
    }

    /// @dev Non-reverting ERC-20 transfer: returns false instead of reverting if the token reverts
    ///      or returns false. Mirrors SafeERC20's success accounting (treats a no-return token as OK)
    ///      but never bubbles a failure up — used by {redeemMix} to skip an untransferable flavor.
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success) return false;
        if (ret.length == 0) return true; // no-return tokens (e.g. USDT) — the call itself succeeded
        return ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @dev Non-reverting `balanceOf(this)`: `(0, false)` if the token reverts, has no code, or returns
    ///      malformed data. The listing probe checks `balanceOf` once, but an upgradeable token can break
    ///      AFTER listing; without this, one bricked flavor would revert every basket-wide loop (all
    ///      deposits, redemptions and views) and the pro-rata distress exit itself. Used wherever the engine
    ///      walks the whole basket; the single-flavor paths still read directly (only that flavor fails).
    function _tryBalanceOf(address token) internal view returns (uint256 balance, bool ok) {
        // The raw staticcall IS the point (a typed call reverts on a bricked token), and the loop it runs in
        // is bounded by MAX_COLLATERALS; same pattern as `_tryTransfer` / `_tryPriceWad`.
        // slither-disable-next-line calls-loop,low-level-calls
        (bool success, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!success || ret.length < 32) return (0, false);
        return (abi.decode(ret, (uint256)), true);
    }

    /// @notice Donate `amount` of a listed `collateral` to the pool as permanent backing, minting NO
    ///         SumUSD in return. Raises `totalCollateralValueUsd()` (and the backing ratio) without
    ///         increasing supply — a first-class recapitalization path.
    /// @dev Anyone may call this. It is the intended way to lift backing back above the mint floor /
    ///      distress line: while distressed the `redeemMix` exit is ratio-flat (it burns
    ///      supply and removes value in equal proportion), so redemptions do not heal the ratio —
    ///      recovery comes from oracle recovery or a donation here. Works for a FROZEN (disabled) but
    ///      listed collateral too (it still counts toward backing). Reads the actually-received balance,
    ///      so fee-on-transfer tokens can't over-credit. Purely additive: it can only raise backing.
    /// @param collateral Listed collateral token to donate (must have a config).
    /// @param amount     Amount to donate (in the token's own decimals).
    /// @return received  The amount actually received by the pool.
    function donate(address collateral, uint256 amount) external nonReentrant returns (uint256 received) {
        CollateralConfig memory c = configs[collateral];
        if (address(c.oracle) == address(0)) revert CollateralNotEnabled(collateral); // unlisted
        if (amount == 0) revert ZeroAmount();

        uint256 balBefore = IERC20(collateral).balanceOf(address(this));
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(collateral).balanceOf(address(this)) - balBefore;
        emit Donated(msg.sender, collateral, received);
        // Let a recapitalization advance the distress countdown immediately rather than waiting for the
        // next unrelated call. It can only ever move the latch toward clearing.
        _syncDistress(systemCollateralizationRatioBps());
    }

    /// @notice Refresh the cached last-good price for every listed collateral whose feed currently
    ///         reads fresh. Permissionless keeper hook: keeping the cache warm extends how long the
    ///         stale-price fallback ({stalePriceGraceSeconds}) can cover a feed outage. A collateral
    ///         whose feed is currently down is simply skipped (no stale write).
    function refreshPrices() external {
        uint256 len = collateralList.length;
        for (uint256 i; i < len; ++i) {
            address token = collateralList[i];
            _recordPrice(token, configs[token].oracle);
        }
    }

    /// @notice Refresh the cached last-good price for a single listed collateral (cheaper targeted
    ///         keeper hook). No-op if the feed is currently down or the token is unlisted.
    function refreshPrice(address collateral) external {
        _recordPrice(collateral, configs[collateral].oracle);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Quote {redeemMix}: the per-collateral units a pro-rata redemption of `sumUsdAmount`
    ///         would return right now (in `collateralList` order), including the above-par cap. Quoted
    ///         regardless of regime (it is only callable while distressed).
    function previewRedeemMix(uint256 sumUsdAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 len = collateralList.length;
        tokens = new address[](len);
        amounts = new uint256[](len);
        uint256 supply = sumUsd.totalSupply();
        (uint256 backingUsd,,) = _basketSnapshot();
        for (uint256 i; i < len; ++i) {
            tokens[i] = collateralList[i];
            if (supply != 0) {
                (uint256 poolBalance,) = _tryBalanceOf(collateralList[i]);
                amounts[i] = _capMixSlice((poolBalance * sumUsdAmount) / supply, supply, backingUsd);
            }
        }
    }

    /// @dev Cap one {redeemMix} slice at par. While `backingUsd <= supply` (at or under 100%) the raw
    ///      pro-rata `slice` is returned unchanged; above it the slice is scaled by `supply / backingUsd`, so
    ///      summed over the basket the USD value leaving per SumUSD burned is exactly $1.00 (floored). Uses
    ///      the raw WAD totals rather than the bps ratio so the cap never rounds in the redeemer's favor.
    ///      Only ever shrinks a payout, and only when the pool holds MORE than the claim, so it cannot touch
    ///      the shortfall-sharing guarantee below par.
    function _capMixSlice(uint256 slice, uint256 supply, uint256 backingUsd) internal pure returns (uint256) {
        return backingUsd > supply ? (slice * supply) / backingUsd : slice;
    }

    /// @notice The full list of currently-listed collaterals (the order used by {redeemMix} arrays).
    function listedCollaterals() external view returns (address[] memory) {
        return collateralList;
    }

    /// @notice USD value (18-decimal WAD) of the pool's balance of one collateral, using the valuation
    ///         price (live feed, else the stale-price fallback within its grace window, else 0). Returns
    ///         0 if the collateral is unlisted or has no usable price — so a broken feed contributes
    ///         nothing (or its haircut last-good) rather than bricking every basket-wide loop.
    function collateralValueUsd(address collateral) public view returns (uint256) {
        CollateralConfig memory c = configs[collateral];
        if (c.backingExcluded) return 0; // de-backed / siloed: not counted toward backing or the tilt
        return _valueUsd(collateral, c);
    }

    /// @notice The pool's USD value of `collateral` IGNORING any backing exclusion — the real value
    ///         sitting in the pool. Equals {collateralValueUsd} unless the flavor is de-backed, in which
    ///         case this still reports the stranded value (for UIs) while the backing math counts 0.
    function rawCollateralValueUsd(address collateral) external view returns (uint256) {
        return _valueUsd(collateral, configs[collateral]);
    }

    /// @notice The raw current oracle read for `collateral`: the live price (WAD) and whether the feed
    ///         answered. `ok == false` means the feed is currently unavailable (reverting or 0), which is
    ///         also what an UNLISTED collateral reports. Useful for surfacing feed health in a UI.
    function livePriceWad(address collateral) external view returns (uint256 priceWad, bool ok) {
        IPriceOracle oracle = configs[collateral].oracle;
        if (address(oracle) == address(0)) return (0, false); // unlisted: report unpriceable, never revert
        return _tryPriceWad(collateral, oracle);
    }

    /// @notice The price actually used to VALUE `collateral` for backing/tilt right now: the live feed
    ///         if available, else the haircut last-good price within the grace window, else 0. An unlisted
    ///         collateral reads 0.
    function valuationPriceWad(address collateral) external view returns (uint256) {
        IPriceOracle oracle = configs[collateral].oracle;
        if (address(oracle) == address(0)) return 0;
        return _valuationPriceWad(collateral, oracle);
    }

    /// @notice Total USD value (WAD) of the entire collateral basket.
    function totalCollateralValueUsd() public view returns (uint256 total) {
        (total,,) = _basketSnapshot();
    }

    /// @notice System collateralization ratio in bps (collateral value / SumUSD supply).
    /// @return ratioBps `10_000` == exactly 100%. Returns `type(uint256).max` when supply is 0.
    function systemCollateralizationRatioBps() public view returns (uint256 ratioBps) {
        (uint256 backingUsd,,) = _basketSnapshot();
        return _ratioBps(backingUsd);
    }

    /// @dev Backing ratio in bps from an already-computed basket total. `type(uint256).max` at zero supply
    ///      (bootstrap reads as fully backed).
    function _ratioBps(uint256 backingUsd) internal view returns (uint256) {
        uint256 supply = sumUsd.totalSupply();
        if (supply == 0) return type(uint256).max;
        return (backingUsd * BPS) / supply;
    }

    /// @notice Number of collateral tokens ever listed.
    function collateralCount() external view returns (uint256) {
        return collateralList.length;
    }

    /// @notice Quote how much SumUSD a deposit of `amount` `collateral` would mint right now
    ///         (raw 1:1, decimal-normalized; assumes the price is within the deposit peg band).
    function previewDeposit(address collateral, uint256 amount) external view returns (uint256) {
        CollateralConfig memory c = configs[collateral];
        return _normalizeTo18(amount, c);
    }

    /// @notice Quote the NET collateral `redeeming` `sumUsdAmount` of `collateral` would return right
    ///         now — the weight-tilted haircut AND the redemption margin both applied — so the quote
    ///         matches the actual {redeem} payout.
    function previewRedeem(address collateral, uint256 sumUsdAmount) external view returns (uint256 net) {
        (uint256 totalUsd, uint256 funded, uint256 ratioBps) = _quoteSnapshot();
        uint256 poolBalance = IERC20(collateral).balanceOf(address(this));
        (net,) = _quoteRedeem(collateral, sumUsdAmount, poolBalance, totalUsd, funded, ratioBps);
    }

    /// @notice Quote {redeemBatch}: the NET collateral each leg returns right now, priced on ONE basket
    ///         snapshot exactly as {redeemBatch} prices it — so this matches the actual payout leg-for-leg
    ///         (barring a leg that would revert on chain, e.g. dust or an empty pool). A flavor named more
    ///         than once is quoted the way the batch pays it: each later leg sees the pool balance the
    ///         earlier legs of that flavor draw down (net paid plus the routed margin).
    /// @param collaterals Accepted collateral tokens, one per leg.
    /// @param sumUsdAmounts SumUSD to burn per leg (aligned to `collaterals`).
    /// @return nets Net collateral each leg would return (token decimals).
    function previewRedeemBatch(address[] calldata collaterals, uint256[] calldata sumUsdAmounts)
        external
        view
        returns (uint256[] memory nets)
    {
        uint256 n = collaterals.length;
        if (sumUsdAmounts.length != n) revert BatchLengthMismatch();
        (uint256 totalUsd, uint256 funded, uint256 ratioBps) = _quoteSnapshot();
        nets = new uint256[](n);
        uint256[] memory drawn = new uint256[](n); // units each leg removes from its flavor's pool balance
        for (uint256 i; i < n; ++i) {
            uint256 poolBalance = IERC20(collaterals[i]).balanceOf(address(this));
            for (uint256 j; j < i; ++j) {
                if (collaterals[j] != collaterals[i]) continue;
                poolBalance = drawn[j] < poolBalance ? poolBalance - drawn[j] : 0;
            }
            (nets[i], drawn[i]) =
                _quoteRedeem(collaterals[i], sumUsdAmounts[i], poolBalance, totalUsd, funded, ratioBps);
        }
    }

    /// @dev Net collateral a redemption of `sumUsdAmount` in `collateral` returns over the given basket
    ///      snapshot and pre-redemption `poolBalance` — the weight-tilt haircut AND the margin applied —
    ///      plus `drawDown`, the units that would actually leave the pool (net to the redeemer + the routed
    ///      margin; the retained margin stays). Shared by the redeem previews so a quote can never diverge
    ///      from the {redeem}/{redeemBatch} payout.
    function _quoteRedeem(
        address collateral,
        uint256 sumUsdAmount,
        uint256 poolBalance,
        uint256 totalUsd,
        uint256 funded,
        uint256 ratioBps
    ) internal view returns (uint256 net, uint256 drawDown) {
        CollateralConfig memory c = configs[collateral];
        uint256 effectiveRedeemRateBps =
            _liveRedeemRateBps(collateral, c, poolBalance, sumUsdAmount, totalUsd, funded, ratioBps);
        uint256 grossOut = _toUnits((sumUsdAmount * effectiveRedeemRateBps) / BPS, c);
        (uint256 marginTotal, uint256 toRecipient) = _redeemMargin(grossOut);
        net = grossOut - marginTotal;
        drawDown = net + toRecipient;
    }

    /// @notice Break down what redeeming `sumUsdAmount` of `collateral` pays right now: the redeemer's
    ///         net, the margin routed to {marginRecipient}, and the margin retained in the pool.
    function previewRedeemMargin(address collateral, uint256 sumUsdAmount)
        external
        view
        returns (uint256 toRedeemer, uint256 toRecipient, uint256 retained)
    {
        CollateralConfig memory c = configs[collateral];
        (uint256 totalUsd, uint256 funded, uint256 ratioBps) = _quoteSnapshot();
        uint256 poolBalance = IERC20(collateral).balanceOf(address(this));
        uint256 effectiveRedeemRateBps =
            _liveRedeemRateBps(collateral, c, poolBalance, sumUsdAmount, totalUsd, funded, ratioBps);
        uint256 grossOut = _toUnits((sumUsdAmount * effectiveRedeemRateBps) / BPS, c);
        uint256 marginTotal;
        (marginTotal, toRecipient) = _redeemMargin(grossOut);
        toRedeemer = grossOut - marginTotal;
        retained = marginTotal - toRecipient;
    }

    /// @notice The MARGINAL effective redemption rate (bps) for `collateral` right now: its base
    ///         `redeemRateBps` tilted by the basket's current imbalance, quoted for a vanishingly small
    ///         redemption. `10_000` == 100% (no haircut).
    /// @dev Two things are deliberately NOT in this number, so use {previewRedeem}/{previewRedeemMargin}
    ///      for an exact payout: the flat `redeemMarginBps`, and the SIZE effect — since the tilt is priced
    ///      on the post-redemption basket ({_effectiveRedeemRateBps}), a large redemption of a scarce
    ///      flavor prices strictly worse than this marginal quote, and a large redemption of an abundant
    ///      one earns strictly less bonus. This view is the curve's value at the current point, not the
    ///      average a given trade pays.
    function currentRedeemRateBps(address collateral) public view returns (uint256) {
        return marginalRedeemRateBps(collateral);
    }

    /// @notice Alias of {currentRedeemRateBps}, named for what it is: the rate at zero size.
    function marginalRedeemRateBps(address collateral) public view returns (uint256) {
        CollateralConfig memory c = configs[collateral];
        if (address(c.oracle) == address(0)) return 0; // unlisted: quote 0 rather than reverting
        (uint256 totalUsd, uint256 funded, uint256 ratioBps) = _quoteSnapshot();
        uint256 poolBalance = IERC20(collateral).balanceOf(address(this));
        return _liveRedeemRateBps(collateral, c, poolBalance, 0, totalUsd, funded, ratioBps);
    }

    /// @notice The effective redemption rate (bps) `sumUsdAmount` of `collateral` would actually price at
    ///         right now, including the post-redemption size effect. This is the rate {redeem} applies.
    function redeemRateBpsFor(address collateral, uint256 sumUsdAmount) external view returns (uint256) {
        CollateralConfig memory c = configs[collateral];
        if (address(c.oracle) == address(0)) return 0;
        (uint256 totalUsd, uint256 funded, uint256 ratioBps) = _quoteSnapshot();
        uint256 poolBalance = IERC20(collateral).balanceOf(address(this));
        return _liveRedeemRateBps(collateral, c, poolBalance, sumUsdAmount, totalUsd, funded, ratioBps);
    }

    /// @notice The enabled collateral the pool most needs — the one with the smallest USD balance
    ///         (an under-represented or empty flavor). Frontends use this to default the deposit
    ///         selector toward balance. Returns `address(0)` if no collateral is enabled.
    /// @dev Skips a flavor whose feed is currently unpriceable: a dead feed reads as 0 value (so it
    ///      would otherwise always win as "most needed"), but its deposit reverts on the peg-band guard
    ///      anyway, so steering fresh deposits there would be a dead end. A genuinely empty *priceable*
    ///      flavor still reads 0 and is correctly surfaced.
    function poolNeeds() external view returns (address needed) {
        uint256 len = collateralList.length;
        uint256 lowest = type(uint256).max;
        for (uint256 i; i < len; ++i) {
            address token = collateralList[i];
            CollateralConfig memory c = configs[token];
            if (!c.enabled) continue;
            (uint256 priceWad, bool priced) = _tryPriceWad(token, c.oracle);
            if (!priced) continue; // unpriceable => not depositable => never "needed"
            (uint256 poolBalance, bool readable) = _tryBalanceOf(token);
            if (!readable) continue; // a bricked token must never be steered into
            uint256 value = _toUsdAt(poolBalance, c, priceWad);
            if (value < lowest) {
                lowest = value;
                needed = token;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice List a new collateral or update an existing one in a single call.
    /// @dev Decimals are read from the token on first listing and cached. `redeemRateBps` is the base
    ///      redemption rate and is bounded to the immutable sanity rails [MIN_REDEEM_RATE_BPS,
    ///      MAX_REDEEM_RATE_BPS] = [95%, 100%] — governance can tune it, but only within that tight
    ///      band (≤100% preserves over-collateralization; ≥95% caps the base haircut).
    function setCollateral(address collateral, bool enabled, uint16 redeemRateBps, IPriceOracle oracle)
        external
        onlyOwner
    {
        if (redeemRateBps < MIN_REDEEM_RATE_BPS || redeemRateBps > MAX_REDEEM_RATE_BPS) {
            revert InvalidRedeemRate(redeemRateBps);
        }
        if (address(oracle) == address(0)) revert InvalidOracle();

        CollateralConfig storage c = configs[collateral];
        bool isNew = address(c.oracle) == address(0) && c.decimals == 0;
        if (isNew) {
            if (collateralList.length >= MAX_COLLATERALS) revert CollateralCapReached(MAX_COLLATERALS);
            c.decimals = _probeCollateral(collateral); // conformance + decimals sanity, fail-fast on listing
            collateralList.push(collateral);
            emit CollateralListed(collateral, redeemRateBps, address(oracle));
        }
        c.enabled = enabled;
        c.redeemRateBps = redeemRateBps;
        c.oracle = oracle;
        emit CollateralUpdated(collateral, enabled, redeemRateBps, address(oracle));
    }

    /// @notice Enable or disable an already-listed collateral without touching other params.
    /// @dev Owner (timelock) only. Re-enabling a frozen collateral therefore takes the slow path.
    function setCollateralEnabled(address collateral, bool enabled) external onlyOwner {
        CollateralConfig storage c = configs[collateral];
        if (address(c.oracle) == address(0)) revert CollateralNotEnabled(collateral);
        c.enabled = enabled;
        emit CollateralUpdated(collateral, enabled, c.redeemRateBps, address(c.oracle));
    }

    /// @notice Remove a fully-retired collateral from the list to free a slot (against the
    ///         {MAX_COLLATERALS} cap). The collateral must be disabled and hold a zero balance, so
    ///         removal can never strand funds or change the backing ratio. After removal the token is
    ///         fully de-listed (config cleared) and could be listed again fresh.
    /// @dev To retire a collateral that still holds a balance: re-enable it, let holders redeem it to
    ///      zero, disable it, then remove. Owner (timelock) only.
    function removeCollateral(address collateral) external onlyOwner {
        CollateralConfig storage c = configs[collateral];
        if (address(c.oracle) == address(0)) revert CollateralNotEnabled(collateral); // not listed
        if (c.enabled) revert CollateralStillEnabled(collateral);
        if (IERC20(collateral).balanceOf(address(this)) != 0) revert CollateralNotEmpty(collateral);

        uint256 len = collateralList.length;
        for (uint256 i; i < len; ++i) {
            if (collateralList[i] == collateral) {
                collateralList[i] = collateralList[len - 1];
                collateralList.pop();
                break;
            }
        }
        delete configs[collateral];
        emit CollateralRemoved(collateral);
    }

    /// @notice Exclude (or re-include) a listed collateral from the backing/solvency and tilt math —
    ///         "siloing" a permanently-inaccessible flavor (e.g. one whose issuer has blacklisted the
    ///         engine). While excluded, its value contributes 0 to `totalCollateralValueUsd` and drops
    ///         out of the weight tilt, so `systemCollateralizationRatioBps()` reflects only redeemable
    ///         value: distress then triggers HONESTLY if the loss pushes backing below the floor, and
    ///         `redeemMix` shares the shortfall pro-rata instead of leaving it to the last holders.
    /// @dev The flavor stays listed and its balance stays pooled — `redeemMix` still offers its (stuck)
    ///      slice, so if it ever becomes transferable again the value flows back out; re-include it then.
    ///      `rawCollateralValueUsd` still reports the stranded value for UIs. Owner-only (96h timelock),
    ///      because this can trip distress and holders must get their exit window. Orthogonal to a
    ///      guardian {freezeCollateral} (which also stops deposits + is instant): use both to fully silo.
    function setCollateralBackingExcluded(address collateral, bool excluded) external onlyOwner {
        CollateralConfig storage c = configs[collateral];
        if (address(c.oracle) == address(0)) revert CollateralNotEnabled(collateral); // must be listed
        c.backingExcluded = excluded;
        emit CollateralBackingExcludedSet(collateral, excluded);
    }

    /// @notice Set (or clear, with `address(0)`) the guardian that can instantly freeze a collateral.
    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianUpdated(newGuardian);
    }

    /// @notice Instantly freeze (disable) a single collateral — the guardian's only power. A frozen
    ///         collateral can no longer be deposited and is dropped from the active weight set, but it
    ///         **remains redeemable** — with the tilt kept in the penalty direction only (capped at its
    ///         base rate) — and still counts toward backing, so a freeze stops new exposure without ever
    ///         trapping holders, even if every flavor is frozen. The guardian can only freeze, never
    ///         un-freeze (re-enabling is `setCollateralEnabled`, owner/timelock only).
    function freezeCollateral(address collateral) external {
        if (msg.sender != guardian) revert NotGuardian();
        CollateralConfig storage c = configs[collateral];
        if (address(c.oracle) == address(0)) revert CollateralNotEnabled(collateral);
        c.enabled = false;
        emit CollateralFrozen(collateral, msg.sender);
        emit CollateralUpdated(collateral, false, c.redeemRateBps, address(c.oracle));
    }

    /// @notice Set the sensitivity of the weight-tilted haircut. 0 disables the tilt (flat haircut);
    ///         bounded above by the immutable {MAX_TILT_SLOPE_BPS} sanity rail.
    function setTiltSlopeBps(uint16 newTiltSlopeBps) external onlyOwner {
        if (newTiltSlopeBps > MAX_TILT_SLOPE_BPS) revert InvalidTiltSlope(newTiltSlopeBps);
        tiltSlopeBps = newTiltSlopeBps;
        emit TiltSlopeUpdated(newTiltSlopeBps);
    }

    /// @notice Set the single-flavor redemption margin (bps of the gross payout, on top of the tilt
    ///         haircut) and the portion of it routed to {marginRecipient}; the remainder stays in the pool
    ///         as extra backing. Owner-only, so in production every change waits the 96h timelock.
    /// @dev {redeemMix} (the distress exit) is never charged. Reference config: `newRedeemMarginBps = 2`
    ///      (2 bps total), `newMarginToRecipientBps = 1` (1 bp to the recipient, 1 bp retained as backing).
    /// @param newRedeemMarginBps      Total margin, railed to [0, {MAX_REDEEM_MARGIN_BPS}].
    /// @param newMarginToRecipientBps Portion routed to {marginRecipient}; must be <= `newRedeemMarginBps`.
    function setRedeemMargin(uint16 newRedeemMarginBps, uint16 newMarginToRecipientBps) external onlyOwner {
        if (newRedeemMarginBps > MAX_REDEEM_MARGIN_BPS || newMarginToRecipientBps > newRedeemMarginBps) {
            revert InvalidRedeemMargin(newRedeemMarginBps, newMarginToRecipientBps);
        }
        redeemMarginBps = newRedeemMarginBps;
        marginToRecipientBps = newMarginToRecipientBps;
        emit RedeemMarginUpdated(newRedeemMarginBps, newMarginToRecipientBps);
    }

    /// @notice Set (or clear, with `address(0)`) the recipient of the routed redemption-margin portion.
    ///         Owner-only, so changing it waits the 96h timelock. While unset, the routed portion stays
    ///         in the pool (no value leaves), so a margin can be configured before a treasury is live.
    function setMarginRecipient(address newRecipient) external onlyOwner {
        marginRecipient = newRecipient;
        emit MarginRecipientUpdated(newRecipient);
    }

    /// @notice Configure the stale-price fallback: `graceSeconds` is how long a collateral whose live
    ///         feed has failed keeps being valued (for backing/tilt only) at its last-good price minus
    ///         `haircutBps`; after that it values at 0. `graceSeconds = 0` disables the fallback (the
    ///         fully-conservative default). Owner-only (96h timelock); railed to `MAX_STALE_PRICE_GRACE`
    ///         and a haircut <= 100%. Reference config: 6 hours / 100 bps.
    function setStalePriceParams(uint32 graceSeconds, uint16 haircutBps) external onlyOwner {
        if (graceSeconds > MAX_STALE_PRICE_GRACE || haircutBps > BPS) {
            revert InvalidStalePriceParams(graceSeconds, haircutBps);
        }
        stalePriceGraceSeconds = graceSeconds;
        stalePriceHaircutBps = haircutBps;
        emit StalePriceParamsUpdated(graceSeconds, haircutBps);
    }

    // ---------------------------------------------------------------------
    // Internal math
    // ---------------------------------------------------------------------

    /// @dev Sanity-probe a token being listed for the FIRST time and return its cached decimals. The
    ///      token must be a conforming ERC-20 (its `decimals()` and `balanceOf()` must be callable) with
    ///      decimals in [0, {MAX_COLLATERAL_DECIMALS}]. Reverts otherwise, so a non-conforming or
    ///      oversized-decimals token fails at listing (governance time) rather than on first deposit.
    ///      This CANNOT detect rebasing, fee-on-transfer, or transfer-hook tokens — those manifest over
    ///      time or need a live transfer, so they remain a governance whitelist-policy matter (see the
    ///      collateral eligibility policy).
    function _probeCollateral(address collateral) internal view returns (uint8 dec) {
        if (collateral.code.length == 0) revert CollateralProbeFailed(collateral); // must be a contract
        try IERC20Metadata(collateral).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            revert CollateralProbeFailed(collateral);
        }
        if (dec > MAX_COLLATERAL_DECIMALS) revert InvalidCollateralDecimals(dec);
        // The engine reads balanceOf everywhere; require it callable now as a basic conformance check.
        try IERC20(collateral).balanceOf(address(this)) returns (uint256) {}
        catch {
            revert CollateralProbeFailed(collateral);
        }
    }

    /// @dev Revert if a collateral's price has drifted more than {MAX_DEPOSIT_PRICE_DEVIATION_BPS}
    ///      from $1.00 (WAD). Applied to deposits only.
    function _requirePeggedForDeposit(address collateral, uint256 priceWad) internal pure {
        uint256 deviation = priceWad > WAD ? priceWad - WAD : WAD - priceWad;
        if (deviation * BPS > WAD * MAX_DEPOSIT_PRICE_DEVIATION_BPS) {
            revert PriceOutOfBand(collateral, priceWad);
        }
    }

    /// @dev Normalize a token amount (in its own decimals) to an 18-decimal amount, treating one
    ///      unit of collateral as exactly $1 (raw 1:1 swap, oracle-independent). Used on deposit.
    function _normalizeTo18(uint256 amount, CollateralConfig memory c) internal pure returns (uint256) {
        return (amount * WAD) / (10 ** c.decimals);
    }

    /// @dev Inverse of {_normalizeTo18}: convert an 18-decimal par amount back to token units at
    ///      $1 = 1 unit (oracle-independent). Used for the fungible 1:1 redemption payout.
    function _toUnits(uint256 amount18, CollateralConfig memory c) internal pure returns (uint256) {
        return (amount18 * (10 ** c.decimals)) / WAD;
    }

    /// @dev Split a gross redemption payout into the total margin and the portion routed to `marginRecipient`
    ///      (0 while the recipient is unset — the routed portion then stays pooled). The remaining
    ///      `marginTotal - toRecipient` always stays in the pool as extra backing. Both round down.
    function _redeemMargin(uint256 grossOut) internal view returns (uint256 marginTotal, uint256 toRecipient) {
        marginTotal = (grossOut * redeemMarginBps) / BPS;
        if (marginRecipient != address(0)) toRecipient = (grossOut * marginToRecipientBps) / BPS;
    }

    /// @dev Route the redemption margin for a gross payout of `grossOut` in `collateral`, after the
    ///      redeemer's net has already been sent. The recipient portion is transferred best-effort (a
    ///      recipient that can't receive is skipped, its slice staying pooled) so the margin can never
    ///      block a redemption; the retained portion is left in the pool. Emits {RedeemMarginPaid} when a
    ///      margin applies. Kept as a separate call so {redeem} stays under the stack-depth limit.
    function _settleRedeemMargin(address collateral, uint256 grossOut) internal {
        (uint256 marginTotal, uint256 toRecipient) = _redeemMargin(grossOut);
        if (marginTotal == 0) return;
        if (toRecipient != 0 && !_tryTransfer(collateral, marginRecipient, toRecipient)) toRecipient = 0;
        emit RedeemMarginPaid(collateral, marginRecipient, toRecipient, marginTotal - toRecipient);
    }

    /// @dev Resilient oracle read. Returns (price, true) on a successful, non-zero quote; (0, false)
    ///      if the oracle reverts or returns 0. Lets basket-wide loops treat a broken feed as 0
    ///      rather than reverting the whole call.
    function _tryPriceWad(address collateral, IPriceOracle oracle) internal view returns (uint256 priceWad, bool ok) {
        try oracle.getPriceWad(collateral) returns (uint256 p) {
            if (p != 0) (priceWad, ok) = (p, true);
        } catch {}
    }

    /// @dev Price used to VALUE a collateral for backing/tilt: the live feed if it answers; otherwise,
    ///      if the stale-price fallback is enabled and the last-good price is within the grace window,
    ///      that price minus `stalePriceHaircutBps`; otherwise 0. Never used for the deposit peg guard
    ///      (live-only) or the redemption payout (par). `BPS - stalePriceHaircutBps` cannot underflow —
    ///      the setter rails `stalePriceHaircutBps <= BPS`.
    function _valuationPriceWad(address token, IPriceOracle oracle) internal view returns (uint256) {
        (uint256 live, bool ok) = _tryPriceWad(token, oracle);
        if (ok) return live;
        uint256 grace = stalePriceGraceSeconds;
        if (grace == 0) return 0;
        uint256 at = lastGoodPriceAt[token];
        if (at == 0 || block.timestamp - at > grace) return 0;
        return (lastGoodPriceWad[token] * (BPS - stalePriceHaircutBps)) / BPS;
    }

    /// @dev Record a token's live price as its last-good, only if the feed reads fresh and non-zero.
    ///      No-op for an unlisted token (no oracle to read).
    function _recordPrice(address token, IPriceOracle oracle) internal {
        if (address(oracle) == address(0)) return;
        (uint256 priceWad, bool ok) = _tryPriceWad(token, oracle);
        if (ok) _writeLastGood(token, priceWad);
    }

    /// @dev Write the last-good price cache for `token`. `priceWad` must already be a known-fresh read.
    function _writeLastGood(address token, uint256 priceWad) internal {
        lastGoodPriceWad[token] = priceWad;
        lastGoodPriceAt[token] = block.timestamp;
        emit PriceRecorded(token, priceWad, block.timestamp);
    }

    /// @dev Convert a token amount (in its own decimals) to USD value (18-decimal WAD) at `priceWad`.
    function _toUsdAt(uint256 amount, CollateralConfig memory c, uint256 priceWad) internal pure returns (uint256) {
        return (amount * priceWad) / (10 ** c.decimals);
    }

    /// @dev Raw pool USD value of `collateral` (ignoring the backing-exclusion flag): 0 if unlisted or
    ///      unpriceable, else pooled balance valued at the valuation price. Shared by the two value views.
    function _valueUsd(address collateral, CollateralConfig memory c) internal view returns (uint256) {
        if (address(c.oracle) == address(0)) return 0;
        uint256 priceWad = _valuationPriceWad(collateral, c.oracle);
        if (priceWad == 0) return 0;
        (uint256 poolBalance, bool readable) = _tryBalanceOf(collateral);
        if (!readable) return 0; // a balance that can't be read is worth nothing to the pool (conservative)
        return _toUsdAt(poolBalance, c, priceWad);
    }

    /// @dev ONE pass over the basket producing every aggregate the engine needs:
    ///        - `backingUsd`: total value of ALL listed collateral (the solvency numerator). Includes
    ///          frozen flavors; excludes de-backed ones (via {collateralValueUsd}).
    ///        - `enabledUsd` / `funded`: the weight-tilt basket, counting only ENABLED collaterals holding
    ///          at least `MIN_FUNDED_VALUE_WAD`. A frozen collateral is excluded from the share/target math
    ///          (it is not depositable, so it should not skew the redeemable flavors' rates) but still
    ///          counts toward backing. The value floor keeps `funded` — which sets BOTH parity band edges —
    ///          from being shifted by dust.
    ///      Replaces the previous pair of loops (`totalCollateralValueUsd` + `_basketStats`), which priced
    ///      every flavor through the oracle stack twice on the redemption path.
    function _basketSnapshot() internal view returns (uint256 backingUsd, uint256 enabledUsd, uint256 funded) {
        uint256 len = collateralList.length;
        for (uint256 i; i < len; ++i) {
            address token = collateralList[i];
            uint256 value = collateralValueUsd(token);
            if (value == 0) continue;
            backingUsd += value;
            if (!configs[token].enabled) continue;
            if (value < MIN_FUNDED_VALUE_WAD) continue;
            enabledUsd += value;
            funded++;
        }
    }

    /// @dev Record the block-start enabled-basket total, if this is the first state-changing call of the
    ///      block. `spotEnabledUsd` must be read BEFORE the caller's own effect on the basket, so the
    ///      recorded value is a clean pre-transaction reading.
    function _touchBasketRef(uint256 spotEnabledUsd) internal {
        if (basketRefBlock != uint64(block.number)) {
            basketRefBlock = uint64(block.number);
            // casting to 'uint192' is safe because the ternary saturates at type(uint192).max first
            // forge-lint: disable-next-line(unsafe-typecast)
            basketRefTotalUsd = spotEnabledUsd > type(uint192).max ? type(uint192).max : uint192(spotEnabledUsd);
        }
    }

    /// @dev The enabled-basket total to price a tilt against. The manipulation only ever runs one way:
    ///      someone inflates the basket inside a block so that every OTHER flavor's measured share collapses
    ///      below the convex knee and their redemption rates go to zero. So each side of the tilt takes the
    ///      reading that cannot be gamed:
    ///        - PENALTY side: the SMALLER of (spot, block-start), so an intra-block inflation cannot deepen
    ///          a third party's penalty.
    ///        - BONUS side: the LARGER of (spot, block-start), so an intra-block inflation cannot
    ///          manufacture an overweight bonus either.
    ///      `floorUsd` is the flavor's own pooled value: the total is never taken below it, since a flavor
    ///      cannot be more than 100% of the basket and mixing a spot numerator with a stale total would
    ///      otherwise read as a nonsensical share (this binds exactly when the flavor being priced is the
    ///      one that grew, i.e. the manipulator's own). If no reference was recorded this block, spot is
    ///      used unchanged.
    /// @dev Residual, by design: an attacker who holds the inflated position ACROSS a block boundary does
    ///      move the reference, because at that point the imbalance is real, persistent, and carries real
    ///      capital risk — which is precisely the state the tilt exists to price. What this closes is the
    ///      free, atomic, flash-loanable version.
    function _basketRefTotalUsd(uint256 spotEnabledUsd, uint256 floorUsd, bool penaltySide)
        internal
        view
        returns (uint256)
    {
        if (basketRefBlock != uint64(block.number)) return spotEnabledUsd;
        uint256 ref = basketRefTotalUsd;
        if (ref == 0) return spotEnabledUsd;
        uint256 chosen =
            penaltySide ? (ref < spotEnabledUsd ? ref : spotEnabledUsd) : (ref > spotEnabledUsd ? ref : spotEnabledUsd);
        return chosen < floorUsd ? floorUsd : chosen;
    }

    /// @dev The live effective redemption rate for `collateral`, computed exactly as {redeem} applies
    ///      it, so a quote can never diverge from the payout. An unpriceable feed (oracle reverts or
    ///      returns 0) falls back to the flat base rate at par (the payout never depends on the oracle);
    ///      otherwise the weight tilt via {_redeemRateFor} (penalty-direction-only for a frozen flavor).
    ///      Either way the rate is then capped at the backing ratio ({_capAtBacking}) and, when live-priced,
    ///      clamped above par ({_clampAbovePar}) — in that order, so the USD value paid never exceeds the
    ///      ratio's worth per SumUSD. `poolBalance` is the pre-redemption pool balance of `collateral` (in
    ///      its own decimals); `ratioBps` the backing ratio from the same basket snapshot.
    function _liveRedeemRateBps(
        address collateral,
        CollateralConfig memory c,
        uint256 poolBalance,
        uint256 sumUsdAmount,
        uint256 totalUsd,
        uint256 funded,
        uint256 ratioBps
    ) internal view returns (uint256) {
        if (address(c.oracle) == address(0)) return 0; // unlisted: quote 0 rather than reverting
        (uint256 priceWad, bool priced) = _tryPriceWad(collateral, c.oracle);
        if (!priced) return _capAtBacking(c.redeemRateBps, ratioBps); // dead feed: flat base rate at par
        uint256 rate = _redeemRateFor(c, _toUsdAt(poolBalance, c, priceWad), sumUsdAmount, totalUsd, funded);
        return _clampAbovePar(_capAtBacking(rate, ratioBps), priceWad);
    }

    /// @dev Same as {_liveRedeemRateBps}, but also warms the last-good price cache for the touched flavor.
    ///      Lets {_redeemOne} get the rate and the cache write from a SINGLE oracle read instead of the two
    ///      it used to make (one for `_recordPrice`, one for the rate).
    function _redeemRateWithRecord(
        address collateral,
        CollateralConfig memory c,
        uint256 poolBalance,
        uint256 sumUsdAmount,
        uint256 totalUsd,
        uint256 funded,
        uint256 ratioBps
    ) internal returns (uint256) {
        (uint256 priceWad, bool priced) = _tryPriceWad(collateral, c.oracle);
        if (!priced) return _capAtBacking(c.redeemRateBps, ratioBps);
        _writeLastGood(collateral, priceWad);
        uint256 rate = _redeemRateFor(c, _toUsdAt(poolBalance, c, priceWad), sumUsdAmount, totalUsd, funded);
        return _clampAbovePar(_capAtBacking(rate, ratioBps), priceWad);
    }

    /// @dev Cap an effective rate at the backing ratio. Outside distress, backing can legitimately sit
    ///      between the 99% floor and par (in-band sub-$1 deposits, a mild depeg). A redemption paid at a
    ///      rate ABOVE that ratio hands the redeemer more per SumUSD than the pool holds per SumUSD, so it
    ///      pushes every remaining holder's backing DOWN — the first-redeemer dynamic one step at a time —
    ///      and a single large redeem could walk a 99.5%-backed pool through the 99% distress line without
    ///      ever being gated. Capping at the ratio makes every redemption ratio-non-decreasing, which is
    ///      also the premise behind {redeemBatch}'s single up-front distress check. Below the cap nothing
    ///      changes: the ratio can only bind when it is under 100%, and it is never lower than the 99%
    ///      distress line while single-flavor redemption is open, so liveness is untouched. Applied
    ///      BEFORE {_clampAbovePar}, so an above-$1 flavor's value-per-SumUSD is bounded by the ratio too.
    ///      A zero-supply ratio (`type(uint256).max`) never binds.
    function _capAtBacking(uint256 rateBps, uint256 ratioBps) internal pure returns (uint256) {
        return ratioBps < rateBps ? ratioBps : rateBps;
    }

    /// @dev Cap the payout at $1.00 of mark-to-market value per SumUSD burned. The par payout is
    ///      deliberately price-BLIND on the low side (a sub-$1 flavor must not pay out extra units, which
    ///      is what would re-open the round-trip arbitrage), but blind on the HIGH side it lets a flavor
    ///      trading above $1 be drained for more value than the SumUSD burned represents — during a flight
    ///      to quality that is a standing incentive to strip the pool of its best asset and leave the
    ///      impaired one behind, and it makes redemption LOWER the backing ratio. Scaling the rate by
    ///      `1/price` when `price > $1` is the conservative direction only: it can never increase a payout,
    ///      and a dead feed (`priceWad == 0`, handled by the callers) falls through to par unchanged.
    function _clampAbovePar(uint256 rateBps, uint256 priceWad) internal pure returns (uint256) {
        if (priceWad <= WAD) return rateBps;
        return (rateBps * WAD) / priceWad;
    }

    /// @dev Effective redemption rate for `collateral`, given its pooled USD value and the
    ///      enabled-basket stats from {_basketSnapshot}. Routes both {redeem} and the redeem views so they
    ///      can never diverge:
    ///        - ENABLED flavor: the full two-sided weight tilt (discount when overweight, convex
    ///          penalty when underweight).
    ///        - FROZEN (disabled) or DE-BACKED (`backingExcluded`) flavor: the tilt is kept in the PENALTY
    ///          direction ONLY. Either flag drops the flavor out of {_basketSnapshot}, so its share is
    ///          measured on the basket AUGMENTED with itself (`totalUsd + collateralUsd`, `funded + 1`) to
    ///          give a well-defined target, then the result is clamped to at most its base rate. So such a
    ///          flavor keeps its anti-drain convex penalty, but neither flag can ever RAISE its rate above
    ///          base — which would otherwise make draining it cheaper than while it was live. Without the
    ///          augmentation a de-backed flavor would be measured against a basket it is not part of,
    ///          mixing its own spot value into a total that excludes it.
    function _redeemRateFor(
        CollateralConfig memory c,
        uint256 collateralUsd,
        uint256 outUsd,
        uint256 totalUsd,
        uint256 funded
    ) internal view returns (uint256) {
        if (c.enabled && !c.backingExcluded) {
            return _effectiveRedeemRateBps(c.redeemRateBps, collateralUsd, outUsd, totalUsd, funded);
        }
        uint256 tilted =
            _effectiveRedeemRateBps(c.redeemRateBps, collateralUsd, outUsd, totalUsd + collateralUsd, funded + 1);
        return tilted < c.redeemRateBps ? tilted : c.redeemRateBps;
    }

    /// @dev Effective redemption rate around the base `redeemRateBps`, tilted by the collateral's basket
    ///      share vs an equal-weight target (1/funded):
    ///        - OVER-represented (share > 2x target): a small LINEAR bonus (smaller haircut),
    ///          `slope * (share - upperEdge) / BPS`, clamped at 100%.
    ///        - UNDER-represented (share < target/2): a CONVEX penalty `slope * (lowerEdge - share) / share`
    ///          that is mild near the band but grows without bound as the flavor nears depletion
    ///          (share -> 0), so the last units return almost nothing. Clamped at 0; never reverts.
    ///      Falls back to the flat base when the tilt can't apply (slope 0, < 2 funded, empty pool).
    ///
    ///      INTEGRATED (post-redemption) PRICING. The share is measured on the basket as it will stand
    ///      AFTER this redemption settles, not before it. `outUsd` is the redemption's face value, which is
    ///      the maximum USD that can leave (the effective rate is <= 100%), so the adjustment is
    ///      conservative in both directions. Two things follow:
    ///        1. A large redemption of a scarce flavor prices strictly worse than the marginal quote — the
    ///           anti-drain property the whitepaper wanted from integrated pricing, rather than one spot
    ///           rate applied to the whole size.
    ///        2. A self-created imbalance cannot be cashed out. Flash-depositing a flavor to push it past
    ///           the upper edge used to clamp its rate to 100%, letting the attacker redeem the flash mint
    ///           AND their pre-existing balance with no haircut at all. Priced post-redemption, unwinding
    ///           the deposit unwinds the share that justified the bonus, so the bonus evaluates to nothing.
    ///      The denominator additionally passes through {_basketRefTotalUsd}, which caps how far an
    ///      intra-block basket inflation can move the measured share against a third-party redeemer.
    function _effectiveRedeemRateBps(
        uint16 baseRedeemRateBps,
        uint256 collateralUsd,
        uint256 outUsd,
        uint256 totalUsd,
        uint256 funded
    ) internal view returns (uint256) {
        uint256 slope = tiltSlopeBps;
        if (slope == 0 || funded < 2 || totalUsd == 0) return baseRedeemRateBps;

        // Parity band around the equal-weight target (`BPS / funded`): a flavor redeems at its base
        // rate while its weight sits between half and twice that target. The overweight discount starts
        // only ABOVE 2x target; the convex underweight premium starts only BELOW 1/2x target. Edges are
        // inclusive, so a flavor must be strictly outside the band before any tilt is priced. Tilts are
        // measured from the band edge (not from target), so the rate is continuous at the knee. The
        // edges multiply BPS before dividing (no divide-before-multiply), so each is exact to the floor.
        uint256 upperEdge = (2 * BPS) / funded; // 2 x (BPS / funded)
        uint256 lowerEdge = BPS / (2 * funded); // (BPS / funded) / 2

        // Bonus side: the LARGER of (spot, block-start) basket total, so an intra-block inflation of the
        // basket can never manufacture an overweight bonus.
        uint256 bonusShare =
            _postTradeShareBps(collateralUsd, outUsd, _basketRefTotalUsd(totalUsd, collateralUsd, false));
        if (bonusShare > upperEdge) {
            uint256 bonus = (slope * (bonusShare - upperEdge)) / BPS;
            uint256 eff = uint256(baseRedeemRateBps) + bonus;
            return eff > BPS ? BPS : eff;
        }

        // Penalty side: the SMALLER of (spot, block-start) basket total, so an intra-block inflation of the
        // basket can never deepen a third party's convex penalty (the redemption-DoS griefing vector).
        uint256 penaltyShare =
            _postTradeShareBps(collateralUsd, outUsd, _basketRefTotalUsd(totalUsd, collateralUsd, true));
        if (penaltyShare < lowerEdge) {
            // Under-represented beyond the band: convex premium (larger haircut) that grows without
            // bound as the flavor nears depletion.
            if (penaltyShare == 0) return 0;
            uint256 penalty = (slope * (lowerEdge - penaltyShare)) / penaltyShare;
            return penalty >= baseRedeemRateBps ? 0 : baseRedeemRateBps - penalty;
        }
        return baseRedeemRateBps; // within the parity band
    }

    /// @dev The flavor's basket share in bps once `outUsd` of it has left the pool, i.e.
    ///      `(collateralUsd - outUsd) / (totalUsd - outUsd)`. Always <= the pre-trade share, since removing
    ///      the same amount from numerator and denominator can only shrink a ratio <= 1. Both subtractions
    ///      floor at zero, so an over-sized quote reads as a fully-drained flavor (share 0) rather than
    ///      underflowing. `outUsd == 0` reproduces the marginal (pre-trade) share exactly.
    function _postTradeShareBps(uint256 collateralUsd, uint256 outUsd, uint256 totalUsd)
        internal
        pure
        returns (uint256)
    {
        if (outUsd >= totalUsd) return 0;
        uint256 c = collateralUsd > outUsd ? collateralUsd - outUsd : 0;
        return (c * BPS) / (totalUsd - outUsd);
    }
}
