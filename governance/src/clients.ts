import SafeApiKit from "@safe-global/api-kit";
import Safe from "@safe-global/protocol-kit";
import {type Address, type Chain, createPublicClient, createWalletClient, defineChain, http} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {config} from "./config.js";

/// A minimal viem chain built from CHAIN_ID + RPC_URL (we only need id + transport for reads and for
/// broadcasting the Safe-deployment transaction).
export function chain(): Chain {
    const id = Number(config.chainId());
    return defineChain({
        id,
        name: `chain-${id}`,
        nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
        rpcUrls: {default: {http: [config.rpcUrl()]}},
    });
}

export function signerAccount() {
    return privateKeyToAccount(config.signerKey());
}

export function publicClient() {
    return createPublicClient({chain: chain(), transport: http(config.rpcUrl())});
}

export function walletClient() {
    return createWalletClient({account: signerAccount(), chain: chain(), transport: http(config.rpcUrl())});
}

/// Safe Transaction Service client (propose / confirm / list / fetch for execution).
export function apiKit(): SafeApiKit {
    return new SafeApiKit({chainId: config.chainId(), apiKey: config.apiKey(), txServiceUrl: config.txServiceUrl()});
}

/// Protocol Kit connected to an existing Safe, acting as the configured signer.
export function protocolKit(safeAddress: Address): Promise<Safe> {
    return Safe.init({provider: config.rpcUrl(), signer: config.signerKey(), safeAddress});
}

/// Protocol Kit for a not-yet-deployed Safe (used only to predict its address and build the deploy tx).
export function protocolKitPredicted(owners: Address[], threshold: number, saltNonce?: string): Promise<Safe> {
    return Safe.init({
        provider: config.rpcUrl(),
        signer: config.signerKey(),
        predictedSafe: {
            safeAccountConfig: {owners, threshold},
            safeDeploymentConfig: saltNonce ? {saltNonce} : undefined,
        },
    });
}
