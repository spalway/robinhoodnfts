// The mint, under the names the UI already speaks.
//
// A thin adapter over ./evm, and the filename is a deliberate lie kept for one
// release: `useMint`, `MintGate` and `Mint.tsx` import `./solana`, and pointing
// them somewhere else is churn in files this port had no other reason to touch.
// What is behind it is Robinhood Chain, and every symbol below says so.
//
// The whole Solana surface this used to wrap — associated token accounts,
// transferChecked, blockhash expiry, confirmation polling — is gone. An EVM
// transfer is one call and one hash, and whether it landed is the verifier's
// question, not the browser's.
import {
  MINT_COST,
  buildMintRequest,
  explorerTx as evmExplorerTx,
  fetchTokenBalance,
  isEvmError,
  isMintConfigured,
  sendMint,
  type EvmError,
  type MintRequest,
  type TokenBalance,
} from './evm'

export { DEFAULT_RPC, CHAIN_ID, CHAIN_NAME, tokenAddress as xnftMintAddress } from './evm'
export { MINT_COST }
export type { TokenBalance, MintRequest }

/**
 * Where a mint's proceeds go.
 *
 * On Solana this was the incinerator and the copy said "burn". It is the
 * project wallet now and nothing is destroyed — the same change the Solana
 * build made before it, kept here so no copy can drift back into claiming a
 * burn that does not happen.
 */
export { projectWallet as BURN_ADDRESS_FN } from './evm'

export type BurnStage = 'idle' | 'checking' | 'awaiting-signature' | 'confirming' | 'done' | 'error'

/** The UI's error shape. Identical to EvmError — aliased, not re-wrapped. */
export type BurnError = EvmError

export function isBurnError(v: unknown): v is BurnError {
  return isEvmError(v)
}

export function isBurnConfigured(): boolean {
  return isMintConfigured()
}

export function explorerTx(hash: string): string {
  return evmExplorerTx(hash)
}

export type BurnOptions = { endpoint?: string }

export async function fetchXnftBalance(
  owner: string,
  endpoint?: string,
): Promise<TokenBalance | BurnError> {
  return fetchTokenBalance(owner, endpoint)
}

export async function buildBurnTransaction(
  owner: string,
  options: BurnOptions = {},
): Promise<MintRequest | BurnError> {
  return buildMintRequest(owner, options.endpoint)
}

/**
 * Signs and sends the mint.
 *
 * Returns `{ signature }` rather than `{ hash }` so `useMint` — which posts the
 * value straight to the verifier and never inspects it — needs no change. The
 * verifier accepts a 0x hash; the field name is the only thing that stayed
 * Solana-shaped.
 */
export async function sendBurn(
  owner: string,
  signAndSend: (request: MintRequest) => Promise<string>,
  options: BurnOptions = {},
): Promise<{ signature: string } | BurnError> {
  const result = await sendMint(owner, signAndSend, options.endpoint)
  return isEvmError(result) ? result : { signature: result.hash }
}
