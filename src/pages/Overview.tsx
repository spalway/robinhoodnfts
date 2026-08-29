import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Panel, Stat, TierBadge, Table, Th, Td, Tr, Bar } from '../components/ui'
import { RaritySampler } from '../components/RaritySampler'
import { EmptyWorkforce } from '../components/EmptyWorkforce'
import { XployeeArt } from '../components/XployeeArt'
import { TIERS } from '../lib/tiers'
import { MAX_SUPPLY, buildXployee, serial } from '../lib/xployee'
import {
  fetchLeaderboard,
  fetchMintStatus,
  fetchNetworkStats,
  isBackendError,
  type LeaderRow,
  type MintStatus,
  type NetworkStats,
} from '../lib/backend'
import { num, pct } from '../lib/format'

/**
 * The landing page.
 *
 * Every number on it is either a fact about the collection's design (supply,
 * tier shares) or a count the database can prove (minted, wallets). What used to
 * be here instead: a protocol NAV, a lifetime yield accrual, a blended APY, a
 * floor price and a top-earners table, all computed in the browser from a
 * collection nobody had bought. A first-day protocol quoting a NAV is inventing
 * a history it does not have.
 *
 * THE SHAPE OF THE PAGE FOLLOWS FROM ONE FACT: at launch the workforce is
 * empty. So the left column previews what a mint can produce — real unminted
 * serials, one per rarity, with their real metrics — and the workforce panel
 * beside it says plainly that nobody has minted yet, rather than filling itself
 * with samples and letting a visitor mistake them for holdings. That was the
 * previous arrangement and it is the one thing this page must not do.
 */
export function Overview() {
  const [status, setStatus] = useState<MintStatus | null>(null)
  const [stats, setStats] = useState<NetworkStats | null>(null)
  const [leaders, setLeaders] = useState<LeaderRow[] | null>(null)

  useEffect(() => {
    let live = true
    void Promise.all([fetchMintStatus(null), fetchNetworkStats(), fetchLeaderboard({ limit: 12 })]).then(
      ([s, n, l]) => {
        if (!live) return
        if (!isBackendError(s)) setStatus(s)
        if (!isBackendError(n)) setStats(n)
        if (!isBackendError(l)) setLeaders(l)
      },
    )
    return () => {
      live = false
    }
  }, [])

  const issued = stats?.issued ?? 0
  const maxSupply = status?.maxSupply ?? stats?.maxSupply ?? MAX_SUPPLY
  const hold = num(status?.holdRequirementTokens ?? 10_000)

  return (
    <div className="space-y-5">
      <Panel title="xCorp — Hire A Generative Pixel xployee">
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Minted" value={`${num(issued)} / ${num(maxSupply)}`} sub="issued on chain" />
          <Stat label="Holders" value={stats ? num(stats.wallets) : '—'} sub="wallets on xNET" />
          <Stat
            label="Mint Price"
            value={<span className="keep-case">{num(status?.priceTokens ?? 10_000)} $XAS</span>}
            sub="one transfer, no fee"
          />
          {/* Was a "Status" stat reading "Not open yet". It restated what the
              mint page already says on its own button, and told a first-time
              visitor nothing they could act on. How the thing works is the more
              useful fourth cell, and the steps sit under the copy below. */}
          <Stat label="How It Works" value="4 steps" sub="hold, sign, verify, issue" />
        </div>

        {/* The two taglines, in the order they earn attention: the promise
            leads, the mechanism follows. Both are the operator's own words,
            edited for spelling only — a hero paragraph carrying "rariety"
            undoes everything the rest of the page does to look like a desk.

            The mint mechanics that used to sit here moved out entirely. They
            were a prose restatement of the four numbered steps directly below,
            and the steps say it better. */}
        <p className="mt-4 max-w-3xl text-[15px] font-medium leading-snug text-ink">
          Build your own corporation directly on Robinhood Chain. Get started by minting your
          xployee.
        </p>

        <p className="mt-3 max-w-3xl text-[11px] leading-relaxed text-ink-mute">
          Mint your own xployee — an on-chain worker agent that generates returns based on their
          underlying assets, their <span className="text-ink">desks</span>. Higher rarity means
          more desks. xployees can be contracted for a flat daily fee. You can also trade, buy and
          sell your xployees with other holders on{' '}
          <span className="keep-case text-ink">xNET</span>, the official xCorp look-up and
          inventory directory. How do you plan on building your ideal on-chain corporation?
        </p>

        <p className="mt-3 max-w-3xl text-[11px] leading-relaxed text-ink-mute">
          Hold {hold} $XAS to hire one. The serial you draw comes from a shuffle fixed before the
          first mint, so the low numbers stay genuinely rare.
        </p>

        <ol className="mt-4 grid gap-4 border-t border-rule pt-4 text-[11px] leading-relaxed text-ink-mute md:grid-cols-4">
          {[
            ['1', 'Connect an EVM wallet. Read-only — nothing is signed.'],
            ['2', `Hold ${hold} $XAS. The mint button unlocks when your balance clears it.`],
            ['3', 'Sign one transfer to the project wallet.'],
            ['4', 'The payment is verified against the chain and a serial is issued to you.'],
          ].map(([n, body]) => (
            <li key={n}>
              <span className="ui ui-10 block text-ink">Step {n}</span>
              <span className="mt-1 block">{body}</span>
            </li>
          ))}
        </ol>

        <div className="mt-4 flex flex-wrap items-center gap-3">
          <Link
            to="/mint"
            className="ui ui-11 inline-flex min-h-11 items-center bg-accent px-5 py-2.5 text-accent-ink hover:opacity-90"
          >
            Mint an xployee →
          </Link>
          <Link
            to="/xnet"
            className="ui ui-11 inline-flex min-h-11 items-center border border-ink px-5 py-2.5 hover:bg-wash"
          >
            <span className="keep-case">See xNET</span>
          </Link>
        </div>
      </Panel>

      {/* The preview leads and the workforce moves right of it. At launch the
          preview is the only one of the two with anything in it, so it takes the
          reading position; as people mint, the workforce fills and the pair
          balance out without the layout having to change. */}
      <div className="grid gap-5 lg:grid-cols-[420px_1fr]">
        <Panel title="xployees — Preview" right="unminted · sample">
          <RaritySampler />

          <div className="mt-5 border-t border-rule pt-4">
            <div className="ui ui-10 mb-3 text-ink-mute">Rarity</div>
            <Bar segments={TIERS.map((t) => ({ value: t.supply, color: t.color, label: t.label }))} />
            <Table className="mt-3">
              <thead>
                <tr>
                  <Th>Tier</Th>
                  <Th align="right">Desks</Th>
                  <Th align="right">Drop</Th>
                  <Th align="right">Minted</Th>
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
                    <Td align="right">{stats ? num(stats.tiers[t.id] ?? 0) : '—'}</Td>
                  </Tr>
                ))}
              </tbody>
            </Table>
          </div>
        </Panel>

        <Panel
          title="The Workforce"
          right={issued > 0 ? `${num(issued)} minted` : undefined}
          bodyClassName={issued === 0 ? 'p-0' : undefined}
        >
          {issued === 0 || !leaders || leaders.length === 0 ? (
            <EmptyWorkforce />
          ) : (
            <>
              <div className="flex flex-wrap gap-4">
                {leaders.map((row) => (
                  <Link key={row.wallet} to={`/xployee/${row.bestSerial}`} className="w-[124px]">
                    {/* The holder's best pull. hiredAt only drives the accrual
                        clock, which this card does not show, so firstMintAt is
                        the honest stand-in rather than a number invented here. */}
                    <XployeeArt
                      xployee={buildXployee(row.bestSerial, row.firstMintAt)}
                      size={124}
                      animated={false}
                    />
                    <div className="ui ui-10 mt-1 text-ink-mute">{serial(row.bestSerial)}</div>
                    <div className="truncate text-[10px] text-ink-faint">
                      {row.handle ?? `${row.wallet.slice(0, 4)}…${row.wallet.slice(-4)}`}
                    </div>
                  </Link>
                ))}
              </div>
              <p className="mt-4 text-[10px] text-ink-faint">
                The best pull from each of the top holders.{' '}
                <Link to="/xnet" className="underline">
                  See every wallet on xNET →
                </Link>
              </p>
            </>
          )}
        </Panel>
      </div>
    </div>
  )
}
