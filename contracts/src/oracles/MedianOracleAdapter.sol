// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title MedianOracleAdapter
/// @notice Aggregates several {IPriceOracle} sources per collateral and returns the MEDIAN of the ones
///         that answer successfully, so no single feed can move the reported price and a dead feed is
///         simply skipped. It is fail-closed: if fewer than `minFresh` sources answer, or (optionally)
///         the fresh sources disagree by more than `maxSpreadBps`, {getPriceWad} REVERTS — which the
///         {SumUSDEngine} treats as "unpriceable" and values the collateral at 0 (conservative).
///
/// @dev Layer this OVER per-provider adapters (e.g. two {ChainlinkOracleAdapter}s wrapping independent
///      Chainlink and Redstone feeds) to get provider redundancy: the median tolerates one compromised
///      or stale source, and the quorum guarantees a minimum of independent confirmations. Each source
///      is read through try/catch, so a reverting/fail-closed source is treated as "not fresh" rather
///      than bubbling up. Holds no funds; pure read-only pricing with owner-gated configuration.
contract MedianOracleAdapter is IPriceOracle, Ownable2Step {
    uint256 internal constant BPS = 10_000;
    /// @notice Immutable cap on the number of component sources per token. Bounds the O(n) read loop
    ///         and O(n^2) sort in {getPriceWad} — which runs inside the engine's basket-wide loops on
    ///         every deposit/redeem — so governance can never configure a source array large enough to
    ///         make pricing prohibitively expensive. Mirrors the engine's `MAX_COLLATERALS` rail.
    uint256 internal constant MAX_SOURCES = 7;

    /// @notice Per-collateral aggregation configuration.
    struct Sources {
        IPriceOracle[] oracles; // component price sources for this token
        uint32 minFresh; // minimum sources that must answer (quorum); 0 in an unconfigured entry
        uint32 maxSpreadBps; // if > 0, revert when (max - min) of the fresh set exceeds this vs the median
    }

    mapping(address token => Sources config) internal _sources;

    event SourcesConfigured(address indexed token, uint256 count, uint32 minFresh, uint32 maxSpreadBps);
    event SourcesRemoved(address indexed token);

    error NoSources(address token);
    error InvalidQuorum(uint32 minFresh, uint256 count);
    error TooManySources(uint256 count, uint256 max);
    error ZeroSource();
    error InsufficientFreshSources(address token, uint256 fresh, uint32 required);
    error SpreadTooWide(address token, uint256 spreadBps, uint32 maxSpreadBps);

    constructor(address admin) Ownable(admin) {}

    // ---------------------------------------------------------------------
    // Configuration (owner / timelock)
    // ---------------------------------------------------------------------

    /// @notice Configure the component sources for `token`.
    /// @param token        Collateral token to price.
    /// @param oracles      Component {IPriceOracle} sources (none may be the zero address).
    /// @param minFresh     Minimum number that must answer for a valid median. Must be in [1, oracles.length].
    /// @param maxSpreadBps If > 0, reject when the fresh sources' (max - min) exceeds this fraction of the
    ///                     median (a disagreement circuit breaker). 0 disables the check (median only).
    /// @dev The source count is bounded to [1, {MAX_SOURCES}].
    function setSources(address token, IPriceOracle[] calldata oracles, uint32 minFresh, uint32 maxSpreadBps)
        external
        onlyOwner
    {
        uint256 count = oracles.length;
        if (count > MAX_SOURCES) revert TooManySources(count, MAX_SOURCES);
        if (minFresh == 0 || minFresh > count) revert InvalidQuorum(minFresh, count);
        for (uint256 i; i < count; ++i) {
            if (address(oracles[i]) == address(0)) revert ZeroSource();
        }
        Sources storage s = _sources[token];
        s.oracles = oracles;
        s.minFresh = minFresh;
        s.maxSpreadBps = maxSpreadBps;
        emit SourcesConfigured(token, count, minFresh, maxSpreadBps);
    }

    /// @notice Remove all sources for `token`; subsequent {getPriceWad} calls revert `NoSources`.
    function removeSources(address token) external onlyOwner {
        if (_sources[token].minFresh == 0) revert NoSources(token);
        delete _sources[token];
        emit SourcesRemoved(token);
    }

    /// @notice The configured component sources, quorum, and spread bound for `token`.
    function sourcesOf(address token)
        external
        view
        returns (IPriceOracle[] memory oracles, uint32 minFresh, uint32 maxSpreadBps)
    {
        Sources storage s = _sources[token];
        return (s.oracles, s.minFresh, s.maxSpreadBps);
    }

    // ---------------------------------------------------------------------
    // IPriceOracle
    // ---------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    /// @dev Median of the fresh sources; reverts if the quorum is not met or the spread is too wide.
    function getPriceWad(address token) external view returns (uint256 priceWad) {
        Sources storage s = _sources[token];
        uint256 count = s.oracles.length;
        if (count == 0) revert NoSources(token);

        uint256[] memory fresh = new uint256[](count);
        uint256 n = 0; // count of fresh (successful, non-zero) sources
        for (uint256 i; i < count; ++i) {
            try s.oracles[i].getPriceWad(token) returns (uint256 p) {
                if (p != 0) {
                    fresh[n] = p;
                    ++n;
                }
            } catch {}
        }
        if (n < s.minFresh) revert InsufficientFreshSources(token, n, s.minFresh);

        _sortPrefix(fresh, n);
        priceWad = _median(fresh, n);

        if (s.maxSpreadBps != 0) {
            uint256 spreadBps = ((fresh[n - 1] - fresh[0]) * BPS) / priceWad; // sorted: [0] min, [n-1] max
            if (spreadBps > s.maxSpreadBps) revert SpreadTooWide(token, spreadBps, s.maxSpreadBps);
        }
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev In-place insertion sort of the first `n` entries of `a`. n is bounded by the (small)
    ///      configured source count, so O(n^2) is fine and cheaper than any generic sort.
    function _sortPrefix(uint256[] memory a, uint256 n) internal pure {
        for (uint256 i = 1; i < n; ++i) {
            uint256 key = a[i];
            uint256 j = i;
            while (j != 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = key;
        }
    }

    /// @dev Median of the first `n` (already-sorted) entries. Even n averages the two middle values.
    function _median(uint256[] memory sorted, uint256 n) internal pure returns (uint256) {
        uint256 mid = n / 2;
        if (n % 2 == 1) return sorted[mid];
        return (sorted[mid - 1] + sorted[mid]) / 2;
    }
}
