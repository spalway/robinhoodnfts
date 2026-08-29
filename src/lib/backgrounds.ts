// tier -> background layer. Sits BEHIND a transparent character avatar, so
// every rule here is subordinate to legibility: the background carries rarity
// signal, the character carries identity, and the background never wins.
//
// Pure data. This module returns styles and particle state; nothing here
// touches the DOM, so the renderer can be swapped without touching art rules.
import type { CSSProperties } from 'react'
import type { Rng } from './rng'
import { pick, pickWeighted, randInt, rngFrom } from './rng'
import type { Xployee } from './xployee'

export type BgKind = 'solid' | 'rays' | 'image'
export type Overlay = 'none' | 'snow' | 'rain' | 'thunder' | 'sparks' | 'embers' | 'stars'

export interface BackgroundSpec {
  kind: BgKind
  /** Inline style for the background layer div. Always fully self-contained. */
  style: CSSProperties
  /** Animated particle overlay drawn on a canvas above the background, below the character. */
  overlay: Overlay
  /** Human-readable name for the xployee sheet, e.g. 'Neon Skyline', 'Ashfall'. */
  name: string
}

interface Swatch {
  color: string
  name: string
}

/**
 * UNCOMMON. Deliberately boring — office-supply neutrals. The dullness at the
 * bottom of the ladder is what makes the EPIC/X-RATED jump land.
 */
const UNCOMMON_SOLIDS: readonly Swatch[] = [
  { color: '#9aa0a6', name: 'Filing Grey' },
  { color: '#b4ada0', name: 'Manila' },
  { color: '#8d9686', name: 'Breakroom Sage' },
  { color: '#a7a29a', name: 'Drywall' },
  { color: '#7f8a93', name: 'Cubicle Slate' },
  { color: '#93a68c', name: 'Ledger Green' },
  { color: '#a3a8b0', name: 'Toner Dust' },
] as const

/** RARE. Vivid but still flat and tasteful, anchored on the tier blue. */
const RARE_SOLIDS: readonly Swatch[] = [
  { color: '#1d84de', name: 'Terminal Blue' },
  { color: '#1566b4', name: 'Deep Signal' },
  { color: '#2aa5e0', name: 'Ticker Cyan' },
  { color: '#3b5bdb', name: 'Index Indigo' },
  { color: '#0f9e8e', name: 'Liquidity Teal' },
  { color: '#5b4be0', name: 'Settlement Violet' },
  { color: '#1b6fa8', name: 'Custody Steel' },
] as const

/** EPIC ray hues. Crypto-PFP territory: magenta through violet into cyan. */
const RAY_HUES: readonly { h: number; name: string }[] = [
  { h: 316, name: 'Magenta' },
  { h: 334, name: 'Fuchsia' },
  { h: 288, name: 'Violet' },
  { h: 266, name: 'Ultraviolet' },
  { h: 196, name: 'Cyan' },
  { h: 172, name: 'Aqua' },
] as const

const RAY_ANGLES: readonly number[] = [28, 34, 45, 56, 124, 135, 146, 152] as const
const RAY_FORMS: readonly string[] = ['Rays', 'Burst', 'Slipstream', 'Prism', 'Cascade', 'Fracture'] as const

const EPIC_OVERLAYS: readonly { overlay: Overlay; weight: number }[] = [
  { overlay: 'stars', weight: 5 },
  { overlay: 'sparks', weight: 4 },
  { overlay: 'none', weight: 3 },
  { overlay: 'embers', weight: 2 },
] as const

interface Scene {
  file: string
  name: string
  /**
   * Weather that suits the scene — duplicates are the weighting. Rolled from a
   * per-scene pool because snow over a desert reads as a bug, not as rarity.
   */
  overlays: readonly Overlay[]
  /**
   * Mean perceived luminance of the source file, 0–255, measured off the actual
   * artwork rather than eyeballed.
   *
   * The sources span 13 (near-black vaporwave grid) to 172 (daylit ridgeline) —
   * a 13x range. Any single brightness range therefore either crushes the night
   * scenes to a black square or blows out the daylit ones, so brightness is
   * derived per scene to hit a target instead of rolled blind.
   */
  baseLuma: number
}

/**
 * Where an X-RATED backdrop should land on screen. Dark enough that the
 * character still separates from it, light enough that the scene reads as
 * artwork rather than a black tile.
 */
const TARGET_LUMA = 84

/**
 * X-RATED scenes. Left untouched on disk; every variant is a render-time
 * filter, so seven files cover the whole tier without a build step.
 */
const SCENES: readonly Scene[] = [
  {
    file: '360_F_1916540295_IsJKrZ9lR1xK0rTtYydRBtPDdbM01X7b.jpg',
    name: 'Comet Field',
    overlays: ['stars', 'stars', 'sparks'],
    baseLuma: 55,
  },
  {
    file: '8bit-pixel-desert-landscape-arcade-game-level-vector.jpg',
    name: 'Dune Sunset',
    overlays: ['embers', 'sparks', 'none'],
    baseLuma: 133,
  },
  {
    file: 'f45d03846b77e9f81c5311ff940077c0.jpg',
    name: 'Downtown Grid',
    overlays: ['rain', 'thunder', 'rain', 'none'],
    baseLuma: 18,
  },
  {
    file: 'images (1).jpg',
    name: 'Moonrise Skyline',
    overlays: ['snow', 'rain', 'stars'],
    baseLuma: 78,
  },
  {
    file: 'images (2).jpg',
    name: 'Ridgeline',
    overlays: ['snow', 'snow', 'rain', 'none'],
    baseLuma: 172,
  },
  {
    file: 'images (4).jpg',
    name: 'Still Water',
    overlays: ['snow', 'stars', 'none'],
    baseLuma: 141,
  },
  {
    file: 'images.jpg',
    name: 'Infinity Grid',
    overlays: ['stars', 'sparks', 'thunder'],
    baseLuma: 13,
  },
] as const

/**
 * Recolour buckets. Quantised rather than continuous so a variant is nameable
 * and so two xployees on the same scene never land a hue apart and look broken.
 */
const HUE_STEPS: readonly number[] = [0, 40, 80, 130, 180, 220, 270, 315] as const
const HUE_NAMES: readonly string[] = [
  'Native',
  'Ember',
  'Toxic',
  'Verdant',
  'Frozen',
  'Cobalt',
  'Violet',
  'Orchid',
] as const

const XRATED_DIR = '/texture-files/xrated/'

function solidSpec(rng: Rng, swatches: readonly Swatch[]): BackgroundSpec {
  const swatch = pick(rng, swatches)
  // No gradient, no texture, no overlay. Flat is the point.
  return { kind: 'solid', style: { backgroundColor: swatch.color }, overlay: 'none', name: swatch.name }
}

function raysSpec(rng: Rng): BackgroundSpec {
  const hue = pick(rng, RAY_HUES)
  const angle = pick(rng, RAY_ANGLES)
  const band = randInt(rng, 9, 17)
  const form = pick(rng, RAY_FORMS)

  // Lightness capped in the 18–46% band: bright enough to read as EPIC, dark
  // enough that a character sprite still separates from it.
  const t1 = `hsl(${hue.h} 82% 18%)`
  const t2 = `hsl(${hue.h} 78% 28%)`
  const t3 = `hsl(${hue.h} 88% 46%)`
  const t4 = `hsl(${(hue.h + 24) % 360} 84% 34%)`

  // Every stop is doubled at the same offset — that is what makes the edge hard
  // instead of a soft blend, which is the whole pixel look.
  const rays =
    `repeating-linear-gradient(${angle}deg, ` +
    `${t1} 0 ${band}px, ` +
    `${t2} ${band}px ${band * 2}px, ` +
    `${t3} ${band * 2}px ${band * 2 + Math.max(2, Math.round(band / 3))}px, ` +
    `${t4} ${band * 2 + Math.max(2, Math.round(band / 3))}px ${band * 3}px)`

  const tiles = [randInt(rng, 47, 79), randInt(rng, 53, 91), randInt(rng, 61, 103)]
  const offsets = [
    [randInt(rng, 0, 40), randInt(rng, 0, 40)],
    [randInt(rng, 0, 40), randInt(rng, 0, 40)],
    [randInt(rng, 0, 40), randInt(rng, 0, 40)],
  ]
  // Star dots: hard-stopped radial gradients tiled at coprime-ish sizes so the
  // repeat is not obvious. Listed first because earlier layers paint on top.
  const stars = [
    `radial-gradient(circle at 22% 31%, #ffffff 0 1.5px, rgba(255,255,255,0) 1.5px)`,
    `radial-gradient(circle at 68% 12%, #ffe6ff 0 1px, rgba(255,255,255,0) 1px)`,
    `radial-gradient(circle at 45% 77%, #d8f6ff 0 2px, rgba(255,255,255,0) 2px)`,
  ]

  return {
    kind: 'rays',
    style: {
      backgroundColor: t1,
      backgroundImage: [...stars, rays].join(', '),
      backgroundSize: [...tiles.map((t) => `${t}px ${t}px`), 'auto'].join(', '),
      backgroundPosition: [...offsets.map(([ox, oy]) => `${ox}px ${oy}px`), '0 0'].join(', '),
      backgroundRepeat: 'repeat',
    },
    overlay: pickWeighted(rng, EPIC_OVERLAYS, (e) => e.weight).overlay,
    name: `${hue.name} ${form}`,
  }
}

function imageSpec(rng: Rng): BackgroundSpec {
  const scene = pick(rng, SCENES)
  const step = randInt(rng, 0, HUE_STEPS.length - 1)
  const saturate = randInt(rng, 100, 175) / 100

  // Normalise each scene toward TARGET_LUMA rather than rolling a blind range.
  // The clamp ceiling is deliberately high: lifting the 13-luma grid needs ~6x,
  // and clamping that at 1.45 (the previous behaviour) left it rendering at 19 —
  // still a black square. Blown highlights on a neon skyline read as neon.
  const exposure = TARGET_LUMA / scene.baseLuma
  const jitter = randInt(rng, 90, 112) / 100
  const brightness = Math.round(Math.max(0.85, Math.min(6.5, exposure * jitter)) * 100) / 100

  // Dark sources get their contrast pulled back: multiplying a near-black image
  // up amplifies its noise, and extra contrast would crush the midtones we just
  // recovered.
  const contrastBase = scene.baseLuma < 40 ? randInt(rng, 78, 92) : randInt(rng, 95, 118)
  const contrast = contrastBase / 100

  return {
    kind: 'image',
    style: {
      // Sources run 2.4:1 to 1:1, so cover-crop is mandatory or the wide ones letterbox.
      backgroundImage: `url('${XRATED_DIR}${encodeURIComponent(scene.file)}')`,
      backgroundSize: 'cover',
      backgroundPosition: 'center',
      backgroundRepeat: 'no-repeat',
      imageRendering: 'pixelated',
      filter: `hue-rotate(${HUE_STEPS[step]}deg) saturate(${saturate}) brightness(${brightness}) contrast(${contrast})`,
    },
    overlay: pick(rng, scene.overlays),
    name: step === 0 ? scene.name : `${HUE_NAMES[step]} ${scene.name}`,
  }
}

// Identity-stable cache: React re-renders compare the style object, and a fresh
// object every call would churn the background layer on every tick of accrual.
const CACHE = new Map<string, BackgroundSpec>()

export function backgroundFor(x: Xployee): BackgroundSpec {
  const hit = CACHE.get(x.mint)
  if (hit) return hit

  const rng = rngFrom('bg', x.mint)
  let spec: BackgroundSpec
  switch (x.tier.id) {
    case 'xrated':
      spec = imageSpec(rng)
      break
    case 'expert':
      spec = raysSpec(rng)
      break
    case 'mid':
      spec = solidSpec(rng, RARE_SOLIDS)
      break
    default:
      spec = solidSpec(rng, UNCOMMON_SOLIDS)
      break
  }

  CACHE.set(x.mint, spec)
  return spec
}

// ---------------------------------------------------------------------------
// Particles
//
// Framework-free so the field can be stepped in a test without a compositor.
// The renderer owns the canvas; this owns the physics.
// ---------------------------------------------------------------------------

export interface Particle {
  /** Unit space, 0–1 across the layer. Multiply by canvas width/height to draw. */
  x: number
  y: number
  /** Unit-space velocity per frame at 60fps. */
  vx: number
  vy: number
  /** 1 fresh -> 0 spent; usable directly as alpha. For `stars` it is the twinkle phase. */
  life: number
  /** Draw size in device pixels. */
  size: number
}

/** Overlays that actually emit particles. */
type Emitting = Exclude<Overlay, 'none'>

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v
}

/**
 * One particle at its entry edge.
 *
 * `scatter` seeds it mid-flight instead, which matters only on the first frame:
 * without it every field opens as a curtain sweeping in from one side.
 */
function spawn(overlay: Emitting, rand: Rng, scatter: boolean): Particle {
  switch (overlay) {
    case 'snow': {
      const size = 1 + Math.floor(rand() * 3)
      return {
        x: rand(),
        y: scatter ? rand() : -0.02,
        vx: (rand() - 0.5) * 0.0016,
        // Bigger flakes fall faster — cheapest depth cue there is.
        vy: 0.0012 + size * 0.0006 + rand() * 0.0009,
        life: 1,
        size,
      }
    }
    case 'rain':
    case 'thunder':
      return {
        x: rand(),
        y: scatter ? rand() : -0.06,
        vx: -0.004 - rand() * 0.004,
        vy: 0.022 + rand() * 0.016,
        life: 1,
        size: 1 + Math.floor(rand() * 2),
      }
    case 'sparks':
      return {
        x: rand(),
        y: scatter ? rand() : 1.02,
        vx: (rand() - 0.5) * 0.003,
        vy: -0.004 - rand() * 0.006,
        life: scatter ? rand() : 1,
        size: 1 + Math.floor(rand() * 2),
      }
    case 'embers':
      return {
        x: rand(),
        y: scatter ? rand() : 1.02,
        vx: (rand() - 0.5) * 0.0018,
        vy: -0.0018 - rand() * 0.003,
        life: scatter ? rand() : 1,
        size: 2 + Math.floor(rand() * 3),
      }
    case 'stars': {
      const size = 1 + Math.floor(rand() * 3)
      return {
        // Stars are fixed points, so they always seed in place regardless of `scatter`.
        x: rand(),
        y: rand(),
        vx: 0,
        // Stars never translate; vy carries the twinkle rate instead. Bigger
        // stars breathe slower, which keeps the field from strobing in unison.
        vy: 0.014 - size * 0.003,
        life: rand(),
        size,
      }
    }
  }
}

export function seedParticles(overlay: Overlay, count: number, rand: () => number): Particle[] {
  if (overlay === 'none' || count <= 0) return []
  const out: Particle[] = []
  for (let i = 0; i < count; i++) out.push(spawn(overlay, rand, true))
  return out
}

/** Mutates in place — this runs every frame, so no allocation per particle. */
export function stepParticles(
  ps: Particle[],
  overlay: Overlay,
  w: number,
  h: number,
  rand: () => number,
): void {
  if (overlay === 'none' || ps.length === 0) return

  // Unit space is square. Scaling horizontal motion by the aspect keeps a
  // 30-degree rain streak at 30 degrees on a wide layer instead of shearing it.
  const aspect = w > 0 && h > 0 ? h / w : 1

  for (let i = 0; i < ps.length; i++) {
    const p = ps[i]

    switch (overlay) {
      case 'stars':
        // Phase only, and it wraps — a twinkle field must never go dark.
        p.life -= p.vy
        if (p.life <= 0) p.life += 1
        continue
      case 'snow':
        // Sway by nudging and clamping the velocity, so a flake needs no phase
        // field of its own.
        p.vx = clamp(p.vx + (rand() - 0.5) * 0.0006, -0.0018, 0.0018)
        break
      case 'sparks':
        p.vx += (rand() - 0.5) * 0.0012
        p.life -= 0.012
        break
      case 'embers':
        p.vx += (rand() - 0.5) * 0.0006
        p.life -= 0.006
        break
      default:
        break
    }

    p.x += p.vx * aspect
    p.y += p.vy

    // Wrap sideways so drift never thins the middle of the field.
    if (p.x < -0.05) p.x += 1.1
    else if (p.x > 1.05) p.x -= 1.1

    if (p.y > 1.06 || p.y < -0.1 || p.life <= 0) ps[i] = spawn(overlay, rand, false)
  }
}

export function particleColor(overlay: Overlay): string {
  switch (overlay) {
    case 'snow':
      return '#e8f2ff'
    case 'rain':
      return '#9fc4e8'
    case 'thunder':
      return '#cfe4ff'
    case 'sparks':
      return '#ffd166'
    case 'embers':
      return '#ff7a33'
    case 'stars':
      return '#fff6d8'
    case 'none':
      return 'transparent'
  }
}

export function particleCount(overlay: Overlay): number {
  switch (overlay) {
    case 'snow':
      return 90
    case 'rain':
      return 140
    case 'thunder':
      return 170
    case 'sparks':
      return 60
    case 'embers':
      return 45
    case 'stars':
      return 70
    case 'none':
      return 0
  }
}

/** Frames between possible strikes, and how long one strike lingers. */
const FLASH_PERIOD = 220
const FLASH_FRAMES = 7

/**
 * Alpha 0–1 for a full-frame lightning flash.
 *
 * The roll misses on some frames inside the window on purpose: a strike that
 * stutters reads as lightning, a smooth fade reads as a CSS transition.
 */
export function thunderFlash(frame: number, rand: () => number): number {
  const phase = ((frame % FLASH_PERIOD) + FLASH_PERIOD) % FLASH_PERIOD
  if (phase >= FLASH_FRAMES) return 0
  if (rand() > 0.7) return 0
  const decay = 1 - phase / FLASH_FRAMES
  return decay * (0.55 + rand() * 0.45)
}
