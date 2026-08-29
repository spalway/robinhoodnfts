import type { ReactNode } from 'react'
import { Chip, Button, Money } from './ui'
import { useMint } from '../lib/useMint'
import { explorerTx, isBurnError, type BurnError } from '../lib/solana'
import { MINT_BURN, fromRawUnits, mintAmount } from '../lib/fees'
import { useWallet } from '../lib/wallet'
import { num, shortAddress } from '../lib/format'

/**
 * The paywall in front of minting: one transfer of the mint price to the project
 * wallet, under one signature.
 *
 * This is the only component in the app that moves real value, so it is
 * deliberately blunt about it. Nothing fires without a click, and the amount and
 * the destination are on screen before the button.
 *
 * There is no simulated fallback. There used to be one — a free "Hire xployee
 * (simulated)" button rendered whenever the mint was unconfigured — and it sat
 * one element away from a live transfer button, looking the same and costing
 * wildly different things. An unarmed mint now shows a disabled button and says
 * why, which is the honest version of the same information.
 */
export function MintGate({ onMinted }: { onMinted: (serial: number | null) => void }) {
  const { address, signAndSendTransaction } = useWallet()
  const mint = useMint(address)

  const status = mint.status
  const balance = mint.balance

  // Raw units at the decimals the mint itself reports — never the `uiAmount`
  // float sitting beside it. A float is a display artifact and must not be what
  // decides whether an irreversible transfer is affordable.
  const requiredRaw = balance ? mintAmount(balance.decimals) : null
  const shortRaw =
    balance !== null && requiredRaw !== null && balance.rawAmount < requiredRaw
      ? requiredRaw - balance.rawAmount
      : 0n

  // The wallet must HOLD the gate amount, which is a separate config field from
  // the price even though both are 10,000 today.
  const holdRequired = status?.holdRequirementTokens ?? Number(MINT_BURN)
  const holdsEnough = balance !== null && balance.uiAmount >= holdRequired

  /**
   * The client builds its transfer from MINT_BURN, a compiled-in constant, while
   * the database checks it against `mint_price_tokens`, a row an operator can
   * edit. If those two ever disagree the buyer pays the client's number and the
   * backend refuses it — money gone, no NFT. So a mismatch disarms the button
   * rather than being tolerated.
   */
  const priceMismatch =
    status !== null && status.priceTokens > 0 && status.priceTokens !== Number(MINT_BURN)

  const busy =
    mint.stage === 'checking' ||
    mint.stage === 'awaiting-signature' ||
    mint.stage === 'sending' ||
    mint.stage === 'verifying'

  const armed = status?.ok === true && !priceMismatch
  const disabled = !armed || !address || busy || !holdsEnough || mint.stage === 'done'

  const run = async () => {
    if (!signAndSendTransaction) return
    const ok = await mint.mint(signAndSendTransaction)
    if (ok) onMinted(mint.outcome?.assignment?.serial ?? null)
  }

  return (
    <div className="space-y-3 border border-ink p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <span className="ui ui-11">Mint</span>
        <Chip tone={armed ? 'ink' : 'outline'}>{armed ? 'Live' : 'Not available'}</Chip>
      </div>

      <div className="space-y-1.5 text-[11px]">
        <Row label="You pay">
          <Money>{num(status?.priceTokens ?? Number(MINT_BURN))} $XCs</Money>
        </Row>
        <Row label="Sent to">
          {status?.devWallet ? (
            <span className="mono text-[10px]" title={status.devWallet}>
              {shortAddress(status.devWallet, 6, 6)}
            </span>
          ) : (
            <span className="text-ink-faint">—</span>
          )}
        </Row>
        <Row label="You must hold">
          <span className="tabular-nums">{num(holdRequired)} $XCs</span>
        </Row>
        <Row label="Your balance">
          {balance ? (
            <span className={`mono tabular-nums ${holdsEnough ? '' : 'text-down'}`}>
              {num(balance.uiAmount)} $XCs
            </span>
          ) : (
            <span className="text-ink-faint">—</span>
          )}
        </Row>
      </div>

      <GateNote
        status={mint.status}
        statusError={mint.statusError}
        priceMismatch={priceMismatch}
        hasWallet={Boolean(address)}
        shortRaw={shortRaw}
        decimals={balance?.decimals ?? 9}
      />

      {mint.error ? <ErrorLine error={mint.error} /> : null}

      {mint.outcome ? (
        <div className="space-y-2 border-t border-rule pt-3">
          {mint.outcome.verified && mint.outcome.assignment?.status === 'issued' ? (
            <p className="text-[10px] leading-relaxed">
              Minted <strong>{mint.outcome.assignment.label}</strong>. It is yours on xNET.
            </p>
          ) : (
            // Never rendered as a failure. The tokens have left the wallet and
            // the transaction is on chain; the only thing outstanding is an index.
            <p className="text-[10px] leading-relaxed text-ink-mute">
              {mint.outcome.assignment?.heldReason ??
                mint.outcome.note ??
                'Your payment is on chain and is being verified.'}
            </p>
          )}
          <a
            href={explorerTx(mint.outcome.signature)}
            target="_blank"
            rel="noreferrer noopener"
            className="mono block text-[10px] underline"
          >
            View transaction on Solscan →
          </a>
        </div>
      ) : null}

      <div className="flex flex-wrap items-center gap-3">
        <Button onClick={() => void run()} disabled={disabled}>
          {mint.stage === 'awaiting-signature'
            ? 'Confirm in wallet…'
            : mint.stage === 'sending'
              ? 'Sending…'
              : mint.stage === 'verifying'
                ? 'Verifying on chain…'
                : mint.stage === 'checking'
                  ? 'Checking balance…'
                  : mint.stage === 'done'
                    ? 'Minted'
                    : (
                        <>
                          {/* keep-case: Button carries `.ui`, which uppercases
                              its label. The ticker's trailing lowercase s is
                              part of the name — without this it reads $XCS. */}
                          Mint — <span className="keep-case">{num(status?.priceTokens ?? Number(MINT_BURN))} $XCs</span>
                        </>
                      )}
        </Button>
        {address ? (
          <button onClick={() => void mint.refresh()} className="text-[10px] text-ink-mute underline">
            Refresh balance
          </button>
        ) : null}
      </div>
    </div>
  )
}

/**
 * One sentence saying exactly what is standing between this visitor and a mint.
 *
 * Ordered by which fact the visitor can act on: their own balance last, because
 * it is the only one they can do something about, and it should not be buried
 * under an outage they cannot.
 */
function GateNote({
  status,
  statusError,
  priceMismatch,
  hasWallet,
  shortRaw,
  decimals,
}: {
  status: ReturnType<typeof useMint>['status']
  statusError: string | null
  priceMismatch: boolean
  hasWallet: boolean
  shortRaw: bigint
  decimals: number
}) {
  const base = 'border-t border-rule pt-3 text-[10px] leading-relaxed'

  // Checked before the null-status case, because an unreachable backend also
  // leaves status null and "Reading the mint gate…" would then never stop.
  if (statusError !== null && status === null) {
    return (
      <p className={`${base} text-down`}>
        The mint gate could not be read, so minting is disabled. {statusError}
      </p>
    )
  }

  if (status === null) {
    return <p className={`${base} text-ink-mute`}>Reading the mint gate…</p>
  }

  if (priceMismatch) {
    return (
      <p className={`${base} text-down`}>
        The configured mint price ({num(status.priceTokens)} $XCs) does not match what this build
        sends ({num(Number(MINT_BURN))} $XCs). Minting is disabled until they agree — paying the
        wrong amount would be refused after the tokens had already left.
      </p>
    )
  }

  if (status.reason === 'not-configured') {
    return (
      <p className={`${base} text-ink-mute`}>
        The mint is not armed. <code>xnft_mint</code> and <code>dev_wallet</code> in{' '}
        <code>protocol_config</code> are empty, so this app will not build or send a transaction.
      </p>
    )
  }

  if (status.reason === 'paused') {
    return <p className={`${base} text-ink-mute`}>Minting is paused by the operator.</p>
  }

  if (status.reason === 'sold-out') {
    return <p className={`${base} text-ink-mute`}>Every serial in the collection has been minted.</p>
  }

  if (!hasWallet) {
    return (
      <p className={`${base} text-ink-mute`}>
        Connect an EVM wallet to check your balance. Connecting is read-only — nothing is signed
        until you click Mint yourself.
      </p>
    )
  }

  if (shortRaw > 0n) {
    return (
      <p className={`${base} text-down`}>
        Short {num(fromRawUnits(shortRaw, decimals), 2)} $XCs of the{' '}
        {num(status.holdRequirementTokens)} this mint requires.
      </p>
    )
  }

  return (
    <p className={`${base} text-ink-mute`}>
      One transfer, no protocol fee. {num(status.remaining)} of {num(status.maxSupply)} serials are
      still open, and which one you draw is decided when the payment is verified.
    </p>
  )
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-ink-faint">{label}</span>
      {children}
    </div>
  )
}

function ErrorLine({ error }: { error: BurnError }) {
  if (!isBurnError(error)) return null
  return <p className="border-t border-rule pt-3 text-[10px] text-down">{error.message}</p>
}
