import {type Address, getAddress} from "viem";
import {config} from "./config.js";
import {OPERATIONS, buildOp} from "./operations.js";
import {
    confirmSafeTx,
    deploySafe,
    executeSafeTx,
    listPending,
    opStatus,
    proposeSafeTx,
    saltFrom,
    wrapTimelock,
} from "./safeFlows.js";

type Flags = Record<string, string | boolean>;

function parseArgs(argv: string[]): {positionals: string[]; flags: Flags} {
    const positionals: string[] = [];
    const flags: Flags = {};
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith("--")) {
            const key = a.slice(2);
            const next = argv[i + 1];
            if (next === undefined || next.startsWith("--")) flags[key] = true;
            else {
                flags[key] = next;
                i++;
            }
        } else {
            positionals.push(a);
        }
    }
    return {positionals, flags};
}

function str(flags: Flags, key: string): string | undefined {
    const v = flags[key];
    return typeof v === "string" ? v : undefined;
}

function resolveSafe(v: string | undefined, fallback: () => Address): Address {
    if (!v) return fallback();
    if (v === "gov") return config.govSafe();
    if (v === "guardian") return config.guardianSafe();
    return getAddress(v);
}

function requireSalt(flags: Flags): string {
    const s = str(flags, "salt");
    if (!s) throw new Error("this command requires --salt <label> (a unique tag; reuse it for execute/cancel)");
    return s;
}

function fmtEta(eta: bigint): string {
    if (eta === 0n) return "not queued";
    return `${eta} (${new Date(Number(eta) * 1000).toISOString()})`;
}

const HELP = `SumUSD governance — API-driven Safe multisig tooling

Usage: npm run gov -- <command> [args] [--flags]

Multisig lifecycle for a governance change:
  1) one owner proposes          gov queue <op> [args] --salt <label>
  2) other owners confirm        gov confirm <safeTxHash>
  3) any owner executes          gov exec <safeTxHash>
  4) wait >= the timelock delay, then repeat with: gov execute <op> [args] --salt <label>

Commands:
  deploy-safe --owners a,b,c --threshold N [--salt-nonce X]   deploy a new Safe
  queue    <op> [args] --salt <label>       propose timelock.queue(op)   from the gov Safe
  execute  <op> [args] --salt <label>       propose timelock.execute(op) from the gov Safe (after delay)
  cancel   <op> [args] --salt <label>       propose timelock.cancel(op)  from the gov Safe
                                           (add --safe <cancellerSafe> to veto from the guardian Safe)
  direct   <op> [args] [--safe gov|guardian|0x..]   propose a direct (non-timelocked) Safe call
  status   <op> [args] --salt <label>       read the operation id + eta from the timelock
  encode   <op> [args]                      print the inner call (target + calldata), no proposal
  confirm  <safeTxHash> [--safe gov|guardian|0x..]  add your confirmation to a pending Safe tx
  exec     <safeTxHash> [--safe gov|guardian|0x..]  execute a fully-confirmed pending Safe tx
  list     [--safe gov|guardian|0x..]       list pending Safe txs + confirmation progress
  help                                      show this message

Operations (op names for queue/execute/cancel/direct/encode/status):
${Object.values(OPERATIONS)
    .map((o) => `  ${o.help}`)
    .join("\n")}
`;

async function main() {
    const {positionals, flags} = parseArgs(process.argv.slice(2));
    const command = positionals[0];

    switch (command) {
        case undefined:
        case "help":
            console.log(HELP);
            return;

        case "deploy-safe": {
            const ownersStr = str(flags, "owners");
            const thresholdStr = str(flags, "threshold");
            if (!ownersStr || !thresholdStr) throw new Error("deploy-safe requires --owners a,b,c and --threshold N");
            const owners = ownersStr.split(",").map((o) => getAddress(o.trim()));
            const threshold = Number(thresholdStr);
            if (threshold < 1 || threshold > owners.length) throw new Error("threshold must be between 1 and the owner count");
            console.log(`Deploying Safe: ${threshold}-of-${owners.length}`);
            owners.forEach((o) => console.log(`  owner ${o}`));
            const safe = await deploySafe(owners, threshold, str(flags, "salt-nonce"));
            console.log(`Safe address: ${safe}`);
            return;
        }

        case "queue":
        case "execute":
        case "cancel": {
            const op = buildOp(positionals[1], positionals.slice(2));
            if (!op.timelocked) throw new Error(`"${positionals[1]}" is a direct op; use \`gov direct ${positionals[1]}\` instead`);
            const salt = saltFrom(requireSalt(flags));
            const wrapped = wrapTimelock(command, op, salt);
            // cancel is the one operation the CANCELLER Safe may also send, so it accepts --safe. This is
            // the veto path: if the gov Safe is compromised, the guardian Safe kills its queued op inside
            // the delay window without ever being able to queue or execute anything itself.
            const proposer =
                command === "cancel" ? resolveSafe(str(flags, "safe"), () => config.govSafe()) : config.govSafe();
            console.log(`Inner: ${op.description}`);
            console.log(`Safe tx: timelock.${command}(${op.target}, <data>, ${salt}) from ${proposer}`);
            const safeTxHash = await proposeSafeTx(proposer, wrapped.to, wrapped.data);
            console.log(`Proposed. safeTxHash: ${safeTxHash}`);
            console.log(`Next: other owners run \`gov confirm ${safeTxHash}\`, then \`gov exec ${safeTxHash}\`.`);
            return;
        }

        case "direct": {
            const op = buildOp(positionals[1], positionals.slice(2));
            const fallbackSafe = () => (positionals[1] === "freeze" ? config.guardianSafe() : config.govSafe());
            const safe = resolveSafe(str(flags, "safe"), fallbackSafe);
            console.log(`Direct: ${op.description}`);
            console.log(`Safe tx: call ${op.target} directly from ${safe}`);
            const safeTxHash = await proposeSafeTx(safe, op.target, op.data);
            console.log(`Proposed. safeTxHash: ${safeTxHash}`);
            console.log(`Next: other owners run \`gov confirm ${safeTxHash} --safe ${safe}\`, then \`gov exec ${safeTxHash} --safe ${safe}\`.`);
            return;
        }

        case "status": {
            const op = buildOp(positionals[1], positionals.slice(2));
            const salt = saltFrom(requireSalt(flags));
            const {id, eta, delay, grace} = await opStatus(op, salt);
            console.log(`Operation: ${op.description}`);
            console.log(`  id:    ${id}`);
            console.log(`  eta:   ${fmtEta(eta)}`);
            console.log(`  delay: ${delay}s`);
            console.log(`  grace: ${grace}s`);
            if (eta !== 0n) {
                const now = BigInt(Math.floor(Date.now() / 1000));
                const expiresAt = eta + grace;
                console.log(`  expires: ${fmtEta(expiresAt)}`);
                if (now > expiresAt) console.log("  EXPIRED - re-queue it (a new salt is not required)");
                else if (now >= eta) console.log("  READY to execute");
                else console.log("  waiting for the delay to elapse");
            }
            return;
        }

        case "encode": {
            const op = buildOp(positionals[1], positionals.slice(2));
            console.log(`Description: ${op.description}`);
            console.log(`Timelocked: ${op.timelocked}`);
            console.log(`Target:     ${op.target}`);
            console.log(`Data:       ${op.data}`);
            return;
        }

        case "confirm": {
            const safeTxHash = positionals[1];
            if (!safeTxHash) throw new Error("confirm requires a <safeTxHash>");
            const safe = resolveSafe(str(flags, "safe"), config.govSafe);
            await confirmSafeTx(safe, safeTxHash);
            console.log(`Confirmed ${safeTxHash} on ${safe}.`);
            return;
        }

        case "exec": {
            const safeTxHash = positionals[1];
            if (!safeTxHash) throw new Error("exec requires a <safeTxHash>");
            const safe = resolveSafe(str(flags, "safe"), config.govSafe);
            const hash = await executeSafeTx(safe, safeTxHash);
            console.log(`Executed ${safeTxHash}. Ethereum tx: ${hash ?? "(pending)"}`);
            return;
        }

        case "list": {
            const safe = resolveSafe(str(flags, "safe"), config.govSafe);
            const pending = await listPending(safe);
            if (pending.length === 0) {
                console.log(`No pending transactions on ${safe}.`);
                return;
            }
            console.log(`Pending on ${safe}:`);
            for (const t of pending) {
                console.log(
                    `  ${t.safeTxHash}  nonce=${t.nonce}  to=${t.to}  ${t.confirmations}/${t.confirmationsRequired} confirmed${t.isExecuted ? "  [executed]" : ""}`,
                );
            }
            return;
        }

        default:
            throw new Error(`unknown command "${command}". Run \`npm run gov -- help\`.`);
    }
}

main().catch((err: unknown) => {
    console.error(`Error: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
});
