import {type Address, type Hex, encodeFunctionData, keccak256, toHex} from "viem";
import {GOV_ABI} from "./abis.js";
import {apiKit, protocolKit, protocolKitPredicted, publicClient, signerAccount, walletClient} from "./clients.js";
import {config} from "./config.js";
import type {InnerCall} from "./operations.js";

export type TimelockKind = "queue" | "execute" | "cancel";

/// Derive the operation salt from a human-readable label (matches `cast keccak "<label>"`), or accept a
/// pre-computed 32-byte hex directly.
export function saltFrom(label: string): Hex {
    if (label.startsWith("0x") && label.length === 66) return label as Hex;
    return keccak256(toHex(label));
}

/// Wrap an inner call in a timelock queue/execute/cancel Safe transaction (target = the timelock).
export function wrapTimelock(kind: TimelockKind, inner: InnerCall, salt: Hex): {to: Address; data: Hex} {
    return {
        to: config.timelock(),
        data: encodeFunctionData({abi: GOV_ABI, functionName: kind, args: [inner.target, inner.data, salt]}),
    };
}

/// Deploy a new Safe with the given owners/threshold. Returns the (deterministic) Safe address.
export async function deploySafe(owners: Address[], threshold: number, saltNonce?: string): Promise<Address> {
    const kit = await protocolKitPredicted(owners, threshold, saltNonce);
    const predicted = (await kit.getAddress()) as Address;
    if (await kit.isSafeDeployed()) return predicted;
    const deployTx = await kit.createSafeDeploymentTransaction();
    const hash = await walletClient().sendTransaction({
        to: deployTx.to as Address,
        data: deployTx.data as Hex,
        value: BigInt(deployTx.value),
    });
    await publicClient().waitForTransactionReceipt({hash});
    return predicted;
}

/// Create a Safe transaction (to, data, value), sign it as the acting owner, and propose it to the Safe
/// Transaction Service. Returns the safeTxHash other owners will confirm.
export async function proposeSafeTx(safe: Address, to: Address, data: Hex, value = 0n): Promise<string> {
    const kit = await protocolKit(safe);
    const safeTx = await kit.createTransaction({transactions: [{to, data, value: value.toString()}]});
    const safeTxHash = await kit.getTransactionHash(safeTx);
    const signature = await kit.signHash(safeTxHash);
    await apiKit().proposeTransaction({
        safeAddress: safe,
        safeTransactionData: safeTx.data,
        safeTxHash,
        senderAddress: signerAccount().address,
        senderSignature: signature.data,
    });
    return safeTxHash;
}

/// Add the acting owner's confirmation to a pending Safe transaction.
export async function confirmSafeTx(safe: Address, safeTxHash: string): Promise<void> {
    const kit = await protocolKit(safe);
    const signature = await kit.signHash(safeTxHash);
    await apiKit().confirmTransaction(safeTxHash, signature.data);
}

/// Execute a fully-confirmed pending Safe transaction on-chain. Returns the ethereum tx hash.
export async function executeSafeTx(safe: Address, safeTxHash: string): Promise<string | undefined> {
    const kit = await protocolKit(safe);
    const pending = await apiKit().getTransaction(safeTxHash);
    const result = await kit.executeTransaction(pending);
    return result.hash;
}

export type PendingTx = {
    safeTxHash: string;
    to: string;
    nonce: string;
    confirmations: number;
    confirmationsRequired: number;
    isExecuted: boolean;
};

/// List pending (proposed, not-yet-executed) Safe transactions with their confirmation progress.
export async function listPending(safe: Address): Promise<PendingTx[]> {
    const pending = await apiKit().getPendingTransactions(safe);
    return pending.results.map((t) => ({
        safeTxHash: t.safeTxHash,
        to: t.to,
        nonce: t.nonce,
        confirmations: t.confirmations?.length ?? 0,
        confirmationsRequired: t.confirmationsRequired,
        isExecuted: t.isExecuted,
    }));
}

/// Read a timelocked operation's id, earliest-execution timestamp (0 = not queued), and the window it
/// stays executable for. A matured operation expires at `eta + grace` and must then be re-queued.
export async function opStatus(
    inner: InnerCall,
    salt: Hex,
): Promise<{id: Hex; eta: bigint; delay: bigint; grace: bigint}> {
    const pc = publicClient();
    const timelock = config.timelock();
    const [id, delay, grace] = await Promise.all([
        pc.readContract({address: timelock, abi: GOV_ABI, functionName: "operationId", args: [inner.target, inner.data, salt]}),
        pc.readContract({address: timelock, abi: GOV_ABI, functionName: "DELAY"}),
        pc.readContract({address: timelock, abi: GOV_ABI, functionName: "GRACE_PERIOD"}),
    ]);
    const eta = await pc.readContract({address: timelock, abi: GOV_ABI, functionName: "eta", args: [id]});
    return {id, eta, delay, grace};
}
