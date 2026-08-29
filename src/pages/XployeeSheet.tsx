import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { Panel, TierBadge, Table, Th, Td, Tr, Stat, Chip } from '../components/ui'
import { XployeeArt } from '../components/XployeeArt'
import { buildXployee, serial, MAX_SUPPLY } from '../lib/xployee'
import { accruedTotal, yieldPerEpoch, GENESIS } from '../lib/accrual'
import { effectiveApy } from '../lib/skills'
import { useNow } from '../lib/useNow'
import { usePrices } from '../lib/usePrices'
import { getStock } from '../lib/stocks'
import { fetchHolder, isBackendError } from '../lib/backend'
import { usd, pct, num, shortAddress, dateOnly } from '../lib/format'
import { explorerTx } from '../lib/solana'
import { NotFound } from './NotFound'

interface Holder {
  owner: string
  mintedAt: number
  signature: string
}

/**
 * One xployee's sheet.
 *
 * Identity is a pure function of the serial, so this page can render any serial
 * in the supply whether or not it has been minted — and it says which, rather
 * than implying every sheet is somebody's property. Ownership is the one fact it
 * has to ask the database for.
 *
 * The marketplace half of this page is gone: it used to show a listing price, a
 * rental quote, a sale-fee breakdown and a floor comparison, all computed from a
 * simulated order book with no listings in it.
 */
export function XployeeSheet() {
  const { id } = useParams()
  const now = useNow(1000)
  const prices = usePrices()

  const numericId = Number(id)
  const valid = Number.isInteger(numericId) && numericId >= 0 && numericId < MAX_SUPPLY

  const [holder, setHolder] = useState<Holder | null>(null)
  const [checked, setChecked] = useState(false)

  useEffect(() => {
    if (!valid) return
    let live = true
    setChecked(false)
    void fetchHolder(numericId).then((result) => {
      if (!live) return
      setHolder(result && !isBackendError(result) ? result : null)
      setChecked(true)
    })
    return () => {
      live = false
    }
  }, [numericId, valid])

  if (!valid) return <NotFound label="No such xployee" />

  // hiredAt drives the accrual clock. For an unminted serial there is no hire
  // date, so GENESIS stands in and the page labels the figures as indicative
  // rather than presenting them as somebody's earnings.
  const x = buildXployee(numericId, holder?.mintedAt || GENESIS)
  const minted = holder !== null
  const accrued = accruedTotal(x, now)

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2 text-[11px] text-ink-mute">
        <Link to="/xnet" className="inline-flex min-h-11 items-center underline">
          <span className="keep-case">xNET</span>
        </Link>
        <span>/</span>
        <span className="ui ui-10 text-ink">{serial(x.id)}</span>
      </div>

      <div className="grid gap-4 lg:grid-cols-[320px_1fr]">
        <div className="min-w-0 space-y-4">
          <Panel title={serial(x.id)} right={<TierBadge tier={x.tier} />} bodyClassName="p-0" accent={x.tier.shade}>
            <XployeeArt xployee={x} size={320} className="w-full" />
          </Panel>

          <Panel title="Ownership">
            {!checked ? (
              <p className="text-[11px] text-ink-mute">Checking…</p>
            ) : minted && holder ? (
              <div className="space-y-2 text-[11px]">
                <div className="flex items-center justify-between gap-3">
                  <span className="text-ink-faint">Held by</span>
                  <Link to={`/wallet/${holder.owner}`} className="mono text-[10px] underline">
                    {shortAddress(holder.owner, 5, 5)}
                  </Link>
                </div>
                <div className="flex items-center justify-between gap-3">
                  <span className="text-ink-faint">Hired</span>
                  <span>{dateOnly(holder.mintedAt)}</span>
                </div>
                <a
                  // solscan.io was hardcoded here — a Solana explorer, which
                  // would render a Robinhood Chain hash as "not found" on every
                  // mint. explorerTx() is the same Blockscout URL the mint
                  // receipt uses, so the two cannot drift apart again.
                  href={explorerTx(holder.signature)}
                  target="_blank"
                  rel="noreferrer noopener"
                  className="mono block pt-1 text-[10px] underline"
                >
                  Mint transaction →
                </a>
              </div>
            ) : (
              <div className="space-y-3">
                <Chip tone="outline">Unminted</Chip>
                <p className="text-[10px] leading-relaxed text-ink-mute">
                  Nobody holds this serial yet. It is still in the reveal order and can come out of
                  a mint.
                </p>
                <Link to="/mint" className="ui ui-10 block underline">
                  Mint an xployee →
                </Link>
              </div>
            )}
          </Panel>
        </div>

        <div className="min-w-0 space-y-4">
          <Panel title="Worker">
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
              <Stat label="Tier" value={x.tier.label} sub={`${x.tier.skills} desks`} accent={x.tier.shade} />
              <Stat label="Blended APY" value={pct(x.apy)} sub="across its desks" />
              <Stat label="Per Epoch" value={usd(yieldPerEpoch(x), 2)} sub="indicative" />
              <Stat
                label={minted ? 'Accrued' : 'Accrued (since genesis)'}
                value={usd(accrued, 2)}
                sub={minted ? 'lifetime' : 'if hired at genesis'}
              />
            </div>
          </Panel>

          <Panel title="Desks" right={`${x.skills.length} staffed`}>
            <Table>
              <thead>
                <tr>
                  <Th>Skill</Th>
                  <Th>Desk</Th>
                  <Th>Ticker</Th>
                  <Th align="right">Price</Th>
                  <Th align="right">Prof.</Th>
                  <Th align="right">Eff. APY</Th>
                </tr>
              </thead>
              <tbody>
                {x.skills.map((h, i) => (
                  <Tr key={h.skill.id} index={i}>
                    <Td>
                      <span className="ui ui-10">{h.skill.label}</span>
                    </Td>
                    <Td className="text-ink-mute">{getStock(h.skill.ticker)?.name ?? h.skill.desk}</Td>
                    <Td>
                      <span className="mono keep-case font-medium">${h.skill.ticker}</span>
                    </Td>
                    <Td align="right">{usd(prices.bySymbol[h.skill.ticker])}</Td>
                    <Td align="right">{pct(h.proficiency, 0)}</Td>
                    <Td align="right">{pct(effectiveApy(h))}</Td>
                  </Tr>
                ))}
              </tbody>
            </Table>
            <p className="mt-3 text-[10px] leading-relaxed text-ink-faint">
              Desk prices come from Robinhood's own stock-token API ({prices.source}). Yield figures are the
              collection's own model and are not a claim about proceeds.
            </p>
          </Panel>

          <Panel title="Traits">
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
              <Stat label="Uniform" value={x.traits.uniform} />
              <Stat label="Head" value={x.traits.head} />
              <Stat label="Face" value={x.traits.face} />
              <Stat label="Accessory" value={x.traits.accessory} />
            </div>
            <p className="mt-3 text-[10px] text-ink-faint">
              Serial {num(x.id)} of {num(MAX_SUPPLY)}. Traits are derived from the serial and are
              the same on every machine.
            </p>
          </Panel>
        </div>
      </div>
    </div>
  )
}
