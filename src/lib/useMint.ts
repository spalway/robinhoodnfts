// React state around the mint: read the gate, read the balance, send the
// payment, then wait for the database to verify it against the chain.
//
// The hook reads on its own; it never sends on its own. `mint()` exists to be
// wired to a click handler, and mounting this hook, changing wallets or
// re-rendering can only ever cost an RPC read.
//
// THE ORDER OF EVENTS MATTERS AND IS NOT NEGOTIABLE:
//
//   1. Build and send one transfer of the mint price to the project wallet.
//   2. The wallet signs. Tokens leave. THIS IS THE POINT OF NO RETURN.
//   3. Post the signature to the backend, which re-reads the transaction from
//      Solana and issues a serial from what it finds there.
//
// Step 3 can fail, be slow, or be rate-limited, and NONE of those mean the mint
// failed — the money is already gone and the transaction is already on chain.
// So verification never reports 'error'; it reports 'unverified' and hands back
// the signature. A visitor cannot fix a database, and offering them a "retry"
// button next to an irreversible transfer is how a second one gets signed.
import { useCallback, useEffect, useRef, useState } from 'react'
import type { MintRequest } from './evm'
import { fetchXnftBalance, isBurnError, sendBurn, type BurnError, type TokenBalance } from './solana'
import { confirmMint, fetchMintStatus, isBackendError, type MintAssignment, type MintStatus } from './backend'

export type MintStage =
  | 'idle'
  | 'checking'
  | 'awaiting-signature'
  | 'sending'
  /** Paid and on chain. Waiting for the backend to see it. */
  | 'verifying'
  | 'done'
  | 'error'

export interface MintOutcome {
  signature: string
  assignment: MintAssignment | null
  /** True when the backend confirmed. False means paid but not yet indexed. */
  verified: boolean
  /** Present when verification is still outstanding — never an error message. */
  note: string | null
}

export interface MintState {
  stage: MintStage
  error: BurnError | null
  balance: TokenBalance | null
  status: MintStatus | null
  /**
   * Why the gate could not be read, when it could not be.
   *
   * Separate from `status` being null, and the distinction is the whole point:
   * null-and-no-error means "still loading" and null-with-an-error means "this
   * is not going to arrive". Collapsing the two left the mint page showing
   * "Reading the mint gate…" forever whenever the backend was unreachable.
   */
  statusError: string | null
  outcome: MintOutcome | null
  refresh: () => Promise<void>
  mint: (signAndSend: (request: MintRequest) => Promise<string>) => Promise<boolean>
  reset: () => void
}

/**
 * How long to keep asking the backend whether it has seen the transaction.
 *
 * Roughly a minute of increasing waits. Solana confirms in well under that, but
 * an RPC that has not caught up returns 'pending' and the right response is to
 * wait rather than to tell somebody who has paid that nothing happened.
 */
const CONFIRM_DELAYS_MS = [1200, 1800, 2500, 3500, 5000, 6000, 8000, 10000, 12000]

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export function useMint(address: string | null): MintState {
  const [stage, setStage] = useState<MintStage>('idle')
  const [error, setError] = useState<BurnError | null>(null)
  const [balance, setBalance] = useState<TokenBalance | null>(null)
  const [status, setStatus] = useState<MintStatus | null>(null)
  const [statusError, setStatusError] = useState<string | null>(null)
  const [outcome, setOutcome] = useState<MintOutcome | null>(null)

  const stageRef = useRef<MintStage>('idle')
  // One mint at a time: a double-click must not produce two irreversible sends.
  const minting = useRef(false)
  // Only the newest read may write — a slow one must not overwrite a fresh one.
  const readSeq = useRef(0)
  const alive = useRef(true)

  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const goto = useCallback((next: MintStage) => {
    stageRef.current = next
    setStage(next)
  }, [])

  const refresh = useCallback(async () => {
    const seq = ++readSeq.current

    // The gate is read even with no wallet connected: a visitor should be able
    // to see the price and the supply before deciding to connect.
    const [gate, bal] = await Promise.all([
      fetchMintStatus(address),
      address ? fetchXnftBalance(address) : Promise.resolve(null),
    ])

    if (!alive.current || seq !== readSeq.current) return

    if (isBackendError(gate)) {
      setStatusError(gate.message)
    } else {
      setStatus(gate)
      setStatusError(null)
    }
    if (bal === null) setBalance(null)
    else if (!isBurnError(bal)) setBalance(bal)
    else setBalance(null)
  }, [address])

  const reset = useCallback(() => {
    setError(null)
    setOutcome(null)
    goto('idle')
  }, [goto])

  /**
   * Ask the backend about a signature until it stops saying "not yet".
   *
   * Never throws and never reports failure. A run of retries that ends without
   * an answer resolves to `verified: false`, because the alternative — showing
   * an error over a payment that landed — is the one outcome that costs a
   * visitor real money.
   */
  const verify = useCallback(async (signature: string): Promise<MintOutcome> => {
    for (let i = 0; i <= CONFIRM_DELAYS_MS.length; i++) {
      const result = await confirmMint(signature)

      if (!isBackendError(result)) {
        if (result.status === 'confirmed' || result.status === 'duplicate') {
          return { signature, assignment: result.assignment, verified: true, note: null }
        }
        if (result.status === 'rejected') {
          // The chain says the transfer was not what the gate requires. Surfaced
          // as a note rather than swallowed — the tokens may well have moved, and
          // the operator needs the signature to work out what happened.
          return {
            signature,
            assignment: null,
            verified: false,
            note: result.message ?? 'The backend did not recognise that payment.',
          }
        }
        // 'pending' or 'busy' — keep waiting.
      }

      const delay = CONFIRM_DELAYS_MS[i]
      if (delay === undefined) break
      await sleep(delay)
      if (!alive.current) break
    }

    return {
      signature,
      assignment: null,
      verified: false,
      note: 'Your payment is on chain. The index has not caught up yet — your xployee will appear on xNET shortly.',
    }
  }, [])

  const mint = useCallback(
    async (signAndSend: (request: MintRequest) => Promise<string>): Promise<boolean> => {
      if (minting.current) return false

      if (!address) {
        setError({ code: 'no-wallet', message: 'Connect a Solana wallet before minting.' })
        goto('error')
        return false
      }

      minting.current = true
      setError(null)
      setOutcome(null)
      goto('checking')

      try {
        const sent = await sendBurn(address, async (tx) => {
          goto('awaiting-signature')
          const sig = await signAndSend(tx)
          if (alive.current) goto('sending')
          return sig
        })

        if (isBurnError(sent)) {
          if (alive.current) {
            setError(sent)
            goto('error')
          }
          return false
        }

        // Past this line the tokens are gone. Nothing below may set 'error'.
        if (alive.current) goto('verifying')
        const result = await verify(sent.signature)

        if (alive.current) {
          setOutcome(result)
          goto('done')
        }
        return true
      } finally {
        minting.current = false
        void refresh()
      }
    },
    [address, goto, refresh, verify],
  )

  // Switching wallets shows a different balance and must not inherit the
  // previous wallet's result. Reads only — this never triggers a mint.
  useEffect(() => {
    if (minting.current) return
    setError(null)
    setOutcome(null)
    stageRef.current = 'idle'
    setStage('idle')
    void refresh()
  }, [refresh])

  return { stage, error, balance, status, statusError, outcome, refresh, mint, reset }
}
