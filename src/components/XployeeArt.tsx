import { useEffect, useRef } from 'react'
import { PixelAvatar } from './PixelAvatar'
import {
  backgroundFor,
  seedParticles,
  stepParticles,
  particleColor,
  particleCount,
  thunderFlash,
  type Overlay,
  type Particle,
} from '../lib/backgrounds'
import { rngFrom } from '../lib/rng'
import type { Xployee } from '../lib/xployee'

/**
 * Weather / particle layer. Sits above the background and below the character,
 * so snow falls *behind* the xployee rather than over its face.
 */
function ParticleLayer({ overlay, seed }: { overlay: Overlay; seed: string }) {
  const ref = useRef<HTMLCanvasElement>(null)

  // Logical particle space is small and scaled up, keeping the flakes chunky
  // enough to read as pixel art rather than as a soft-focus haze.
  const W = 48
  const H = 48

  useEffect(() => {
    const canvas = ref.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const rng = rngFrom('particles', seed)
    const particles: Particle[] = seedParticles(overlay, particleCount(overlay), rng)
    const color = particleColor(overlay)

    let frame = 0

    const draw = () => {
      ctx.clearRect(0, 0, W, H)

      if (overlay === 'thunder') {
        const flash = thunderFlash(frame, rng)
        if (flash > 0) {
          ctx.fillStyle = `rgba(255,255,255,${flash * 0.5})`
          ctx.fillRect(0, 0, W, H)
        }
      }

      ctx.fillStyle = color
      for (const p of particles) {
        ctx.globalAlpha = Math.max(0.2, Math.min(1, p.life))
        ctx.fillRect(Math.round(p.x), Math.round(p.y), p.size, overlay === 'rain' || overlay === 'thunder' ? p.size * 2 : p.size)
      }
      ctx.globalAlpha = 1
    }

    draw()

    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return

    let raf = 0
    const loop = () => {
      frame++
      stepParticles(particles, overlay, W, H, rng)
      draw()
      raf = requestAnimationFrame(loop)
    }
    raf = requestAnimationFrame(loop)
    return () => cancelAnimationFrame(raf)
  }, [overlay, seed])

  return (
    /* Stretched to the container rather than given a pixel size. The art box is
       `aspect-square w-full` wherever `fill` is set, so a fixed width left this
       48x48 field rendered at its natural size in the TOP-LEFT corner of a much
       larger card — a hard-edged square of weather sitting over one quarter of
       the portrait. Only EPIC and X-RATED carry overlays, which is why it only
       ever showed on those two. */
    <canvas
      ref={ref}
      width={W}
      height={H}
      className="pixelated pointer-events-none absolute inset-0 h-full w-full"
      aria-hidden="true"
    />
  )
}

/**
 * The full xployee artwork: rarity background, optional weather, character.
 *
 * The character canvas is transparent outside its silhouette, which is what
 * lets a scenic X-RATED background show through around it.
 */
/** Stroke treatment per tier. Same weight throughout — only the look changes. */
const FRAME: Record<string, string> = {
  entry: 'frame-entry',
  mid: 'frame-mid',
  expert: 'frame-expert',
  xrated: 'frame-xrated',
}

const STROKE = 3

export function XployeeArt({
  xployee,
  size = 96,
  className = '',
  animated = true,
  framed = true,
  fill = false,
  bottomRule = false,
}: {
  xployee: Xployee
  size?: number
  className?: string
  /** Grids of many cards disable this — 48 particle canvases is wasteful. */
  animated?: boolean
  /** Off for thumbnails already sitting inside someone else's border. */
  framed?: boolean
  /** Span the container as a square instead of a fixed size. Card grids use this. */
  fill?: boolean
  /**
   * Close the bottom edge with the tier colour.
   *
   * Unframed art inside a card runs straight into the card body, so the
   * portrait looks cut off. This gives it a proper sill and separates the art
   * from the data below it.
   */
  bottomRule?: boolean
}) {
  const bg = backgroundFor(xployee)
  const frame = framed ? (FRAME[xployee.tier.id] ?? '') : ''

  // The box is grown by the stroke rather than the art being shrunk by it:
  // with border-box sizing a 3px frame would otherwise eat 6px of character.
  const outer = framed ? size + STROKE * 2 : size

  return (
    <div
      className={`relative overflow-hidden ${fill ? 'aspect-square w-full' : ''} ${frame} ${className}`}
      style={{
        ...(fill ? {} : { width: outer, height: outer }),
        ...(bottomRule ? { borderBottom: `3px solid ${xployee.tier.color}` } : {}),
      }}
      title={`${xployee.tier.label} · ${bg.name}`}
    >
      {/*
        The backdrop is its OWN leaf layer, and that is load-bearing.

        bg.style carries a CSS filter for X-RATED scenes — exposure
        normalisation that reaches brightness(6.5) on the near-black sources.
        A filter applies to an element's entire subtree, so while this style sat
        on the container it also hit the two things sitting inside it: the
        character canvas was multiplied 6.5x and blew out to white, and
        hue-rotate spun the red laser border off-hue (180deg turns #ff1b1b
        cyan). Both looked like the backdrop had failed to load.

        Absolutely-positioned children resolve against the padding box, so
        inset-0 already stops at the frame — no background-clip needed.
      */}
      <div className="absolute inset-0" style={bg.style} aria-hidden="true" />
      {animated && bg.overlay !== 'none' ? (
        <ParticleLayer overlay={bg.overlay} seed={xployee.mint} />
      ) : null}
      <PixelAvatar xployee={xployee} size={size} fill={fill} className="absolute inset-0" />
    </div>
  )
}
