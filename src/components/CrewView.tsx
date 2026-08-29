import { Link } from 'react-router-dom'
import { Panel, Stat, Empty, Chip, TierBadge } from './ui'
import { XployeeArt } from './XployeeArt'
import { XBossBadge, asXBoss } from './XBossBadge'
import { buildXployee } from '../lib/xployee'
import { getTier, type TierId } from '../lib/tiers'
import { num, shortAddress, plural } from '../lib/format'
import type { WalletPage } from '../lib/backend'

/**
 * One wallet's crew, rendered from what the database issued.
 *
 * Shared by /profile and /wallet/:address because they are the same view of the
 * same data — the only difference is whose address is in the URL. Two copies
 * would be two places for the rank and the crew to disagree.
 *
 * The art is not stored anywhere. Identity is a pure function of the serial
 * (xployee.ts), so the database sends a number and the browser draws the worker.
 */
export function CrewView({ page, own }: { page: WalletPage; own: boolean }) {
  if (!page.ok || page.crew.length === 0) {
    return (
      <div className="space-y-5">
        <Panel title={own ? 'Your Crew' : 'Wallet'} right={shortAddress(page.wallet, 6, 6)}>
          <p className="text-[11px] leading-relaxed text-ink-mute">
            {own
              ? 'This wallet has not minted yet. Once a mint is verified on chain, its xployee appears here and the wallet joins xNET.'
              : 'This wallet holds no xployees.'}
          </p>
        </Panel>
        {own ? (
          <Empty title="Nothing hired yet">
            <Link to="/mint" className="underline">
              Mint an xployee →
            </Link>
          </Empty>
        ) : null}
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <Panel
        title={own ? 'Your Crew' : 'Wallet'}
        right={<span className="mono normal-case">{shortAddress(page.wallet, 6, 6)}</span>}
      >
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="xNET Rank" value={page.position ? `#${page.position}` : '—'} sub="by crew rarity" />
          <Stat label="Crew" value={num(page.holdings)} sub={plural(page.holdings, 'xployee')} />
          <Stat label="Rarity Score" value={num(page.rarityScore, 1)} sub="summed weight" />
          <Stat
            label="xBoss"
            value={<XBossBadge rank={asXBoss(page.xboss)} size="lg" />}
            sub="status ladder"
          />
        </div>
        {page.handle ? (
          <div className="mt-4">
            <Chip tone="mute">{page.handle}</Chip>
          </div>
        ) : null}
      </Panel>

      <Panel title="Holdings" right={num(page.crew.length)} bodyClassName="p-4">
        <div className="flex flex-wrap gap-4">
          {page.crew.map((m) => {
            const x = buildXployee(m.serial, m.mintedAt || Date.now())
            return (
              <Link
                key={m.serial}
                to={`/xployee/${m.serial}`}
                title={m.label}
                className="group block w-[104px]"
              >
                <XployeeArt xployee={x} size={104} animated={false} className="" />
                <span className="ui ui-10 mt-1 block text-ink-mute group-hover:text-ink">
                  {m.label}
                </span>
                <TierBadge tier={getTier(m.tier as TierId)} />
              </Link>
            )
          })}
        </div>
      </Panel>
    </div>
  )
}
