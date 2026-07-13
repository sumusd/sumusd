// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {MedianOracleAdapter} from "../src/oracles/MedianOracleAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../test/mocks/MockAggregatorV3.sol";

/// @notice End-to-end testnet bringup: deploys the protocol plus mock collateral and a
///         {MedianOracleAdapter} that prices each flavor over TWO independent {ChainlinkOracleAdapter}
///         providers (each wrapping its own settable Chainlink-shaped mock aggregator), lists every
///         flavor against the median, and faucets some collateral to the deployer so the dapp is
///         immediately usable on Sepolia.
///
/// @dev Intended for testnets ONLY — the collateral and price feeds here are unaudited mocks anyone
///      can mint/reprice. It wires the *real* production oracle stack (two `ChainlinkOracleAdapter`s
///      under a `MedianOracleAdapter`) so the full path — per-provider decimal scaling / staleness /
///      sane-band, then median + quorum + spread breaker — is exercised end to end. Because nothing
///      pushes fresh rounds to the mock aggregators on a testnet, the staleness bound here is set
///      deliberately long (see {FEED_STALENESS}) so the dapp keeps working without a keeper; a real
///      deployment points each provider's `setFeed` at genuine Chainlink aggregators with a
///      heartbeat-based staleness (e.g. ~1h). The aggregator addresses are logged so a tester can
///      age/reprice one feed (`agg.setUpdatedAt(...)` / `agg.setAnswer(...)`) to exercise the
///      median's outage tolerance (`MIN_FRESH = 1`, so the surviving feed still prices) and the
///      disagreement breaker (`MAX_SPREAD_BPS`).
///
/// Usage:
///   forge script script/SetupSepolia.s.sol:SetupSepolia \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
contract SetupSepolia is Script {
    uint256 internal constant BPS = 10_000;
    uint16 internal constant TILT = 500; // convex haircut sensitivity (mild near target, steep near depletion)
    // Base redeem rate < 100% leaves headroom for the tilt to reward over-represented redemptions.
    uint16 internal constant BASE_STABLE = 9900; // base for the most liquid flavors (99%)
    uint16 internal constant BASE_C = 9700; // base for a conservatively-rated flavor (97%)

    // Chainlink USD feeds are 8-decimal; $1.00 == 1e8.
    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant FEED_ONE = 1e8;
    // TESTNET ONLY: no keeper refreshes the mock aggregators, so use a very long staleness bound
    // (~10 years) to keep the dapp usable. Production uses the feed's heartbeat plus a buffer.
    uint32 internal constant FEED_STALENESS = uint32(3650 days);
    // Absolute sane band: reject a feed reading outside [$0.90, $1.10] as a malfunction. In-band
    // depegs are still reported (the engine's own 0.5% deposit peg band gates deposits).
    uint128 internal constant SANE_MIN = 0.9e18;
    uint128 internal constant SANE_MAX = 1.1e18;

    // Median config: require at least 1 fresh provider (tolerate one feed outage; the survivor still
    // prices), and reject when the two fresh providers disagree by more than 1% (a manipulation / bad-
    // feed circuit breaker; median-of-2 is their average). A stricter setup could require both fresh.
    uint32 internal constant MIN_FRESH = 1;
    uint32 internal constant MAX_SPREAD_BPS = 100; // 1%

    function run() external {
        vm.startBroadcast();
        address admin = msg.sender;

        // Core protocol.
        SumUSD sumUsd = new SumUSD(admin);
        SumUSDEngine engine = new SumUSDEngine(admin, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        // Mock collateral flavors. These placeholders stand in for whitelisted, GENIUS-Act-compliant
        // stablecoins on a real deployment.
        MockERC20 flavorA = new MockERC20("Flavor A", "FLAV-A", 6);
        MockERC20 flavorB = new MockERC20("Flavor B", "FLAV-B", 6);
        MockERC20 flavorC = new MockERC20("Flavor C", "FLAV-C", 18);

        // Two independent Chainlink-shaped oracle providers, plus a median over them. On mainnet the
        // aggregators wired below are the real Chainlink (and a second provider's) feeds.
        ChainlinkOracleAdapter oracle1 = new ChainlinkOracleAdapter(admin);
        ChainlinkOracleAdapter oracle2 = new ChainlinkOracleAdapter(admin);
        MedianOracleAdapter median = new MedianOracleAdapter(admin);

        // Per flavor: two mock aggregators (one per provider) at $1.00, wired into each provider adapter
        // and medianized. Logs the aggregator pair for each flavor.
        _wireMedianFeeds(oracle1, oracle2, median, address(flavorA));
        _wireMedianFeeds(oracle1, oracle2, median, address(flavorB));
        _wireMedianFeeds(oracle1, oracle2, median, address(flavorC));

        // List flavors against the MEDIAN oracle: 99% base redeem rate for the most liquid two, 97% for
        // a conservatively-rated one. Balance is maintained by the convex tilt.
        engine.setCollateral(address(flavorA), true, BASE_STABLE, median);
        engine.setCollateral(address(flavorB), true, BASE_STABLE, median);
        engine.setCollateral(address(flavorC), true, BASE_C, median);

        // Convex weight-tilted haircut: redeeming an over-represented flavor is cheaper, and an
        // under-represented one gets steeply more expensive as it depletes — nudging rebalancing.
        engine.setTiltSlopeBps(TILT);

        // 2 bps redemption fee: 1 bp retained as extra backing, 1 bp routed to the fee recipient
        // (the deployer here, stands in for a treasury). redeemMix (distress exit) is exempt.
        engine.setRedeemFee(2, 1);
        engine.setFeeRecipient(admin);

        // Faucet the deployer so the dapp can be exercised right away.
        flavorA.mint(admin, 1_000_000e6);
        flavorB.mint(admin, 1_000_000e6);
        flavorC.mint(admin, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("=== SumUSD Sepolia deployment ===");
        console2.log("Admin/deployer:", admin);
        console2.log("");
        console2.log("Paste into sumusd-com-website/.env.local:");
        console2.log("NEXT_PUBLIC_SUMUSD_ADDRESS=%s", address(sumUsd));
        console2.log("NEXT_PUBLIC_ENGINE_ADDRESS=%s", address(engine));
        console2.log("NEXT_PUBLIC_FLAVOR_A=%s", address(flavorA));
        console2.log("NEXT_PUBLIC_FLAVOR_B=%s", address(flavorB));
        console2.log("NEXT_PUBLIC_FLAVOR_C=%s", address(flavorC));
        console2.log("");
        console2.log("Median oracle (engine reads this): %s", address(median));
        console2.log("Provider 1 (ChainlinkOracleAdapter): %s", address(oracle1));
        console2.log("Provider 2 (ChainlinkOracleAdapter): %s", address(oracle2));
        console2.log("(reprice/age one provider's aggregator to exercise the median's outage tolerance");
        console2.log(" and disagreement breaker; per-flavor aggregator pairs are logged above)");
    }

    /// @dev Deploy two mock aggregators for `token` (one per provider), wire each into its provider
    ///      adapter, and configure the median over both providers. Kept as a helper so {run} stays
    ///      under the stack-depth limit.
    function _wireMedianFeeds(
        ChainlinkOracleAdapter oracle1,
        ChainlinkOracleAdapter oracle2,
        MedianOracleAdapter median,
        address token
    ) internal {
        MockAggregatorV3 agg1 = new MockAggregatorV3(FEED_DECIMALS, FEED_ONE, block.timestamp);
        MockAggregatorV3 agg2 = new MockAggregatorV3(FEED_DECIMALS, FEED_ONE, block.timestamp);
        oracle1.setFeed(token, address(agg1), FEED_STALENESS, SANE_MIN, SANE_MAX);
        oracle2.setFeed(token, address(agg2), FEED_STALENESS, SANE_MIN, SANE_MAX);

        IPriceOracle[] memory sources = new IPriceOracle[](2);
        sources[0] = oracle1;
        sources[1] = oracle2;
        median.setSources(token, sources, MIN_FRESH, MAX_SPREAD_BPS);

        console2.log("Flavor feeds  token:", token);
        console2.log("  provider 1 aggregator:", address(agg1));
        console2.log("  provider 2 aggregator:", address(agg2));
    }
}
