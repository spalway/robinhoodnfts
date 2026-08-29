import { useEffect, useRef, useState } from 'react'
import { buildLogo, LOGO_GRID } from '../lib/logos'
import { STOCKS, type Stock } from '../lib/stocks'
import { signedPct, usd } from '../lib/format'

/**
 * The one place the monochrome rule is broken on purpose. A trading tape
 * without red and green is not a restrained tape, it is an unreadable one —
 * the sign of the move is the whole point of the strip.
 *
 * These read the tokens rather than restating hex. They used to be literals, and
 * the up-green had drifted a full stop lighter than `--color-up` — #16a34a
 * against paper measures 3.3:1, so the one figure the tape exists to communicate
 * was the one below AA. Anything that has to stay legible belongs to the token.
 */
const UP = 'text-up'
const DOWN = 'text-down'

/** Seconds for one full pass. Long, because a tape should read, not race. */
const CYCLE_S = 64

// The track holds two identical runs; sliding it from -50% to 0 walks exactly
// one run, so the wrap is invisible. Translating (not `left`) keeps the whole
// thing on the compositor — `left` would relayout sixteen canvases per frame.
const TAPE_CSS = `
@keyframes xnfts-tape {
  from { transform: translate3d(-50%, 0, 0); }
  to   { transform: translate3d(0, 0, 0); }
}
.xnfts-tape-track { animation: xnfts-tape ${CYCLE_S}s linear infinite; }
.xnfts-tape:hover .xnfts-tape-track,
.xnfts-tape:focus-within .xnfts-tape-track { animation-play-state: paused; }
`

function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(
    () =>
      typeof window !== 'undefined' &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches,
  )

  useEffect(() => {
    const query = window.matchMedia('(prefers-reduced-motion: reduce)')
    const onChange = () => setReduced(query.matches)
    query.addEventListener('change', onChange)
    return () => query.removeEventListener('change', onChange)
  }, [])

  return reduced
}

/** The pixel mark, painted 1:1 — the tile is authored at its display size. */
function LogoTile({ symbol, name }: { symbol: string; name: string }) {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = ref.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const grid = buildLogo(symbol)
    ctx.clearRect(0, 0, LOGO_GRID, LOGO_GRID)
    for (let y = 0; y < LOGO_GRID; y++) {
      for (let x = 0; x < LOGO_GRID; x++) {
        const color = grid[y][x]
        if (!color) continue
        ctx.fillStyle = color
        ctx.fillRect(x, y, 1, 1)
      }
    }
  }, [symbol])

  return (
    <canvas
      ref={ref}
      width={LOGO_GRID}
      height={LOGO_GRID}
      className="pixelated block shrink-0"
      style={{ width: LOGO_GRID, height: LOGO_GRID }}
      role="img"
      aria-label={name}
    />
  )
}

function TapeItem({
  stock,
  price,
  change,
}: {
  stock: Stock
  price: number
  change: number
}) {
  // Both maps are typed dense but arrive from the network, so a missing key is
  // a real runtime case. It shows as an em dash — never NaN, never 0.00%.
  const delta = typeof change === 'number' && Number.isFinite(change) ? change : null

  return (
    <div
      className="flex shrink-0 items-center gap-2 border-r border-rule px-3 py-1.5"
      title={`${stock.name} — ${stock.sector}`}
    >
      <LogoTile symbol={stock.symbol} name={stock.name} />

      <span className="ui ui-10 keep-case text-ink">${stock.symbol}</span>
      <span className="mono text-[11px] tabular-nums text-ink">{usd(price)}</span>
      {delta === null ? (
        <span className="mono text-[11px] text-ink-faint" title="no 24h data">
          —
        </span>
      ) : (
        <span className={`mono text-[11px] tabular-nums ${delta >= 0 ? UP : DOWN}`}>
          {signedPct(delta)}
        </span>
      )}
    </div>
  )
}

export function TickerTape({
  prices,
  change24h,
  className = '',
}: {
  prices: Record<string, number>
  change24h: Record<string, number>
  className?: string
}) {
  const reduced = usePrefersReducedMotion()

  const items = STOCKS.map((stock) => (
    <TapeItem
      key={stock.symbol}
      stock={stock}
      price={prices[stock.symbol]}
      change={change24h[stock.symbol]}
    />
  ))

  const shell = `border-t border-b border-ink bg-paper ${className}`

  // Reduced motion gets the same data as a plain strip the reader drives. The
  // scroll is scoped to this element either way, so the page never grows a
  // horizontal scrollbar because of the tape.
  if (reduced) {
    return (
      <section
        className={`overflow-x-auto scrollbar-thin ${shell}`}
        aria-label="Robinhood stock token ticker"
      >
        <div className="flex w-max">{items}</div>
      </section>
    )
  }

  // tabIndex is what makes the :focus-within pause reachable at all — nothing
  // inside the tape is focusable, so without a tab stop here the rule is dead
  // CSS and a keyboard user has no way to stop perpetual motion.
  return (
    <section
      className={`xnfts-tape overflow-hidden ${shell}`}
      aria-label="Robinhood stock token ticker"
      tabIndex={0}
    >
      <style href="xnfts-ticker-tape" precedence="medium">
        {TAPE_CSS}
      </style>
      <div className="xnfts-tape-track flex w-max will-change-transform">
        <div className="flex">{items}</div>
        {/* The second run only exists to fill the gap behind the first. */}
        <div className="flex" aria-hidden="true">
          {items}
        </div>
      </div>
    </section>
  )
}
