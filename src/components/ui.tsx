import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { LabelFlames } from './LaserSparks'
import type { Tier } from '../lib/tiers'

/**
 * Panel — the core primitive. Solid black header bar with a white m42 label
 * over a white body. The bar is deliberately taller than the label needs:
 * m42 is a bitmap face whose top pixel row clips against a tight edge.
 */
export function Panel({
  title,
  right,
  children,
  className = '',
  bodyClassName = '',
  accent,
}: {
  /** ReactNode, not string, so a title can carry .keep-case and protect the
      lowercase x in "$XAS" from the global uppercase rule. */
  title: ReactNode
  right?: ReactNode
  children: ReactNode
  className?: string
  bodyClassName?: string
  /**
   * Rarity tint for the header bar and border, so a page about one xployee
   * carries its rarity through the whole layout rather than only in the badge.
   *
   * Pass tier.shade, NOT tier.color. The label is white, and white on the raw
   * rarity hues is illegible at the bottom of the ladder — UNCOMMON green
   * measures about 2.3:1. The shades exist for filled backgrounds and run
   * 5.4:1 to 9.9:1, all of which clear AA for this weight.
   */
  accent?: string
}) {
  return (
    /* min-w-0 is load-bearing on every narrow viewport, and it is here rather
       than on each call site because a Panel is a grid item almost everywhere it
       appears. A grid item's automatic minimum size is its min-content width, and
       a Panel's min-content is whatever its widest table needs — the `overflow-x`
       on <Table> stops the table from painting outside the panel but does NOT
       stop the panel from demanding the room. At 375px that dragged the Overview
       grid to 482px inside a 327px column and pushed the whole document to a
       506px scrollWidth, so the body scrolled sideways on every route that laid
       two panels out side by side. With min-w-0 the track collapses to its share
       and the table scrolls inside itself, which is what it was always for. */
    <section
      className={`min-w-0 border border-ink bg-paper ${className}`}
      style={accent ? { borderColor: accent } : undefined}
    >
      {/* min-w-0 + truncate on the title and shrink-0 on the meta: without
          these the title wraps as a flex item and the bar grows to 2–4 rows. */}
      <header
        className="flex items-center justify-between gap-4 bg-ink px-3.5 py-2.5"
        style={accent ? { backgroundColor: accent } : undefined}
      >
        <h2 className="ui ui-11 min-w-0 truncate text-paper">{title}</h2>
        {right ? (
          <div className="ui ui-10 shrink-0 whitespace-nowrap text-paper/60">{right}</div>
        ) : null}
      </header>
      <div className={bodyClassName || 'p-4'}>{children}</div>
    </section>
  )
}

/** Stat tile — tiny m42 label, display numeral, quiet caption. */
export function Stat({
  label,
  value,
  sub,
  accent,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
  accent?: string
}) {
  return (
    <div className="border border-rule bg-paper px-3 py-3">
      <div className="ui ui-10 text-ink-mute">{label}</div>
      <div
        className="ui ui-18 mt-2 leading-none"
        style={accent ? { color: accent } : undefined}
      >
        {value}
      </div>
      {sub ? <div className="mt-2 text-[10px] leading-tight text-ink-faint">{sub}</div> : null}
    </div>
  )
}

/**
 * The rarity type colour, by tier.
 *
 * NOT `tier.color`. That value is the decorative one — the dot, the bar segment,
 * the card tint, the art's bottom rule — and it answers to the 3:1 threshold for
 * graphical objects. A badge is a word at 11–13px bold, which is normal text, so
 * it answers to 4.5:1, and the raw hues do not clear it: UNCOMMON measured
 * 2.78:1 and RARE 3.88:1 on paper. The four accessible values live together in
 * index.css so the ladder can be tuned as one thing.
 */
const TIER_TYPE: Record<string, string> = {
  entry: 'tier-entry',
  mid: 'tier-mid',
  expert: 'tier-epic',
  xrated: 'tier-xrated',
}

/**
 * Tier badge — colour lives in the *type*, not a filled block.
 *
 * EPIC drifts a violet gradient through the letters; X-RATED runs a laser
 * shine sweep with a fine ember emitter alongside. Both are deliberately
 * low-key: they should read as a sheen, not a light show.
 */
export function TierBadge({
  tier,
  size = 'sm',
  onDark = false,
}: {
  tier: Tier
  size?: 'sm' | 'lg'
  onDark?: boolean
}) {
  const text = size === 'lg' ? 'ui-12' : 'ui-11'

  // Inside a black bar, background-clip:text would knock the label out — and the
  // ladder inverts: `tier.light` is the value that clears AA against ink
  // (7.3:1–10.9:1), where the type colours used on paper sit at 4.1:1.
  if (onDark) {
    return (
      <span className={`ui ${text}`} style={{ color: tier.light }}>
        {tier.label}
      </span>
    )
  }

  if (tier.effect === 'laser') {
    return (
      <span className="relative inline-block align-middle">
        <span className={`ui ${text} tier-xrated relative`}>{tier.label}</span>
        <LabelFlames />
      </span>
    )
  }

  return <span className={`ui ${text} ${TIER_TYPE[tier.id] ?? ''}`}>{tier.label}</span>
}

/**
 * The serial, as a filled rarity plate with white type.
 *
 * `tier.shade`, not `tier.color`, for the same reason Panel's accent prop takes
 * the shade: white on the raw hues does not survive being read. Measured white
 * on `tier.color` — UNCOMMON 2.78:1, RARE 3.88:1, X-RATED 3.87:1, EPIC 4.72:1,
 * so three of the four failed outright. On the shades the same white runs
 * 5.07:1 (UNCOMMON), 6.72:1 (RARE), 8.60:1 (EPIC), 10.58:1 (X-RATED).
 *
 * The shadow stays. It is doing a different job from contrast: at 11px bold on a
 * saturated plate it keeps the glyph edges from bleeding into the fill.
 */
export function SerialTag({
  tier,
  children,
  className = '',
}: {
  tier: Tier
  children: ReactNode
  className?: string
}) {
  return (
    <span
      className={`ui ui-10 inline-block px-1.5 py-0.5 leading-none text-white ${className}`}
      style={{ background: tier.shade, textShadow: '0 1px 1px rgba(0,0,0,0.35)' }}
    >
      {children}
    </span>
  )
}

/**
 * Card treatment for a tier: matching border plus a faint tint of the same
 * colour. UNCOMMON returns nothing, so it keeps the plain white card.
 */
export function cardTone(tierId: string): string {
  return tierId === 'mid'
    ? 'card-mid'
    : tierId === 'expert'
      ? 'card-expert'
      : tierId === 'xrated'
        ? 'card-xrated'
        : ''
}

/** A tier's colour swatch — used in legends and distribution rows. */
export function TierDot({ tier }: { tier: Tier }) {
  return <span className="inline-block h-2.5 w-2.5 shrink-0" style={{ background: tier.color }} aria-hidden />
}

/** Small square chip. Monochrome by default — colour is reserved for rarity. */
export function Chip({
  children,
  tone = 'ink',
  title,
}: {
  children: ReactNode
  tone?: 'ink' | 'outline' | 'mute'
  title?: string
}) {
  const styles = {
    ink: 'bg-ink text-paper',
    outline: 'border border-ink text-ink',
    mute: 'border border-rule text-ink-mute',
  }[tone]
  return (
    <span title={title} className={`ui ui-10 inline-block px-1.5 py-1 ${styles}`}>
      {children}
    </span>
  )
}

/** Block button — square corners, solid fill. */
export function Button({
  children,
  onClick,
  variant = 'solid',
  disabled,
  type = 'button',
  className = '',
}: {
  children: ReactNode
  onClick?: () => void
  variant?: 'solid' | 'outline'
  disabled?: boolean
  type?: 'button' | 'submit'
  className?: string
}) {
  /* min-h-11 is 44px — the touch-target floor. The padding alone rendered these
     at 39px, which is under the mark on every phone. inline-flex rather than the
     block default so the label stays centred once the box is taller than its
     text; with `display:block` the extra height would all land under the label. */
  const base =
    'ui ui-11 inline-flex min-h-11 items-center justify-center px-4 py-2.5 transition-colors disabled:opacity-40 disabled:cursor-not-allowed'
  const styles =
    variant === 'solid'
      ? 'bg-ink text-paper hover:bg-ink-mute'
      : 'border border-ink text-ink hover:bg-ink hover:text-paper'
  return (
    <button type={type} onClick={onClick} disabled={disabled} className={`${base} ${styles} ${className}`}>
      {children}
    </button>
  )
}

export function LinkButton({ to, children }: { to: string; children: ReactNode }) {
  return (
    <Link
      to={to}
      className="ui ui-11 inline-flex min-h-11 items-center justify-center border border-ink px-4 py-2.5 text-ink transition-colors hover:bg-ink hover:text-paper"
    >
      {children}
    </Link>
  )
}

/* ---- Table ------------------------------------------------------------- */

export function Table({ children, className = '' }: { children: ReactNode; className?: string }) {
  return (
    <div className={`overflow-x-auto scrollbar-thin ${className}`}>
      <table className="w-full border-collapse text-[11px]">{children}</table>
    </div>
  )
}

export function Th({
  children,
  align = 'left',
  className = '',
}: {
  children?: ReactNode
  align?: 'left' | 'right' | 'center'
  className?: string
}) {
  return (
    <th
      className={`ui ui-10 border-b border-ink px-3 py-2.5 text-ink-mute ${
        align === 'right' ? 'text-right' : align === 'center' ? 'text-center' : 'text-left'
      } ${className}`}
    >
      {children}
    </th>
  )
}

export function Td({
  children,
  align = 'left',
  className = '',
  title,
}: {
  children?: ReactNode
  align?: 'left' | 'right' | 'center'
  className?: string
  title?: string
}) {
  return (
    <td
      title={title}
      className={`border-b border-rule px-3 py-2.5 ${
        align === 'right' ? 'text-right tabular-nums' : align === 'center' ? 'text-center' : 'text-left'
      } ${className}`}
    >
      {children}
    </td>
  )
}

/** Zebra row. */
export function Tr({ children, index = 0 }: { children: ReactNode; index?: number }) {
  return <tr className={index % 2 === 1 ? 'bg-wash' : ''}>{children}</tr>
}

/** Section heading used inside panel bodies. */
export function Heading({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <h3 className={`ui ui-11 mb-3 ${className}`}>{children}</h3>
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="border border-dashed border-rule px-4 py-12 text-center">
      <div className="ui ui-12 text-ink-mute">{title}</div>
      {children ? <div className="mt-3 text-[11px] text-ink-faint">{children}</div> : null}
    </div>
  )
}

/** Horizontal proportion bar, used for tier distribution and desk weights. */
export function Bar({ segments }: { segments: { value: number; color: string; label: string }[] }) {
  const total = segments.reduce((s, x) => s + x.value, 0) || 1
  return (
    <div className="flex h-3 w-full overflow-hidden border border-ink">
      {segments.map((s) => (
        <div
          key={s.label}
          title={`${s.label} — ${((s.value / total) * 100).toFixed(1)}%`}
          style={{ width: `${(s.value / total) * 100}%`, background: s.color }}
        />
      ))}
    </div>
  )
}

/** Numerals that should read small and quiet use the body face, not m42. */
export function Num({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <span className={`mono tabular-nums ${className}`}>{children}</span>
}

/**
 * A capital figure — deployed capital, portfolio value, book value.
 *
 * Green, because on a trading desk money is green. This and <Delta> are the
 * only places colour escapes the rarity system, and both earn it: a dashboard
 * of dollar figures in flat black reads as a spreadsheet, not a terminal.
 */
export function Money({ children, className = '' }: { children: ReactNode; className?: string }) {
  return (
    <span className={`mono tabular-nums font-medium text-money ${className}`}>{children}</span>
  )
}

/** A signed change. Green up, red down, muted em dash when there is no data. */
export function Delta({ value, decimals = 2 }: { value: number | undefined; decimals?: number }) {
  if (value === undefined || !Number.isFinite(value)) {
    return <span className="mono text-ink-faint">—</span>
  }
  const up = value >= 0
  return (
    <span className={`mono tabular-nums ${up ? 'text-up' : 'text-down'}`}>
      {up ? '▲' : '▼'} {Math.abs(value).toFixed(decimals)}%
    </span>
  )
}
