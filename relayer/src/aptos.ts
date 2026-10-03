import {
  Aptos,
  AptosConfig,
  Network,
  Account,
  Ed25519PrivateKey,
  Hex,
  type MoveVector,
} from "@aptos-labs/ts-sdk";

export function createAptos(nodeUrl: string): Aptos {
  return new Aptos(new AptosConfig({ network: Network.CUSTOM, fullnode: nodeUrl }));
}

export function relayerAccount(privateKeyHex: string): Account {
  let hex = privateKeyHex.startsWith("0x") ? privateKeyHex.slice(2) : privateKeyHex;
  if (hex.startsWith("ed25519-private:0x")) hex = hex.slice("ed25519-private:0x".length);
  return Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(`0x${hex}`) });
}

/// Submit bridge::mint_attested as the relayer.
/// moduleAddr: where okrw_bridge modules are published (publisher address).
/// (Config/Seen are found via the relayer signer inside the Move function.)
export type MintStage = "submitting" | "confirming";

export async function mintAttested(
  aptos: Aptos,
  relayer: Account,
  moduleAddr: string,
  metadata: string, // OKRW metadata object address
  recipient: string, // 0x aptos address
  amount: bigint,
  marooNonce: bigint,
  onStage?: (s: MintStage) => void,
) {
  onStage?.("submitting");
  const txn = await aptos.transaction.build.simple({
    sender: relayer.accountAddress,
    data: {
      function: `${moduleAddr}::bridge::mint_attested` as `${string}::${string}::${string}`,
      functionArguments: [metadata, recipient, amount.toString(), marooNonce.toString()],
    },
  });
  const r = await aptos.signAndSubmitTransaction({ signer: relayer, transaction: txn });
  onStage?.("confirming");
  return aptos.waitForTransaction({ transactionHash: r.hash });
}

/// Submit bridge::burn_withdraw as the relayer (step 2 of withdraw).
/// Config is located via the relayer signer on-chain (canonical); bridgeAddr
/// is only used off-chain for event queries.
export async function burnWithdraw(
  aptos: Aptos,
  relayer: Account,
  moduleAddr: string,
  metadata: string,
  from: string, // original depositor, for the event trail
  amount: bigint,
  marooRecipient: string, // 0x 20-byte EVM address -> passed as vector<u8>
) {
  const recipientBytes = Array.from(Hex.fromHexString(marooRecipient).toUint8Array());
  const txn = await aptos.transaction.build.simple({
    sender: relayer.accountAddress,
    data: {
      function: `${moduleAddr}::bridge::burn_withdraw` as `${string}::${string}::${string}`,
      functionArguments: [metadata, from, amount.toString(), recipientBytes],
    },
  });
  const r = await aptos.signAndSubmitTransaction({ signer: relayer, transaction: txn });
  return aptos.waitForTransaction({ transactionHash: r.hash });
}

/// Read OKRW primary-store balance (0 if no store). Uses the on-chain
/// `primary_fungible_store::balance` view and BigInts the raw string:
/// `getAccountCoinAmount` routes through a path that float-rounds large
/// u64s (observed: ...016 returned as ...000), which breaks wei-exact
/// conservation checks.
export async function okrwBalance(
  aptos: Aptos,
  owner: string,
  metadata: string,
): Promise<bigint> {
  try {
    const res = await aptos.view({
      payload: {
        function: "0x1::primary_fungible_store::balance",
        typeArguments: ["0x1::fungible_asset::Metadata"],
        functionArguments: [owner, metadata],
      },
    });
    return BigInt((res as unknown as string[])[0] ?? "0");
  } catch {
    return 0n;
  }
}

/// Fetch WithdrawInitiated events for the relayer to process.
export async function getWithdrawEvents(aptos: Aptos, bridgeAddr: string) {
  return aptos.getEvents({
    options: {
      where: {
        event_type: { _eq: `${bridgeAddr}::bridge::WithdrawInitiated` },
      },
      order_by: [{ transaction_version: "asc" as const }],
    },
  } as any);
}

export type { MoveVector };
