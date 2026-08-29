import { useEffect, useRef, useState, lazy, Suspense } from 'react'
import { Link } from 'react-router-dom'
import { Panel, Stat, TierBadge, Button, Table, Th, Td, Tr, LinkButton } from '../components/ui'
import { XployeeArt } from '../components/XployeeArt'
import { buildXployee, serial, MAX_SUPPLY, type Xployee } from '../lib/xployee'
import { TIERS } from '../lib/tiers'
import { useWallet } from '../lib/wallet'
import { fetchMintStatus, isBackendError, type MintStatus } from '../lib/backend'
import { num, pct } from '../lib/format'

// @solana/web3.js + spl-token are ~320kB and only ever needed here, at the
// moment somebody actually pays. Lazy-loading keeps them out of the main chunk
// so every other page still loads on the small bundle.
const MintGate = lazy(() =>
  import('../components/MintGate').then((m) => ({ default: m.MintGate })),
)

type Phase = 'idle' | 'revealing' | 'revealed'

/** Preview ids sit far past the collection so they can never collide with a real serial. */
const PREVIEW_BASE = 90_000

const ROLL_STEPS = 26

/**
 * The reveal decelerates rather than running at a fixed rate — a flat cycle
 * reads as a loading spinner, while a slowdown reads as a result landing.
 *
 * Normalised on step/ROLL_STEPS so the curve's shape is independent of the step
 * count. Sums to roughly 3s, ending at ~340ms between swaps.
 */
function rollDelay(step: number): number {
  return Math.round(42 + Math.pow(step / ROLL_STEPS, 3) * 300)
}

export function Mint() {
  const { address } = useWallet()

  const [status, setStatus] = useState<MintStatus | null>(null)
  const [phase, setPhase] = useState<Phase>('idle')
  const [minted, setMinted] = useState<Xployee | null>(null)
  const [preview, setPreview] = useState<Xployee>(() => buildXployee(PREVIEW_BASE + 1, Date.now()))
  const [flash, setFlash] = useState(false)

  const timers = useRef<number[]>([])
  useEffect(() => () => timers.current.forEach(window.clearTimeout), [])

  // Supply and the gate come from the database, so the numbers on this page are
  // the same ones the mint itself is decided by. There is no local count any
  // more — the previous version added a browser's localStorage tally to a
  // hardcoded constant and called the result the supply.
  useEffect(() => {
    let live = true
    void fetchMintStatus(address).then((s) => {
      if (live && !isBackendError(s)) setStatus(s)
    })
    return () => {
      live = false
    }
  }, [address])

  const shown = phase === 'revealed' && minted ? minted : preview

  /**
   * Runs only after a payment has been verified on chain, and only on the serial
   * the database actually issued. It is a reveal of a fact, not a roll — nothing
   * here decides what anybody got.
   */
  function reveal(assigned: number | null) {
    void fetchMintStatus(address).then((s) => {
      if (!isBackendError(s)) setStatus(s)
    })

    // A held payment has no serial yet. MintGate says so in words; there is
    // nothing to animate.
    if (assigned === null) return

    setPhase('revealing')
    let elapsed = 0
    for (let step = 0; step < ROLL_STEPS; step++) {
      elapsed += rollDelay(step)
      const id = window.setTimeout(() => {
        setPreview(buildXployee(PREVIEW_BASE + ((step * 37) % 971) + 1, Date.now()))
      }, elapsed)
      timers.current.push(id)
    }

    timers.current.push(
      window.setTimeout(() => {
        setMinted(buildXployee(assigned, Date.now()))
        setPhase('revealed')
        setFlash(true)
        timers.current.push(window.setTimeout(() => setFlash(false), 550))
      }, elapsed + 260),
    )
  }

  function reset() {
    timers.current.forEach(window.clearTimeout)
    timers.current = []
    setPhase('idle')
    setMinted(null)
  }

  const issued = status?.issued ?? 0
  const remaining = status?.remaining ?? 0
  const maxSupply = status?.maxSupply ?? MAX_SUPPLY

  return (
    <div className="space-y-5">
      <Panel title="Mint — Hire An xployee" right={`${num(remaining)} positions open`}>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Minted" value={`${num(issued)} / ${num(maxSupply)}`} sub="issued on chain" />
          <Stat
            label="Price"
            value={<span className="keep-case">{num(status?.priceTokens ?? 10_000)} $XAS</span>}
            sub="per xployee"
          />
          <Stat
            label="Hold To Mint"
            value={<span className="keep-case">{num(status?.holdRequirementTokens ?? 10_000)} $XAS</span>}
            sub="wallet requirement"
          />
          <Stat label="Your Hires" value={num(status?.walletHoldings ?? 0)} sub="this wallet" />
        </div>
        <p className="mt-4 max-w-3xl text-[11px] leading-relaxed text-ink-mute">
          You don't pick a portfolio — you hire a worker, and its tier decides how many desks it can
          staff. Which serial you draw is decided when your payment is verified against the chain,
          from a shuffle fixed before the first mint.
        </p>
      </Panel>

      <div className="grid gap-5 lg:grid-cols-[420px_1fr]">
        <Panel
          title={phase === 'revealed' ? 'Hired' : phase === 'revealing' ? 'Interviewing' : 'Candidate'}
          bodyClassName="p-0"
        >
          <div className="relative">
            <XployeeArt xployee={shown} size={416} className="w-full border-b border-ink" />

            {flash && minted ? (
              <div
                className="pointer-events-none absolute inset-0 animate-pulse"
                style={{ background: minted.tier.color, opacity: 0.28 }}
              />
            ) : null}

            {phase === 'revealing' ? (
              <div className="pointer-events-none absolute inset-x-0 bottom-3 flex justify-center">
                <span className="ui ui-10 bg-ink px-3 py-1.5 text-paper">Interviewing…</span>
              </div>
            ) : null}

            {phase === 'idle' ? (
              <div className="pointer-events-none absolute inset-x-0 bottom-3 flex justify-center">
                <span className="ui ui-10 bg-paper px-3 py-1.5 text-ink-mute border border-rule">
                  Sample art — not your draw
                </span>
              </div>
            ) : null}
          </div>

          <div className="space-y-4 p-4">
            {phase === 'revealed' && minted ? (
              <>
                <div className="flex items-center justify-between gap-3">
                  <span className="ui ui-18">{serial(minted.id)}</span>
                  <TierBadge tier={minted.tier} size="lg" />
                </div>
                <div className="flex flex-wrap gap-3">
                  <LinkButton to={`/xployee/${minted.id}`}>View sheet →</LinkButton>
                  <Button variant="outline" onClick={reset}>
                    Mint another
                  </Button>
                </div>
              </>
            ) : (
              <Suspense
                fallback={
                  <div className="border border-rule p-4 text-[10px] text-ink-faint">
                    Loading mint module…
                  </div>
                }
              >
                <MintGate onMinted={reveal} />
              </Suspense>
            )}
          </div>
        </Panel>

        <div className="space-y-5">
          <Panel title={phase === 'revealed' ? 'Assigned Desks' : 'Tier Table'}>
            {phase === 'revealed' && minted ? (
              <Table>
                <thead>
                  <tr>
                    <Th>Skill</Th>
                    <Th>Desk</Th>
                    <Th>Ticker</Th>
                  </tr>
                </thead>
                <tbody>
                  {minted.skills.map((h, i) => (
                    <Tr key={h.skill.id} index={i}>
                      <Td>
                        <span className="ui ui-10">{h.skill.label}</span>
                      </Td>
                      <Td className="text-ink-mute">{h.skill.desk}</Td>
                      <Td>
                        <span className="mono keep-case font-medium">${h.skill.ticker}</span>
                      </Td>
                    </Tr>
                  ))}
                </tbody>
              </Table>
            ) : (
              <Table>
                <thead>
                  <tr>
                    <Th>Tier</Th>
                    <Th align="right">Skills</Th>
                    <Th align="right">Share of supply</Th>
                    <Th>Background</Th>
                  </tr>
                </thead>
                <tbody>
                  {TIERS.map((t, i) => (
                    <Tr key={t.id} index={i}>
                      <Td>
                        <TierBadge tier={t} />
                      </Td>
                      <Td align="right">{t.skills}</Td>
                      <Td align="right">{pct(t.supply, 0)}</Td>
                      <Td className="text-ink-mute">
                        {t.id === 'entry'
                          ? 'Flat neutral'
                          : t.id === 'mid'
                            ? 'Vivid solid'
                            : t.id === 'expert'
                              ? 'Spacial rays'
                              : 'Scenic, weathered'}
                      </Td>
                    </Tr>
                  ))}
                </tbody>
              </Table>
            )}
          </Panel>

          {status && status.walletHoldings > 0 ? (
            <Panel title="Your Crew" right={num(status.walletHoldings)}>
              <p className="text-[11px] text-ink-mute">
                {num(status.walletHoldings)} minted by this wallet.
              </p>
              <div className="mt-4">
                <Link to="/profile" className="ui ui-10 underline">
                  View your crew →
                </Link>
              </div>
            </Panel>
          ) : null}
        </div>
      </div>
    </div>
  )
}
