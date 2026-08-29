import { useEffect, useRef } from 'react'
import { buildLogo, LOGO_GRID } from '../lib/logos'

/**
 * A ticker's pixel mark.
 *
 * Authored at 16px and painted 1:1, then scaled by whole integers only — these
 * are hand-placed pixels, and a fractional scale resamples them into mush. See
 * logos.ts for the marks themselves.
 */
export function PixelLogo({
  symbol,
  size = 16,
  className = '',
}: {
  symbol: string
  size?: number
  className?: string
}) {
  const ref = useRef<HTMLCanvasElement>(null)
  const scale = Math.max(1, Math.round(size / LOGO_GRID))
  const px = LOGO_GRID * scale

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
      className={`pixelated block shrink-0 ${className}`}
      style={{ width: px, height: px }}
      role="img"
      aria-label={symbol}
    />
  )
}
