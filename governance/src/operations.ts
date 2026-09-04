import {type Address, type Hex, encodeFunctionData, getAddress} from "viem";
import {GOV_ABI, MINTER_ROLE} from "./abis.js";
import {config} from "./config.js";

export type InnerCall = {
    target: Address;
    data: Hex;
    description: string;
    /** true = must go through the timelock (queue/wait/execute); false = a direct Safe call. */
    timelocked: boolean;
};

// --- argument coercion from CLI strings ---
function addr(s: string | undefined, label: string): Address {
    if (!s) throw new Error(`missing address argument: ${label}`);
    return getAddress(s);
}
function bool(s: string | undefined, label: string): boolean {
    if (s === "true") return true;
    if (s === "false") return false;
    throw new Error(`expected true|false for ${label}, got: ${s}`);
}
function u(s: string | undefined, label: string): bigint {
    if (s === undefined) throw new Error(`missing numeric argument: ${label}`);
    return BigInt(s);
}
function addrList(s: string | undefined, label: string): Address[] {
    if (!s) throw new Error(`missing address list: ${label}`);
    return s.split(",").map((x) => getAddress(x.trim()));
}

type Op = {help: string; build: (a: string[]) => InnerCall};

/// The full operation catalogue. Each builder returns the INNER call; the CLI decides whether to wrap it
/// in the timelock (queue/execute/cancel) or send it directly, based on `timelocked`.
export const OPERATIONS: Record<string, Op> = {
    "accept-ownership": {
        help: "accept-ownership                          engine.acceptOwnership() (post-deploy handoff)",
        build: () => ({
            target: config.engine(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "acceptOwnership"}),
            description: "engine.acceptOwnership()",
            timelocked: true,
        }),
    },
    "set-collateral": {
        help: "set-collateral <token> <enabled> <rateBps> [oracle=MEDIAN]   list / reconfigure a flavor",
        build: (a) => {
            const token = addr(a[0], "token");
            const enabled = bool(a[1], "enabled");
            const rate = u(a[2], "redeemRateBps");
            const oracle = a[3] ? addr(a[3], "oracle") : config.median();
            return {
                target: config.engine(),
                data: encodeFunctionData({abi: GOV_ABI, functionName: "setCollateral", args: [token, enabled, Number(rate), oracle]}),
                description: `engine.setCollateral(${token}, ${enabled}, ${rate}, ${oracle})`,
                timelocked: true,
            };
        },
    },
    "set-collateral-enabled": {
        help: "set-collateral-enabled <token> <enabled>  enable/disable (incl. un-freeze)",
        build: (a) => {
            const token = addr(a[0], "token");
            const enabled = bool(a[1], "enabled");
            return {
                target: config.engine(),
                data: encodeFunctionData({abi: GOV_ABI, functionName: "setCollateralEnabled", args: [token, enabled]}),
                description: `engine.setCollateralEnabled(${token}, ${enabled})`,
                timelocked: true,
            };
        },
    },
    "remove-collateral": {
        help: "remove-collateral <token> <maxResidualUnits>   remove a retired flavor (disabled; strands at most this much dust)",
        build: (a) => {
            const token = addr(a[0], "token");
            const maxResidual = u(a[1], "maxResidualUnits");
            return {
                target: config.engine(),
                data: encodeFunctionData({abi: GOV_ABI, functionName: "removeCollateral", args: [token, maxResidual]}),
                description: `engine.removeCollateral(${token}, ${maxResidual})`,
                timelocked: true,
            };
        },
    },
    "set-backing-excluded": {
        help: "set-backing-excluded <token> <excluded>   silo / un-silo a stuck flavor",
        build: (a) => {
            const token = addr(a[0], "token");
            const excluded = bool(a[1], "excluded");
            return {
                target: config.engine(),
                data: encodeFunctionData({abi: GOV_ABI, functionName: "setCollateralBackingExcluded", args: [token, excluded]}),
                description: `engine.setCollateralBackingExcluded(${token}, ${excluded})`,
                timelocked: true,
            };
        },
    },
    "set-tilt": {
        help: "set-tilt <slopeBps>                       setTiltSlopeBps (<= 5000)",
        build: (a) => ({
            target: config.engine(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "setTiltSlopeBps", args: [Number(u(a[0], "slopeBps"))]}),
            description: `engine.setTiltSlopeBps(${a[0]})`,
            timelocked: true,
        }),
    },
    "set-margin": {
        help: "set-margin <totalBps> <toRecipientBps>    setRedeemMargin (total <= 5, routed <= total)",
        build: (a) => ({
            target: config.engine(),
            data: encodeFunctionData({
                abi: GOV_ABI,
                functionName: "setRedeemMargin",
                args: [Number(u(a[0], "totalBps")), Number(u(a[1], "toRecipientBps"))],
            }),
            description: `engine.setRedeemMargin(${a[0]}, ${a[1]})`,
            timelocked: true,
        }),
    },
    "set-margin-recipient": {
        help: "set-margin-recipient <address>            setMarginRecipient (0x0 = keep routed part pooled)",
        build: (a) => ({
            target: config.engine(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "setMarginRecipient", args: [addr(a[0], "recipient")]}),
            description: `engine.setMarginRecipient(${a[0]})`,
            timelocked: true,
        }),
    },
    "set-stale-params": {
        help: "set-stale-params <graceSecs> <haircutBps> setStalePriceParams (grace <= 1 day)",
        build: (a) => ({
            target: config.engine(),
            data: encodeFunctionData({
                abi: GOV_ABI,
                functionName: "setStalePriceParams",
                args: [Number(u(a[0], "graceSeconds")), Number(u(a[1], "haircutBps"))],
            }),
            description: `engine.setStalePriceParams(${a[0]}, ${a[1]})`,
            timelocked: true,
        }),
    },
    "set-guardian": {
        help: "set-guardian <address>                    setGuardian",
        build: (a) => ({
            target: config.engine(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "setGuardian", args: [addr(a[0], "newGuardian")]}),
            description: `engine.setGuardian(${a[0]})`,
            timelocked: true,
        }),
    },
    "grant-minter": {
        help: "grant-minter <account>                    token.grantRole(MINTER_ROLE, account)",
        build: (a) => ({
            target: config.token(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "grantRole", args: [MINTER_ROLE, addr(a[0], "account")]}),
            description: `token.grantRole(MINTER_ROLE, ${a[0]})`,
            timelocked: true,
        }),
    },
    "revoke-minter": {
        help: "revoke-minter <account>                   token.revokeRole(MINTER_ROLE, account)",
        build: (a) => ({
            target: config.token(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "revokeRole", args: [MINTER_ROLE, addr(a[0], "account")]}),
            description: `token.revokeRole(MINTER_ROLE, ${a[0]})`,
            timelocked: true,
        }),
    },
    "set-feed": {
        help: "set-feed <provider> <token> <agg> <maxStaleness> <maxWad>   point a provider at a Chainlink feed",
        build: (a) => ({
            target: addr(a[0], "provider"),
            data: encodeFunctionData({
                abi: GOV_ABI,
                functionName: "setFeed",
                args: [addr(a[1], "token"), addr(a[2], "aggregator"), Number(u(a[3], "maxStaleness")), u(a[4], "maxPriceWad")],
            }),
            description: `provider(${a[0]}).setFeed(${a[1]}, ${a[2]}, ${a[3]}, ${a[4]})`,
            timelocked: true,
        }),
    },
    "remove-feed": {
        help: "remove-feed <provider> <token>            remove a provider feed",
        build: (a) => ({
            target: addr(a[0], "provider"),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "removeFeed", args: [addr(a[1], "token")]}),
            description: `provider(${a[0]}).removeFeed(${a[1]})`,
            timelocked: true,
        }),
    },
    "set-sources": {
        help: "set-sources <token> <p1,p2,...> <minFresh> <maxSpreadBps>   median.setSources",
        build: (a) => ({
            target: config.median(),
            data: encodeFunctionData({
                abi: GOV_ABI,
                functionName: "setSources",
                args: [addr(a[0], "token"), addrList(a[1], "sources"), Number(u(a[2], "minFresh")), Number(u(a[3], "maxSpreadBps"))],
            }),
            description: `median.setSources(${a[0]}, [${a[1]}], ${a[2]}, ${a[3]})`,
            timelocked: true,
        }),
    },
    "remove-sources": {
        help: "remove-sources <token>                    median.removeSources",
        build: (a) => ({
            target: config.median(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "removeSources", args: [addr(a[0], "token")]}),
            description: `median.removeSources(${a[0]})`,
            timelocked: true,
        }),
    },
    freeze: {
        help: "freeze <token>                            [DIRECT, guardian Safe] engine.freezeCollateral(token)",
        build: (a) => ({
            target: config.engine(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "freezeCollateral", args: [addr(a[0], "token")]}),
            description: `engine.freezeCollateral(${a[0]})`,
            timelocked: false,
        }),
    },
    "set-sequencer-feed": {
        help: "set-sequencer-feed <provider> <feed> <graceSecs>   L2 sequencer uptime gate (0x0 to clear on L1)",
        build: (a) => ({
            target: addr(a[0], "provider"),
            data: encodeFunctionData({
                abi: GOV_ABI,
                functionName: "setSequencerFeed",
                args: [addr(a[1], "sequencerFeed"), Number(u(a[2], "gracePeriod"))],
            }),
            description: `provider(${a[0]}).setSequencerFeed(${a[1]}, ${a[2]})`,
            timelocked: true,
        }),
    },
    // --- direct ops (no timelock wrap) ---
    "poke-distress": {
        help: "poke-distress                             [DIRECT, anyone] engine.pokeDistress() — advance the recovery clock",
        build: () => ({
            target: config.engine(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "pokeDistress"}),
            description: "engine.pokeDistress()  (starts/advances the distress recovery countdown)",
            timelocked: false,
        }),
    },
    "initiate-renounce": {
        help: "initiate-renounce                         [DIRECT, gov Safe] timelock.initiateRenounce() — starts the TERMINAL countdown",
        build: () => ({
            target: config.timelock(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "initiateRenounce"}),
            description: "timelock.initiateRenounce()  (step 1 of 2; waits DELAY, abortable)",
            timelocked: false,
        }),
    },
    "abort-renounce": {
        help: "abort-renounce                            [DIRECT, gov Safe] timelock.abortRenounce()",
        build: () => ({
            target: config.timelock(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "abortRenounce"}),
            description: "timelock.abortRenounce()",
            timelocked: false,
        }),
    },
    "renounce-executor": {
        help: "renounce-executor                         [DIRECT, gov Safe] timelock.renounceExecutor() — TERMINAL, needs initiate-renounce + DELAY",
        build: () => ({
            target: config.timelock(),
            data: encodeFunctionData({abi: GOV_ABI, functionName: "renounceExecutor"}),
            description: "timelock.renounceExecutor()  (step 2 of 2; freezes all parameters forever)",
            timelocked: false,
        }),
    },
};

export function buildOp(name: string, args: string[]): InnerCall {
    const op = OPERATIONS[name];
    if (!op) {
        throw new Error(`unknown operation "${name}". Run \`npm run gov -- help\` for the catalogue.`);
    }
    return op.build(args);
}
