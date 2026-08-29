import { useEffect, useRef, useState } from 'react'
import { seedSparks, stepSparks, sparkColor, flameCount, type Spark } from '../lib/sparks'

/**
 * A flame field drawn ACROSS a label rather than beside it — embers rise over
 * the glyphs themselves.
 *
 * Two decisions make this readable instead of a mess:
 *  - It composites with 'lighter', so embers ADD light to the letters underneath
 *    instead of painting opaque blocks over them. Text stays legible.
 *  - Density is capped in flameCount(). Past ~70 particles the glyphs disappear.
 *
 * The canvas resizes to whatever it is stretched over, so it works on both the
 * small table badge and the large sheet badge without configuration.
 */
export function LabelFlames({ cell = 2 }: { cell?: number }) {
  const hostRef = useRef<HTMLSpanElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [box, setBox] = useState({ w: 0, h: 0 })

  // Track the label's rendered size; badge widths differ per rank and per page.
  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const measure = () => {
      const r = host.getBoundingClientRect()
      setBox({ w: Math.max(1, Math.round(r.width)), h: Math.max(1, Math.round(r.height)) })
    }
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const ro = new ResizeObserver(measure)
    ro.observe(host)
    return () => ro.disconnect()
  }, [])

  const W = Math.max(4, Math.round(box.w / cell))
  const H = Math.max(4, Math.round(box.h / cell))

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas || box.w === 0) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    // Decorative, so a local PRNG is fine — but never Math.random at module scope.
    let seed = W * 7349 + H * 91
    const rand = () => {
      seed = (seed * 1664525 + 1013904223) >>> 0
      return seed / 4294967296
    }

    const sparks: Spark[] = seedSparks(flameCount(W, H), W, H, rand)

    const draw = () => {
      ctx.clearRect(0, 0, W, H)
      ctx.globalCompositeOperation = 'lighter'
      for (const spark of sparks) {
        const t = spark.life / spark.maxLife
        ctx.fillStyle = sparkColor(spark)
        // Fade with height as well as age, so the top of the label stays clear.
        ctx.globalAlpha = Math.max(0, Math.min(1, t * 0.9)) * (0.35 + 0.65 * (spark.y / H))
        ctx.fillRect(Math.round(spark.x), Math.round(spark.y), 1, 1)
      }
      ctx.globalAlpha = 1
      ctx.globalCompositeOperation = 'source-over'
    }

    draw()

    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return

    let raf = 0
    const loop = () => {
      stepSparks(sparks, W, H, rand)
      draw()
      raf = requestAnimationFrame(loop)
    }
    raf = requestAnimationFrame(loop)
    return () => cancelAnimationFrame(raf)
  }, [W, H, box.w])

  return (
    <span ref={hostRef} className="pointer-events-none absolute inset-0 block">
      <canvas
        ref={canvasRef}
        width={W}
        height={H}
        className="pixelated block h-full w-full"
        aria-hidden="true"
      />
    </span>
  )
}
