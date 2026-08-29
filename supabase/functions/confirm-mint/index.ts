// confirm-mint — did this transaction actually pay for an xployee, and if so,
// deal one.
//
// The Robinhood Chain port of the Solana verifier. The split is unchanged and
// is the part worth keeping:
//
//   here               reads the chain and decides whether a payment happened
//   xnft_issue_serial  takes (hash, buyer) and deals a serial under a lock
//
// The database function is revoked from anon and granted only to service_role,
// which never leaves this server. A browser can ask whether a payment was
// verified; it can never assert that one was.
//
// ===========================================================================
// THE ONE RULE, CARRIED OVER
// ===========================================================================
// NOT-YET IS NOT NO. A receipt that comes back null means the chain has not
// caught up — which is the normal state for the first seconds after a send, and
// is indistinguishable from a hash that never existed. Every branch that cannot
// PROVE a failure answers 'pending'. 'rejected' is reserved for a receipt whose
// status is 0x0, and for movements that are readable and provably not a mint.
//
// ===========================================================================
// WHAT GOT SIMPLER, AND WHAT GOT STRICTER
// ===========================================================================
// Simpler: an ERC-20 transfer emits a log naming sender, recipient and amount.
// There are no token accounts to attribute back to owners, so the Solana
// build's whole 'owners-unresolved' branch — its subtlest failure mode — has no
// equivalent and is gone.
//
// Stricter: addresses are compared case-insensitively. EVM addresses are
// case-insensitive but EIP-55 checksums them with mixed case, so the same
// wallet arrives as 0xAbC… from a wallet, 0xabc… from a log and 0xABC… from a
// config row. Comparing raw strings would reject a good payment because a
// letter was capitalised — a bug that would look exactly like fraud.
import { callRpc } from '../_shared/db.ts'
import { loadConfig } from '../_shared/env.ts'
import { errorResponse, isFnError, jsonResponse, readJsonBody, serveSafely } from '../_shared/http.ts'
import { mintAmount } from '../_shared/protocol.ts'
import { getDecimals, getReceipt, isEvmFailure, isTxHash, sameAddress, transfersOf } from '../_shared/evm.ts'

type Status = 'confirmed' | 'duplicate' | 'pending' | 'busy' | 'rejected'

function answer(status: Status, reason: string | null, message: string | null, buyer: string | null = null) {
  return jsonResponse({
    ok: status === 'confirmed' || status === 'duplicate',
    status,
    reason,
    message,
    buyer,
    assignment: null,
  })
}

Deno.serve(
  serveSafely(async (request: Request): Promise<Response> => {
    const body = await readJsonBody(request)
    if (isFnError(body)) return errorResponse(body)

    const config = loadConfig()
    if (isFnError(config)) return errorResponse(config)

    // `signature` is the field name the frontend has always posted. It carries
    // a 0x transaction hash now; renaming it would have been churn in files
    // this port had no other reason to touch.
    const hash = typeof body.signature === 'string' ? body.signature.trim() : ''
    if (!hash || !isTxHash(hash)) {
      return answer('rejected', 'bad-request', 'That is not a transaction hash.')
    }

    // ---- Did it land? ----------------------------------------------------
    const receipt = await getReceipt(config.rpcUrl, hash)
    if (isEvmFailure(receipt)) {
      return answer('pending', 'rpc-unavailable', 'Could not reach the chain to check. Nothing was written — try again.')
    }
    if (receipt === null) {
      return answer('pending', 'not-seen', 'The chain has not caught up to that transaction yet. Keep the hash.')
    }
    if (receipt.status !== '0x1') {
      // The one thing the chain itself calls a failure. Nothing moved.
      return answer('rejected', 'transaction-failed', 'That transaction reverted. No tokens moved.')
    }

    // ---- What moved? -----------------------------------------------------
    const legs = transfersOf(receipt, config.xnftMint)

    if (legs.length === 0) {
      return answer('rejected', 'not-a-mint', 'That transaction moved no $XCs. Nothing was written.')
    }
    if (legs.length > 1) {
      // A mint is exactly one transfer. Guessing which leg was "the payment" is
      // how some other shape gets credited as a mint.
      return answer('rejected', 'not-a-mint', `That transaction moved $XCs in ${legs.length} transfers. A mint is exactly one.`)
    }

    const leg = legs[0]
    if (!sameAddress(leg.to, config.devWallet)) {
      return answer('rejected', 'wrong-destination', 'That $XCs did not go to the project wallet. Nothing was written.')
    }
    if (sameAddress(leg.from, config.devWallet)) {
      return answer('rejected', 'not-a-mint', 'That transfer has no payer distinct from the project wallet.')
    }

    // ---- Was it the right amount? ----------------------------------------
    //
    // Read off the token rather than assumed, then checked for EQUALITY. Not a
    // minimum: somebody sending more is not buying two xployees, and somebody
    // sending less is not buying a cheaper one.
    const decimals = await getDecimals(config.rpcUrl, config.xnftMint)
    if (isEvmFailure(decimals)) {
      return answer('pending', 'unreadable', 'Could not read the token decimals. Nothing was written — try again.')
    }
    const expected = mintAmount(decimals)
    if (expected === null) {
      return answer('rejected', 'implausible-decimals', '$XCs reports an implausible decimal count, so no price can be checked.')
    }
    if (leg.amount !== expected) {
      return answer('rejected', 'wrong-amount', 'That transfer is not the mint price. Nothing was written.')
    }

    // ---- Deal a serial ---------------------------------------------------
    //
    // Past this line the payment is proven. Everything below reports how the
    // ISSUING went, and a failure here must never be presented as a failed
    // payment — the money has moved either way.
    const issued = await callRpc<Record<string, unknown>>(config, 'xnft_issue_serial', {
      p_signature: hash.toLowerCase(),
      p_buyer: leg.from,
      p_paid_raw: expected.toString(),
    })

    if (isFnError(issued)) {
      return answer(
        'pending',
        'index-unavailable',
        'Your payment is verified but the index did not record it yet. Keep this hash — retrying is safe.',
        leg.from,
      )
    }

    return jsonResponse(issued)
  }),
)
