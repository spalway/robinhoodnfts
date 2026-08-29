import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { Panel, Stat, Table, Th, Td, Tr, Empty, Button, Chip, TierBadge } from '../components/ui'
import { XployeeArt } from '../components/XployeeArt'
import { XBossBadge, asXBoss } from '../components/XBossBadge'
import {
  fetchLeaderboard,
  fetchNetworkStats,
  isBackendError,
  type LeaderRow,
  type NetworkStats,
} from '../lib/backend'
import { buildXployee } from '../lib/xployee'
import { getTier, type TierId } from '../lib/tiers'
import { num, shortAddress, plural } from '../lib/format'

/**
 * xNET — who actually holds what.
 *
 * Every row here is a wallet that paid for and received at least one serial, and
 * the ordering is the sum of the rarity weights of what it holds. Both facts come
 * out of the database, which only writes them after reading a payment off the
 * chain — so a rank cannot move without somebody having actually minted.
 *
 * This page used to be generated in the browser. It partitioned the collection
 * across invented wallets with invented handles and `fakeAddress` addresses, and
 * a launch-day protocol showing a hundred holders is claiming a history it does
 * not have. It now starts empty and fills up as people mint.
 */
const PAGE = 30

export function XNet() {
  const [query, setQuery] = useState('')
  const [limit, setLimit] = useState(PAGE)
  const [rows, setRows] = useState<LeaderRow[] | null>(null)
  const [stats, setStats] = useState<NetworkStats | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async (q: string, take: number) => {
    const [board, net] = await Promise.all([
      // One over the page size, so "load more" knows whether there is a next
      // page without a second count query.
      fetchLeaderboard({ limit: take + 1, query: q }),
      fetchNetworkStats(),
    ])
    if (isBackendError(board)) {
      setError(board.message)
      setRows([])
      return
    }
    setError(null)
    setRows(board)
    if (!isBackendError(net)) setStats(net)
  }, [])

  // Debounced so typing an address does not fire a request per keystroke.
  useEffect(() => {
    const id = window.setTimeout(() => void load(query, limit), query ? 250 : 0)
    return () => window.clearTimeout(id)
  }, [query, limit, load])

  const visible = useMemo(() => (rows ?? []).slice(0, limit), [rows, limit])
  const hasMore = (rows?.length ?? 0) > limit
  const leaders = useMemo(() => (query ? [] : visible.slice(0, 3)), [visible, query])

  return (
    <div className="space-y-5">
      <Panel title="xNET — The Network" right={stats ? plural(stats.wallets, 'wallet') : '—'}>
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Wallets" value={stats ? num(stats.wallets) : '—'} sub="holding xployees" />
          <Stat
            label="Minted"
            value={stats ? `${num(stats.issued)} / ${num(stats.maxSupply)}` : '—'}
            sub="issued on chain"
          />
          <Stat
            label="X-RATED Pulled"
            value={stats ? num(stats.tiers.xrated ?? 0) : '—'}
            sub="rarest tier"
          />
          <Stat
            label="Network Rarity"
            value={stats ? num(stats.rarityTotal, 1) : '—'}
            sub="summed weight"
          />
        </div>
        <p className="mt-4 max-w-3xl text-[11px] leading-relaxed text-ink-mute">
          Every xployee in circulation is held by exactly one wallet. xBoss rank is set by the total
          rarity of the crew a wallet controls — one X-RATED outranks nineteen UNCOMMONs — so it only
          moves when you mint.
        </p>
      </Panel>

      {leaders.length > 0 ? (
        <div className="grid gap-4 md:grid-cols-3">
          {leaders.map((w) => (
            <LeaderCard key={w.wallet} wallet={w} />
          ))}
        </div>
      ) : null}

      <Panel title="Wallet Directory" right={rows ? `${num(visible.length)} shown` : '—'}>
        <div className="flex flex-wrap items-center gap-4">
          <label className="flex flex-1 items-center gap-2 min-w-[240px]">
            <span className="ui ui-10 text-ink-mute">Search</span>
            <input
              value={query}
              onChange={(e) => {
                setQuery(e.target.value)
                setLimit(PAGE)
              }}
              placeholder="handle or wallet address"
              className="min-h-11 w-full border border-ink bg-paper px-3 py-2 text-[11px] outline-none placeholder:text-ink-faint focus:bg-wash"
            />
          </label>
          {query ? (
            <Button variant="outline" onClick={() => setQuery('')}>
              Clear
            </Button>
          ) : null}
        </div>
      </Panel>

      {error ? (
        <Empty title="The network is unreachable">{error}</Empty>
      ) : rows === null ? (
        <Empty title="Loading the network…" />
      ) : visible.length === 0 ? (
        <Empty title={query ? 'No wallets match' : 'Nobody has minted yet'}>
          {query
            ? 'Try a different handle or paste a full address.'
            : 'The first wallet to mint takes the top of this board.'}
        </Empty>
      ) : (
        <Panel title="Wallets" right={`${num(visible.length)} shown`} bodyClassName="p-0">
          <Table>
            <thead>
              <tr>
                <Th align="right">#</Th>
                <Th>Wallet</Th>
                <Th>xBoss</Th>
                <Th>Best Pull</Th>
                <Th align="right">Crew</Th>
                <Th align="right">Rarity</Th>
              </tr>
            </thead>
            <tbody>
              {visible.map((w, i) => (
                <Tr key={w.wallet} index={i}>
                  <Td align="right" className="text-ink-faint">
                    {w.position}
                  </Td>
                  <Td>
                    <Link to={`/wallet/${w.wallet}`} className="mono font-medium hover:underline">
                      {w.handle ?? shortAddress(w.wallet, 6, 6)}
                    </Link>
                  </Td>
                  <Td>
                    <XBossBadge rank={asXBoss(w.xboss)} />
                  </Td>
                  {/* TierBadge, not a hand-rolled span on tier.color. The raw
                      hues measure 2.78:1 (UNCOMMON) to 3.88:1 (RARE) as type
                      here; the badge carries the accessible ladder. */}
                  <Td>
                    <TierBadge tier={getTier(w.bestTier as TierId)} />
                  </Td>
                  <Td align="right">{num(w.holdings)}</Td>
                  <Td align="right">{num(w.rarityScore, 1)}</Td>
                </Tr>
              ))}
            </tbody>
          </Table>
        </Panel>
      )}

      {hasMore ? (
        <div className="flex justify-center">
          <Button variant="outline" onClick={() => setLimit((l) => l + PAGE)}>
            Load more
          </Button>
        </div>
      ) : null}
    </div>
  )
}

function LeaderCard({ wallet }: { wallet: LeaderRow }) {
  // The crew's rarest member is the wallet's face. Its art is a pure function of
  // the serial, so the database only has to send the number.
  const face = buildXployee(wallet.bestSerial, wallet.firstMintAt || Date.now())

  return (
    <Panel
      title={`#${wallet.position} Top Holder`}
      right={<span className="keep-case">{wallet.handle ?? shortAddress(wallet.wallet, 4, 4)}</span>}
    >
      <div className="flex gap-4">
        <XployeeArt xployee={face} size={96} className="shrink-0" />
        <div className="min-w-0 flex-1 space-y-2">
          <XBossBadge rank={asXBoss(wallet.xboss)} size="lg" />
          <div className="flex flex-wrap items-center gap-2">
            <Chip tone="mute">{plural(wallet.holdings, 'xployee')}</Chip>
            <Chip tone="mute">{num(wallet.rarityScore, 1)} rarity</Chip>
          </div>
        </div>
      </div>
      <div className="mt-4">
        <Link
          to={`/wallet/${wallet.wallet}`}
          className="ui ui-10 inline-flex min-h-11 items-center border border-ink px-3 py-2 hover:bg-ink hover:text-paper"
        >
          View crew →
        </Link>
      </div>
    </Panel>
  )
}
