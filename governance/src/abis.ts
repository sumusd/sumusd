import {parseAbi} from "viem";

/// The privileged functions this toolkit encodes: the timelock's queue/execute/cancel plus every inner
/// call from the governance runbook (engine, token, oracle adapters). Human-readable, parsed by viem.
export const GOV_ABI = parseAbi([
    // --- ImmutableTimelock (the Safe calls these as the executor) ---
    "function queue(address target, bytes data, bytes32 salt) returns (bytes32)",
    "function execute(address target, bytes data, bytes32 salt) returns (bytes)",
    "function cancel(address target, bytes data, bytes32 salt)",
    "function operationId(address target, bytes data, bytes32 salt) pure returns (bytes32)",
    "function eta(bytes32 id) view returns (uint256)",
    "function executor() view returns (address)",
    "function DELAY() view returns (uint256)",
    "function GRACE_PERIOD() view returns (uint256)",
    "function CANCELLER() view returns (address)",
    "function renounceEta() view returns (uint256)",
    "function initiateRenounce()",
    "function abortRenounce()",
    "function renounceExecutor()",
    // --- SumUSDEngine (inner calls, wrapped in the timelock; freezeCollateral is a direct guardian call) ---
    "function acceptOwnership()",
    "function setCollateral(address token, bool enabled, uint16 redeemRateBps, address oracle)",
    "function setCollateralEnabled(address token, bool enabled)",
    "function removeCollateral(address token, uint256 maxResidualUnits)",
    "function setCollateralBackingExcluded(address token, bool excluded)",
    "function setTiltSlopeBps(uint16 slope)",
    "function setRedeemMargin(uint16 totalBps, uint16 toRecipientBps)",
    "function setMarginRecipient(address recipient)",
    "function setStalePriceParams(uint32 graceSeconds, uint16 haircutBps)",
    "function setGuardian(address newGuardian)",
    "function freezeCollateral(address token)",
    "function pokeDistress()",
    // --- SumUSD token (roles) ---
    "function grantRole(bytes32 role, address account)",
    "function revokeRole(bytes32 role, address account)",
    // --- ChainlinkOracleAdapter (a provider) ---
    "function setFeed(address token, address aggregator, uint32 maxStaleness, uint128 maxPriceWad)",
    "function removeFeed(address token)",
    "function setSequencerFeed(address feed, uint32 gracePeriod)",
    // --- MedianOracleAdapter ---
    "function setSources(address token, address[] sources, uint32 minFresh, uint32 maxSpreadBps)",
    "function removeSources(address token)",
]);

/// keccak256("MINTER_ROLE") — the only role the token grants/revokes in practice.
export const MINTER_ROLE = "0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6" as const;
