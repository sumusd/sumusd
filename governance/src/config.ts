import {readFileSync} from "node:fs";
import {type Address, type Hex, isAddress} from "viem";

// Minimal .env loader (no dependency): load governance/.env into process.env if present, without
// overriding anything already set in the environment.
function loadDotenv(): void {
    let text: string;
    try {
        text = readFileSync(new URL("../.env", import.meta.url), "utf8");
    } catch {
        return; // no .env file — rely on the ambient environment
    }
    for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("#")) continue;
        const eq = trimmed.indexOf("=");
        if (eq === -1) continue;
        const key = trimmed.slice(0, eq).trim();
        let val = trimmed.slice(eq + 1).trim();
        if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
            val = val.slice(1, -1);
        }
        if (process.env[key] === undefined) process.env[key] = val;
    }
}
loadDotenv();

function req(name: string): string {
    const v = process.env[name];
    if (!v) throw new Error(`Missing required env var ${name} (set it in governance/.env or the environment)`);
    return v;
}
function opt(name: string): string | undefined {
    return process.env[name] || undefined;
}
function reqAddr(name: string): Address {
    const v = req(name);
    if (!isAddress(v)) throw new Error(`${name} is not a valid address: ${v}`);
    return v;
}

/// Every getter is lazy, so a command only requires the env vars it actually uses.
export const config = {
    rpcUrl: () => req("RPC_URL"),
    chainId: () => BigInt(req("CHAIN_ID")),
    signerKey: () => req("SIGNER_KEY") as Hex, // the acting owner's private key (proposing / confirming / executing)
    apiKey: () => opt("SAFE_API_KEY"), // Safe Transaction Service key (required for the hosted safe.global service)
    txServiceUrl: () => opt("SAFE_TX_SERVICE_URL"), // optional self-hosted Transaction Service URL
    govSafe: () => reqAddr("GOV_SAFE"), // governance Safe = the timelock executor
    guardianSafe: () => reqAddr("GUARDIAN_SAFE"), // guardian Safe (instant freeze only)
    timelock: () => reqAddr("TIMELOCK"),
    engine: () => reqAddr("ENGINE"),
    token: () => reqAddr("TOKEN"),
    median: () => reqAddr("MEDIAN"),
};
