import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { XployeeArt } from './XployeeArt'
import { showcase } from '../lib/collection'
import { TIERS, type Tier } from '../lib/tiers'
import { serial, type Xployee } from '../lib/xployee'
import { effectiveApy } from '../lib/skills'
import { num, pct, plural } from '../lib/format'

/**
 * One sample card per rarity, cycling.
 *
 * The landing page has a real problem at launch: nothing is minted, so the only
 * honest thing the workforce panel can say is "nothing yet". That leaves a
 * visitor with no idea what they would be buying. This is the answer — one
 * genuinely unminted xployee from each tier, with its real metrics, and a way to
 * go and mint.
 *
 * Every card is a REAL serial off the reveal order, not a mock-up. Its art,
 * traits, desks and rates are the same functions of the same serial the rest of
 * the site uses, so what is previewed here is exactly what a mint can produce.
 *
 * Rarest first, because the first card is the argument.
 */
const ORDER = ['xrated', 'expert', 'mid', 'entry'] as const

/** How long a card holds before advancing. Long enough to read the metrics. */
const DWELL_MS = 5200

interface Sample {
  tier: Tier
  xployee: Xployee
}

function samples(): Sample[] {
  const crew = showcase()
  const out: Sample[] = []
  for (const id of ORDER) {
    const tier = TIERS.find((t) => t.id === id)
    const xployee = crew.find((x) => x.tier.id === id)
    if (tier && xployee) out.push({ tier, xployee })
  }
  return out
}

export function RaritySampler() {
  const cards = samples()
  const [index, setIndex] = useState(0)
  const [paused, setPaused] = useState(false)
  // Set once the visitor drives it themselves. After that the carousel stops
  // moving on its own — nothing is more irritating than a panel that scrolls
  // away from the card you just chose.
  const taken = useRef(false)

  const go = useCallback((next: number) => {
    taken.current = true
    setIndex(next)
  }, [])

  useEffect(() => {
    if (paused || taken.current || cards.length < 2) return
    const id = window.setTimeout(() => setIndex((i) => (i + 1) % cards.length), DWELL_MS)
    return () => window.clearTimeout(id)
  }, [index, paused, cards.length])

  // Reduced motion gets the same cards and the same controls, without the
  // automatic advance or the slide.
  const [reduced, setReduced] = useState(false)
  useEffect(() => {
    const q = window.matchMedia('(prefers-reduced-motion: reduce)')
    const sync = () => setReduced(q.matches)
    sync()
    q.addEventListener('change', sync)
    return () => q.removeEventListener('change', sync)
  }, [])

  if (cards.length === 0) return null
  const current = cards[Math.min(index, cards.length - 1)]

  return (
    <div
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocusCapture={() => setPaused(true)}
      onBlurCapture={() => setPaused(false)}
    >
      {/* The window. overflow-hidden plus a translated track is what makes the
          change a slide rather than a swap — and it keeps every card mounted, so
          the art is not regenerated on each turn. */}
      <div className="overflow-hidden border border-rule">
        <div
          className="flex"
          style={{
            width: `${cards.length * 100}%`,
            transform: `translate3d(-${(index * 100) / cards.length}%, 0, 0)`,
            transition: reduced ? 'none' : 'transform 620ms cubic-bezier(0.22, 0.61, 0.36, 1)',
          }}
        >
          {cards.map((card) => (
            <Card key={card.tier.id} card={card} width={100 / cards.length} />
          ))}
        </div>
      </div>

      {/* Caption, in the tier's own colour. `tier-*` rather than an inline
          tier.color: those class values are the darkened readable variants, and
          the raw hues are graphics — see index.css. */}
      <div className="mt-3 text-center">
        <span className={`ui ui-11 keep-case tier-${current.tier.id}`}>
          {current.tier.label} sample card
        </span>
        <span className="ui ui-10 ml-2 text-ink-mute">({pct(current.tier.supply, 0)} drop rate)</span>
      </div>

      {/* The position bars. Each carries its own rarity, so the strip doubles as
          a legend — the first one being red is what tells you the deck is
          ordered rarest first before you have seen a second card. */}
      <div className="mt-3 flex gap-1.5" role="tablist" aria-label="Rarity samples">
        {cards.map((card, i) => (
          <button
            key={card.tier.id}
            role="tab"
            aria-selected={i === index}
            aria-label={`${card.tier.label} sample`}
            onClick={() => go(i)}
            className="min-h-11 flex-1 px-0.5"
          >
            <span
              className="block h-1.5 w-full transition-opacity duration-300"
              style={{
                background: card.tier.color,
                opacity: i === index ? 1 : 0.28,
              }}
            />
          </button>
        ))}
      </div>
    </div>
  )
}

function Card({ card, width }: { card: Sample; width: number }) {
  const { tier, xployee } = card
  const desks = xployee.skills
  const best = desks.reduce((hi, h) => Math.max(hi, effectiveApy(h)), 0)

  return (
    <div className="shrink-0 p-4" style={{ width: `${width}%` }}>
      <div className="flex items-start gap-4">
        <div className="w-[132px] shrink-0">
          <XployeeArt xployee={xployee} size={132} animated={false} />
        </div>

        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-2">
            <span className="ui ui-12">{serial(xployee.id)}</span>
            <span className="ui ui-10 text-ink-faint">{plural(tier.skills, 'desk')}</span>
          </div>

          <dl className="mt-2 space-y-1 border-t border-rule pt-2 text-[10px]">
            <Metric label="Drop rate" value={pct(tier.supply, 0)} />
            <Metric label="Of 5,000" value={num(Math.round(tier.supply * 5000))} />
            <Metric label="Blended APY" value={pct(xployee.apy)} />
            <Metric label="Best desk" value={pct(best)} />
          </dl>

          <div className="mt-2 truncate text-[10px] text-ink-mute" title={desks.map((h) => h.skill.label).join(' · ')}>
            {desks.map((h) => h.skill.label).join(' · ')}
          </div>
        </div>
      </div>

      {/* The site's filled control, not a bespoke one. A call to action that
          invents its own shape reads as an ad rather than as part of the page. */}
      <Link
        to="/mint"
        className="ui ui-11 mt-4 flex min-h-11 items-center justify-center bg-accent px-5 py-2.5 text-accent-ink hover:opacity-90"
      >
        Mint now →
      </Link>
    </div>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <dt className="text-ink-faint">{label}</dt>
      <dd className="mono tabular-nums">{value}</dd>
    </div>
  )
}
