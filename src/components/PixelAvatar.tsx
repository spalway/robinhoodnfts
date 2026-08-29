import { useEffect, useRef } from 'react'
import { buildAvatar, GRID } from '../lib/avatar'
import type { Xployee } from '../lib/xployee'

interface Props {
  xployee: Xployee
  /** Rendered size in CSS pixels. Snapped to a multiple of GRID to stay crisp. */
  size?: number
  className?: string
  /**
   * Stretch to the container instead of snapping to an integer multiple.
   *
   * Card grids need this: a snapped size leaves a white gutter wherever the
   * column is not an exact multiple of 32. Non-integer scaling makes some pixel
   * rows one device-pixel wider than others, but `image-rendering: pixelated`
   * keeps every edge hard, so it still reads as pixel art — and a filled card
   * beats a crisp one floating in white.
   */
  fill?: boolean
}

/**
 * The character only — transparent everywhere outside its silhouette so the
 * rarity background layer shows through. Use <XployeeArt> for the composed
 * artwork; this is the bare sprite.
 */
export function PixelAvatar({ xployee, size = 96, className = '', fill = false }: Props) {
  const ref = useRef<HTMLCanvasElement>(null)
  const scale = Math.max(1, Math.round(size / GRID))
  const px = GRID * scale

  useEffect(() => {
    const canvas = ref.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const grid = buildAvatar(xployee)
    ctx.clearRect(0, 0, GRID, GRID)
    for (let y = 0; y < GRID; y++) {
      for (let x = 0; x < GRID; x++) {
        const color = grid[y][x]
        if (!color) continue
        ctx.fillStyle = color
        ctx.fillRect(x, y, 1, 1)
      }
    }
  }, [xployee])

  return (
    <canvas
      ref={ref}
      width={GRID}
      height={GRID}
      className={`pixelated block ${fill ? 'h-full w-full' : ''} ${className}`}
      style={fill ? undefined : { width: px, height: px }}
      role="img"
      aria-label={`xployee #${xployee.id}, ${xployee.tier.label}`}
    />
  )
}
