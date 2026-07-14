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
///      no fee or sweep path to extract it.
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
///      Distress mode (anti-run): below DISTRESS_RATIO_BPS (99%) the pick-your-flavor `redeem` is
///      disabled and holders exit via `redeemMix` — a pro-rata claim returning sumUsd/totalSupply of
///      EVERY collateral. This shares the shortfall equally regardless of redemption order (no
///      first-redeemer advantage), keeps the backing ratio flat as holders exit, and needs no oracle.
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
    uint256 internal constant MIN_MINT_RATIO_BPS = 9900; // 99%
    /// @notice Distress line. At/above this backing ratio the system operates normally (minting on,
    ///         pick-your-flavor redemption). Below it the system is distressed: minting is already
    ///         frozen (== MIN_MINT_RATIO_BPS) and single-flavor `redeem` is disabled in favor of
    ///         {redeemMix} — a pro-rata claim on the whole basket that shares the shortfall equally
    ///         across holders, removing the first-redeemer advantage / run incentive.
    uint256 internal constant DISTRESS_RATIO_BPS = 9900; // 99%
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
    ///         (`deposit`/`redeem`/`totalCollateralValueUsd`/`_basketStats`/`poolNeeds`) so their gas
    ///         can never grow without limit. Drained, disabled collaterals can be removed to free a
    ///         slot ({removeCollateral}).
    uint256 internal constant MAX_COLLATERALS = 24;
    /// @notice Immutable cap on a listed collateral's decimals. Every GENIUS-Act payment stablecoin uses
    ///         6 or 18; values above 18 would strain the engine's `10 ** decimals` unit math, so they are
    ///         rejected by the listing probe ({_probeCollateral}).
    uint8 internal constant MAX_COLLATERAL_DECIMALS = 18;
    /// @notice Immutable sanity rail on the total `redeemFeeBps`. Caps the redemption fee governance
    ///         can impose (on top of the tilt haircut) at 2 bps (0.02%), so no admin can set a punitive
    ///         exit fee. 0 stays valid (no fee). The routable portion is separately capped at `redeemFeeBps`.
    uint256 internal constant MAX_REDEEM_FEE_BPS = 2; // 0.02%
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

    /// @notice Total redemption fee (bps of the gross payout) taken on single-flavor {redeem}, ON TOP
    ///         of the weight-tilt haircut. 0 disables the fee. Railed to `MAX_REDEEM_FEE_BPS`. The
    ///         distress exit {redeemMix} is intentionally exempt (it stays fee/haircut/oracle-free).
    uint16 public redeemFeeBps;
    /// @notice Portion of `redeemFeeBps` routed to {feeRecipient}; the remainder stays in the pool as
    ///         extra backing (an additional haircut). Must be <= `redeemFeeBps`. With the reference
    ///         2 bps / 1 bp config: 1 bp is paid to the recipient and 1 bp is retained as backing.
    uint16 public feeToRecipientBps;
    /// @notice Recipient of the routed fee portion. Settable only by the owner (the 96h timelock). While
    ///         unset (`address(0)`), the routed portion also stays in the pool, so no value leaves.
    address public feeRecipient;

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
    event RedeemFeeUpdated(uint16 redeemFeeBps, uint16 feeToRecipientBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event RedeemFeePaid(address indexed collateral, address indexed recipient, uint256 toRecipient, uint256 retained);
    event StalePriceParamsUpdated(uint32 graceSeconds, uint16 haircutBps);
    event PriceRecorded(address indexed token, uint256 priceWad, uint256 at);

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
    error ZeroCollateralOut(uint256 sumUsdAmount);
    error InvalidRedeemFee(uint16 redeemFeeBps, uint16 feeToRecipientBps);
    error InvalidStalePriceParams(uint32 graceSeconds, uint16 haircutBps);

    /// @param admin   Owner of the engine (risk admin / governance).
    /// @param _sumUsd The SumUSD token. The engine must be granted MINTER_ROLE on it separately.
    constructor(address admin, SumUSD _sumUsd) Ownable(admin) {
        require(address(_sumUsd) != address(0), "engine: sumUsd=0");
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
    ///      allowed.
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
        if (amount == 0) revert ZeroAmount();

        // Mint guard: do not issue new SumUSD while backing is below MIN_MINT_RATIO_BPS.
        // Checked on the pre-deposit snapshot; bootstrap (supply == 0) reads as fully backed.
        uint256 ratioBps = systemCollateralizationRatioBps();
        if (ratioBps < MIN_MINT_RATIO_BPS) revert UnderCollateralized(ratioBps);

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
        CollateralConfig memory c = configs[collateral];
        if (address(c.oracle) == address(0)) revert CollateralNotEnabled(collateral); // unlisted
        if (sumUsdAmount == 0) revert ZeroAmount();

        // Warm the last-good cache for the touched flavor (no-op if its feed is currently down).
        _recordPrice(collateral, c.oracle);

        // Below the distress line, single-flavor (cherry-pick) redemption is disabled to stop the
        // first-redeemer run; holders exit pro-rata via {redeemMix}.
        uint256 ratioBps = systemCollateralizationRatioBps();
        if (ratioBps < DISTRESS_RATIO_BPS) revert UseRedeemMix(ratioBps);

        uint256 available = IERC20(collateral).balanceOf(address(this));
        (uint256 totalUsd, uint256 funded) = _basketStats();

        // Effective haircut from the weight tilt (priced on the pre-redemption basket). The oracle is
        // read only to weigh the flavor's basket share — it does NOT price the payout. An unpriceable
        // flavor can't be weighed, so it redeems at the flat base rate (the par payout below never
        // depends on the oracle). A FROZEN (disabled) flavor keeps the tilt in the PENALTY direction
        // only. See {_liveRedeemRateBps} / {_redeemRateFor}; the views quote the same function.
        uint256 effectiveRedeemRateBps = _liveRedeemRateBps(collateral, c, available, totalUsd, funded);

        // Fungible 1:1 payout: burning N SumUSD returns N * effectiveRate units of collateral,
        // decimal-normalized at par ($1 = 1 unit). The oracle price does not enter the conversion.
        uint256 grossOut = _toUnits((sumUsdAmount * effectiveRedeemRateBps) / BPS, c);
        // Redemption fee (bps of the gross payout) on top of the tilt haircut, deducted from the
        // redeemer; the routed portion goes to `feeRecipient` and the rest stays pooled as extra
        // backing. {redeemMix} (the distress exit) is exempt. Settled after the burn by {_settleRedeemFee}.
        collateralOut = grossOut - (grossOut * redeemFeeBps) / BPS; // net to the redeemer

        // Dust guard: if a POSITIVE-rate redemption nets to zero collateral (input too small for the
        // token's decimals), revert rather than burn SumUSD for nothing. A rate of exactly 0 (a
        // fully-depleted flavor priced to ~0 by the convex tilt) is left to return 0 without reverting,
        // preserving the "the tilt never gates a flavor" liveness property — the holder simply exits via
        // another flavor (SumUSD is a fungible claim), or {redeemMix} in distress.
        if (collateralOut == 0 && effectiveRedeemRateBps != 0) revert ZeroCollateralOut(sumUsdAmount);
        if (collateralOut < minCollateralOut) revert SlippageExceeded(collateralOut, minCollateralOut);
        // The full gross must be available (net to redeemer + routed fee both come out of it; any
        // retained fee just stays pooled), so checking gross conservatively covers both transfers.
        if (grossOut > available) revert InsufficientPool(collateral, grossOut, available);

        sumUsd.burn(msg.sender, sumUsdAmount);
        IERC20(collateral).safeTransfer(msg.sender, collateralOut);
        _settleRedeemFee(collateral, grossOut); // routes the fee portion (best-effort) and emits
        emit Redeemed(msg.sender, collateral, sumUsdAmount, collateralOut);
    }

    /// @notice Pro-rata "redeem the mix": burn `sumUsdAmount` and receive `sumUsdAmount / totalSupply`
    ///         of EVERY listed collateral (enabled and frozen). Only callable when the system is
    ///         distressed (backing < {DISTRESS_RATIO_BPS}); it is the fair, order-independent exit
    ///         that shares the shortfall equally across all holders (no first-redeemer advantage).
    /// @dev Payout is pure ownership math — no oracle, no haircut, no tilt — so it works even with
    ///      dead feeds. `minOut` is per-collateral slippage protection on the computed slice: pass an
    ///      empty array to skip, or one of length `collateralList.length` aligned to {listedCollaterals}.
    ///      A flavor whose transfer FAILS (e.g. the issuer blacklisted the engine) is SKIPPED, not
    ///      reverted, so one non-transferable collateral can never brick the whole exit; its slice
    ///      stays pooled and the returned `amounts[i]` is 0 for any skipped flavor.
    /// @return amounts Units of each listed collateral actually sent, in `collateralList` order.
    function redeemMix(uint256 sumUsdAmount, uint256[] calldata minOut)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        uint256 ratioBps = systemCollateralizationRatioBps();
        if (ratioBps >= DISTRESS_RATIO_BPS) revert NotDistressed(ratioBps);
        if (sumUsdAmount == 0) revert ZeroAmount();

        uint256 len = collateralList.length;
        if (minOut.length != 0 && minOut.length != len) revert MinOutLengthMismatch();

        uint256 supply = sumUsd.totalSupply(); // > 0 (caller holds sumUsdAmount)
        amounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            uint256 out = (IERC20(collateralList[i]).balanceOf(address(this)) * sumUsdAmount) / supply;
            amounts[i] = out;
            if (minOut.length != 0 && out < minOut[i]) revert SlippageExceeded(out, minOut[i]);
        }

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

    /// @notice Donate `amount` of a listed `collateral` to the pool as permanent backing, minting NO
    ///         SumUSD in return. Raises `totalCollateralValueUsd()` (and the backing ratio) without
    ///         increasing supply — a first-class recapitalization path.
    /// @dev Anyone may call this. It is the intended way to lift backing back above the mint floor /
    ///      distress line: below `DISTRESS_RATIO_BPS` the `redeemMix` exit is ratio-flat (it burns
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
    ///         would return right now (in `collateralList` order). Independent of regime/oracle.
    function previewRedeemMix(uint256 sumUsdAmount)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 len = collateralList.length;
        tokens = new address[](len);
        amounts = new uint256[](len);
        uint256 supply = sumUsd.totalSupply();
        for (uint256 i; i < len; ++i) {
            tokens[i] = collateralList[i];
            if (supply != 0) {
                amounts[i] = (IERC20(collateralList[i]).balanceOf(address(this)) * sumUsdAmount) / supply;
            }
        }
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
    ///         answered. `ok == false` means the feed is currently unavailable (reverting or 0). Useful
    ///         for surfacing feed health in a UI.
    function livePriceWad(address collateral) external view returns (uint256 priceWad, bool ok) {
        return _tryPriceWad(collateral, configs[collateral].oracle);
    }

    /// @notice The price actually used to VALUE `collateral` for backing/tilt right now: the live feed
    ///         if available, else the haircut last-good price within the grace window, else 0.
    function valuationPriceWad(address collateral) external view returns (uint256) {
        return _valuationPriceWad(collateral, configs[collateral].oracle);
    }

    /// @notice Total USD value (WAD) of the entire collateral basket.
    function totalCollateralValueUsd() public view returns (uint256 total) {
        uint256 len = collateralList.length;
        for (uint256 i; i < len; ++i) {
            total += collateralValueUsd(collateralList[i]);
        }
    }

    /// @notice System collateralization ratio in bps (collateral value / SumUSD supply).
    /// @return ratioBps `10_000` == exactly 100%. Returns `type(uint256).max` when supply is 0.
    function systemCollateralizationRatioBps() public view returns (uint256 ratioBps) {
        uint256 supply = sumUsd.totalSupply();
        if (supply == 0) return type(uint256).max;
        return (totalCollateralValueUsd() * BPS) / supply;
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
    ///         now — the weight-tilted haircut AND the redemption fee both applied — so the quote
    ///         matches the actual {redeem} payout.
    function previewRedeem(address collateral, uint256 sumUsdAmount) external view returns (uint256) {
        CollateralConfig memory c = configs[collateral];
        (uint256 totalUsd, uint256 funded) = _basketStats();
        uint256 poolBalance = IERC20(collateral).balanceOf(address(this));
        uint256 effectiveRedeemRateBps = _liveRedeemRateBps(collateral, c, poolBalance, totalUsd, funded);
        uint256 grossOut = _toUnits((sumUsdAmount * effectiveRedeemRateBps) / BPS, c);
        (uint256 feeTotal,) = _redeemFee(grossOut);
        return grossOut - feeTotal;
    }

    /// @notice Break down what redeeming `sumUsdAmount` of `collateral` pays right now: the redeemer's
    ///         net, the fee routed to {feeRecipient}, and the fee retained in the pool.
    function previewRedeemFee(address collateral, uint256 sumUsdAmount)
        external
        view
        returns (uint256 toRedeemer, uint256 toRecipient, uint256 retained)
    {
        CollateralConfig memory c = configs[collateral];
        (uint256 totalUsd, uint256 funded) = _basketStats();
        uint256 poolBalance = IERC20(collateral).balanceOf(address(this));
        uint256 effectiveRedeemRateBps = _liveRedeemRateBps(collateral, c, poolBalance, totalUsd, funded);
        uint256 grossOut = _toUnits((sumUsdAmount * effectiveRedeemRateBps) / BPS, c);
        uint256 feeTotal;
        (feeTotal, toRecipient) = _redeemFee(grossOut);
        toRedeemer = grossOut - feeTotal;
        retained = feeTotal - toRecipient;
    }

    /// @notice The effective redemption rate (bps) for `collateral` right now: its base `redeemRateBps`
    ///         tilted by the basket's current imbalance. `10_000` == 100% (no haircut). This is the
    ///         weight-tilt rate ONLY — it does NOT include the flat `redeemFeeBps` redemption fee; use
    ///         {previewRedeem}/{previewRedeemFee} for the exact net payout.
    function currentRedeemRateBps(address collateral) public view returns (uint256) {
        CollateralConfig memory c = configs[collateral];
        (uint256 totalUsd, uint256 funded) = _basketStats();
        uint256 poolBalance = IERC20(collateral).balanceOf(address(this));
        return _liveRedeemRateBps(collateral, c, poolBalance, totalUsd, funded);
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
            uint256 value = _toUsdAt(IERC20(token).balanceOf(address(this)), c, priceWad);
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

    /// @notice Set the single-flavor redemption fee (bps of the gross payout, on top of the tilt
    ///         haircut) and the portion of it routed to {feeRecipient}; the remainder stays in the pool
    ///         as extra backing. Owner-only, so in production every change waits the 96h timelock.
    /// @dev {redeemMix} (the distress exit) is never charged. Reference config: `newRedeemFeeBps = 2`
    ///      (2 bps total), `newFeeToRecipientBps = 1` (1 bp to the recipient, 1 bp retained as backing).
    /// @param newRedeemFeeBps      Total fee, railed to [0, {MAX_REDEEM_FEE_BPS}].
    /// @param newFeeToRecipientBps Portion routed to {feeRecipient}; must be <= `newRedeemFeeBps`.
    function setRedeemFee(uint16 newRedeemFeeBps, uint16 newFeeToRecipientBps) external onlyOwner {
        if (newRedeemFeeBps > MAX_REDEEM_FEE_BPS || newFeeToRecipientBps > newRedeemFeeBps) {
            revert InvalidRedeemFee(newRedeemFeeBps, newFeeToRecipientBps);
        }
        redeemFeeBps = newRedeemFeeBps;
        feeToRecipientBps = newFeeToRecipientBps;
        emit RedeemFeeUpdated(newRedeemFeeBps, newFeeToRecipientBps);
    }

    /// @notice Set (or clear, with `address(0)`) the recipient of the routed redemption-fee portion.
    ///         Owner-only, so changing it waits the 96h timelock. While unset, the routed portion stays
    ///         in the pool (no value leaves), so a fee can be configured before a treasury is live.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
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

    /// @dev Split a gross redemption payout into the total fee and the portion routed to `feeRecipient`
    ///      (0 while the recipient is unset — the routed portion then stays pooled). The remaining
    ///      `feeTotal - toRecipient` always stays in the pool as extra backing. Both round down.
    function _redeemFee(uint256 grossOut) internal view returns (uint256 feeTotal, uint256 toRecipient) {
        feeTotal = (grossOut * redeemFeeBps) / BPS;
        if (feeRecipient != address(0)) toRecipient = (grossOut * feeToRecipientBps) / BPS;
    }

    /// @dev Route the redemption fee for a gross payout of `grossOut` in `collateral`, after the
    ///      redeemer's net has already been sent. The recipient portion is transferred best-effort (a
    ///      recipient that can't receive is skipped, its slice staying pooled) so the fee can never
    ///      block a redemption; the retained portion is left in the pool. Emits {RedeemFeePaid} when a
    ///      fee applies. Kept as a separate call so {redeem} stays under the stack-depth limit.
    function _settleRedeemFee(address collateral, uint256 grossOut) internal {
        (uint256 feeTotal, uint256 toRecipient) = _redeemFee(grossOut);
        if (feeTotal == 0) return;
        if (toRecipient != 0 && !_tryTransfer(collateral, feeRecipient, toRecipient)) toRecipient = 0;
        emit RedeemFeePaid(collateral, feeRecipient, toRecipient, feeTotal - toRecipient);
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
    function _recordPrice(address token, IPriceOracle oracle) internal {
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
        return _toUsdAt(IERC20(collateral).balanceOf(address(this)), c, priceWad);
    }

    /// @dev One pass over the basket for the weight tilt: total USD value and the count of
    ///      collaterals with a non-zero balance, **counting only ENABLED collaterals**. A frozen
    ///      (disabled) collateral is excluded from the share/target math — it is not redeemable, so
    ///      it should not skew the rates of the redeemable flavors. (It still counts toward the
    ///      backing ratio via {totalCollateralValueUsd}.)
    function _basketStats() internal view returns (uint256 totalUsd, uint256 funded) {
        uint256 len = collateralList.length;
        for (uint256 i; i < len; ++i) {
            address token = collateralList[i];
            if (!configs[token].enabled) continue;
            uint256 value = collateralValueUsd(token);
            if (value == 0) continue;
            totalUsd += value;
            funded++;
        }
    }

    /// @dev The live effective redemption rate for `collateral`, computed exactly as {redeem} applies
    ///      it, so a quote can never diverge from the payout. An unpriceable feed (oracle reverts or
    ///      returns 0) falls back to the flat base rate at par (the payout never depends on the oracle);
    ///      otherwise the weight tilt via {_redeemRateFor} (penalty-direction-only for a frozen flavor).
    ///      `poolBalance` is the pre-redemption pool balance of `collateral` (in its own decimals).
    function _liveRedeemRateBps(
        address collateral,
        CollateralConfig memory c,
        uint256 poolBalance,
        uint256 totalUsd,
        uint256 funded
    ) internal view returns (uint256) {
        (uint256 priceWad, bool priced) = _tryPriceWad(collateral, c.oracle);
        if (!priced) return c.redeemRateBps;
        return _redeemRateFor(c, _toUsdAt(poolBalance, c, priceWad), totalUsd, funded);
    }

    /// @dev Effective redemption rate for `collateral`, given its pooled USD value and the
    ///      enabled-basket stats from {_basketStats}. Routes both {redeem} and the redeem views so they
    ///      can never diverge:
    ///        - ENABLED flavor: the full two-sided weight tilt (discount when overweight, convex
    ///          penalty when underweight).
    ///        - FROZEN (disabled) flavor: the tilt is kept in the PENALTY direction ONLY. The frozen
    ///          flavor is excluded from {_basketStats}, so its share is measured on the basket
    ///          AUGMENTED with itself (`totalUsd + collateralUsd`, `funded + 1`) to give a well-defined
    ///          target, then the result is clamped to at most its base rate. So a frozen, scarce flavor
    ///          keeps its anti-drain convex penalty, but a freeze can never RAISE its rate above base —
    ///          which would otherwise make draining a frozen flavor cheaper than while it was live.
    function _redeemRateFor(CollateralConfig memory c, uint256 collateralUsd, uint256 totalUsd, uint256 funded)
        internal
        view
        returns (uint256)
    {
        if (c.enabled) {
            return _effectiveRedeemRateBps(c.redeemRateBps, collateralUsd, totalUsd, funded);
        }
        uint256 tilted = _effectiveRedeemRateBps(c.redeemRateBps, collateralUsd, totalUsd + collateralUsd, funded + 1);
        return tilted < c.redeemRateBps ? tilted : c.redeemRateBps;
    }

    /// @dev Effective redemption rate around the base `redeemRateBps`, tilted by the collateral's basket
    ///      share vs an equal-weight target (1/funded):
    ///        - OVER-represented (share >= target): a small LINEAR bonus (smaller haircut),
    ///          `slope * (share - target) / BPS`, clamped at 100%.
    ///        - UNDER-represented (share < target): a CONVEX penalty `slope * (target - share) / share`
    ///          that is mild near the target but grows without bound as the flavor nears depletion
    ///          (share -> 0), so the last units return almost nothing. Clamped at 0; never reverts.
    ///      Falls back to the flat base when the tilt can't apply (slope 0, < 2 funded, empty pool).
    function _effectiveRedeemRateBps(uint16 baseRedeemRateBps, uint256 collateralUsd, uint256 totalUsd, uint256 funded)
        internal
        view
        returns (uint256)
    {
        uint256 slope = tiltSlopeBps;
        if (slope == 0 || funded < 2 || totalUsd == 0) return baseRedeemRateBps;

        uint256 shareBps = (collateralUsd * BPS) / totalUsd;
        uint256 targetBps = BPS / funded;

        // Parity band: a flavor redeems at its base rate while its weight sits between half and
        // twice its equal-weight target. The overweight discount starts only ABOVE 2x target; the
        // convex underweight premium starts only BELOW 1/2x target. Edges are inclusive, so a flavor
        // must be strictly outside the band before any tilt is priced. Tilts are measured from the
        // band edge (not from target), so the rate is continuous at the knee.
        uint256 upperEdge = 2 * targetBps;
        uint256 lowerEdge = targetBps / 2;

        if (shareBps > upperEdge) {
            // Over-represented beyond the band: small linear discount (smaller haircut), capped at 100%.
            uint256 bonus = (slope * (shareBps - upperEdge)) / BPS;
            uint256 eff = uint256(baseRedeemRateBps) + bonus;
            return eff > BPS ? BPS : eff;
        }
        if (shareBps < lowerEdge) {
            // Under-represented beyond the band: convex premium (larger haircut) that grows without
            // bound as the flavor nears depletion. shareBps > 0 here (collateralUsd > 0 on redeem).
            if (shareBps == 0) return 0;
            uint256 penalty = (slope * (lowerEdge - shareBps)) / shareBps;
            return penalty >= baseRedeemRateBps ? 0 : baseRedeemRateBps - penalty;
        }
        return baseRedeemRateBps; // within the parity band
    }
}
