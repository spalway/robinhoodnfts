// The compositor: a BackgroundSpec plus a PixelGrid in, an RGB buffer out.
//
// This is the half of <XployeeArt> that a browser normally does. The stacking
// order is copied from that component and is load-bearing:
//
//   1. the rarity background layer, filling the whole box
//   2. (the particle overlay — see NOTE below; the export omits it)
//   3. the character sprite, transparent outside its silhouette
//
// The tier frame is NOT part of the artwork. `.frame-xrated` and friends in
// src/index.css are a 3px border on the CONTAINER — one of them is an animated
// laser sweep — so they are chrome the site draws around the art, not pixels in
// it. Baking a border into 5,000 files would also bake in a 3px inset the site
// does not have.
//
// NOTE ON PARTICLES. The overlay is animated and has no canonical frame, so
// there is no still image of it to export. It is recorded in the metadata
// (`background.overlay`) and left unpainted. That decision is also, separately,
// forced: ParticleLayer in src/components/XployeeArt.tsx draws particles with
// `ctx.fillRect(Math.round(p.x), Math.round(p.y), ...)` while `p.x` and `p.y`
// are UNIT-SPACE 0–1 values (see the Particle docblock in src/lib/backgrounds.ts),
// so every particle currently rounds to 0 or 1 and the whole field paints into a
// 2x2 corner of a 48x48 canvas. Reproducing that faithfully would export a blob;
// reproducing it correctly would export something the site does not show. Until
// that component is fixed there is no answer that is both, so the export paints
// neither and says so.
import { deflateSync } from 'node:zlib'
import {
  compileFilter,
  parseBackgroundPosition,
  parseBackgroundSize,
  parseColor,
  parseRadialGradientDot,
  parseRepeatingLinearGradient,
  splitTopLevel,
} from './css.mjs'

/** Supersampling for gradient edges. Browsers antialias a hard stop; so do we. */
const SS_GRADIENT = 2
/** Star dots are 1–2 CSS px across, so their edges get a finer grid. */
const SS_DOT = 4

// ---------------------------------------------------------------------------
// background layers
// ---------------------------------------------------------------------------

function fillSolid(buf, size, color) {
  const [r, g, b] = color
  for (let i = 0; i < size * size * 3; i += 3) {
    buf[i] = r
    buf[i + 1] = g
    buf[i + 2] = b
  }
}

/**
 * repeating-linear-gradient, evaluated as distance along the gradient line.
 *
 * CSS measures the angle clockwise from "to top", so in a y-down buffer the
 * direction is (sin A, -cos A). The line passes through the box centre and its
 * length is |W sin A| + |H cos A| — the projection of the box onto it — which is
 * what puts the 0px stop at the corner the gradient starts from rather than at
 * the top-left of the box. Getting that origin wrong shifts every band by a
 * fraction of a period, which reads as "the rays are in the wrong place" and is
 * otherwise invisible.
 */
function fillLinearGradient(buf, size, grad, k) {
  const rad = (grad.angle * Math.PI) / 180
  const dx = Math.sin(rad)
  const dy = -Math.cos(rad)
  const length = Math.abs(size * dx) + Math.abs(size * dy)
  const cx = size / 2
  const cy = size / 2
  const sx = cx - (length / 2) * dx
  const sy = cy - (length / 2) * dy
  // t = (p - start) . d, expanded so the inner loop is one multiply-add.
  const t0 = -(sx * dx + sy * dy)

  const { stops, period, origin } = grad
  const n = stops.length

  const step = 1 / SS_GRADIENT
  const samples = SS_GRADIENT * SS_GRADIENT
  const half = step / 2

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let ar = 0
      let ag = 0
      let ab = 0
      for (let sj = 0; sj < SS_GRADIENT; sj++) {
        const py = y + half + sj * step
        for (let si = 0; si < SS_GRADIENT; si++) {
          const px = x + half + si * step
          // Device px -> CSS px, because the stop offsets are authored in CSS px.
          const t = (t0 + px * dx + py * dy) / k
          let u = (t - origin) % period
          if (u < 0) u += period
          u += origin
          let c = stops[n - 1].color
          for (let i = 0; i < n; i++) {
            if (u < stops[i].to) {
              c = stops[i].color
              break
            }
          }
          ar += c[0]
          ag += c[1]
          ab += c[2]
        }
      }
      const o = (y * size + x) * 3
      buf[o] = Math.round(ar / samples)
      buf[o + 1] = Math.round(ag / samples)
      buf[o + 2] = Math.round(ab / samples)
    }
  }
}

/**
 * A tiled radial-gradient dot layer — the stars over an EPIC ray field.
 *
 * `background-size` gives the tile, `background-position` offsets the first one.
 * Only the discs are visited rather than the whole box: at a 68px tile over a
 * 256px layer that is roughly sixteen 3-pixel circles, so scanning the other
 * 65,000 pixels to find them would dominate the cost of the entire image.
 */
function stampDots(buf, size, dot, tileCss, offsetCss, k) {
  const tw = tileCss[0] * k
  const th = tileCss[1] * k
  const ox = offsetCss[0] * k
  const oy = offsetCss[1] * k
  const radius = dot.radius * k
  const [dr, dg, db, da] = dot.color

  const firstI = Math.floor((0 - ox - dot.cxPct * tw - radius) / tw)
  const lastI = Math.ceil((size - ox - dot.cxPct * tw + radius) / tw)
  const firstJ = Math.floor((0 - oy - dot.cyPct * th - radius) / th)
  const lastJ = Math.ceil((size - oy - dot.cyPct * th + radius) / th)

  const step = 1 / SS_DOT
  const samples = SS_DOT * SS_DOT
  const half = step / 2
  const r2 = radius * radius

  for (let j = firstJ; j <= lastJ; j++) {
    const cy = oy + dot.cyPct * th + j * th
    for (let i = firstI; i <= lastI; i++) {
      const cx = ox + dot.cxPct * tw + i * tw

      const x0 = Math.max(0, Math.floor(cx - radius - 1))
      const x1 = Math.min(size - 1, Math.ceil(cx + radius + 1))
      const y0 = Math.max(0, Math.floor(cy - radius - 1))
      const y1 = Math.min(size - 1, Math.ceil(cy + radius + 1))

      for (let y = y0; y <= y1; y++) {
        for (let x = x0; x <= x1; x++) {
          let hits = 0
          for (let sj = 0; sj < SS_DOT; sj++) {
            const py = y + half + sj * step - cy
            for (let si = 0; si < SS_DOT; si++) {
              const px = x + half + si * step - cx
              if (px * px + py * py <= r2) hits++
            }
          }
          if (hits === 0) continue
          const cov = (hits / samples) * da
          const o = (y * size + x) * 3
          buf[o] = Math.round(buf[o] * (1 - cov) + dr * cov)
          buf[o + 1] = Math.round(buf[o + 1] * (1 - cov) + dg * cov)
          buf[o + 2] = Math.round(buf[o + 2] * (1 - cov) + db * cov)
        }
      }
    }
  }
}

/**
 * A cover-cropped, filtered photograph — the X-RATED backdrop.
 *
 * Sampling is nearest-neighbour because the declaration says
 * `image-rendering: pixelated`. Note that every source is WIDER than the square
 * box (829x360 down to 500x500), so cover is a downscale for six of the seven
 * scenes and a browser's `pixelated` downscale is not specified to the last
 * pixel — see the fidelity notes in scripts/README.md. The crop geometry and
 * the colour maths are exact; only which single source pixel a shrunk edge
 * lands on can differ, and never by more than one.
 */
function fillCoverImage(buf, size, image, filterSpec) {
  const { width: iw, height: ih, data } = image
  const scale = Math.max(size / iw, size / ih)
  const dw = iw * scale
  const dh = ih * scale
  const ox = (size - dw) / 2
  const oy = (size - dh) / 2

  const filter = filterSpec ? compileFilter(filterSpec) : null
  const out = new Uint8Array(3)

  // Column mapping is the same for every row, so resolve it once.
  const cols = new Int32Array(size)
  for (let x = 0; x < size; x++) {
    let sx = Math.floor((x + 0.5 - ox) / scale)
    if (sx < 0) sx = 0
    else if (sx >= iw) sx = iw - 1
    cols[x] = sx
  }

  for (let y = 0; y < size; y++) {
    let sy = Math.floor((y + 0.5 - oy) / scale)
    if (sy < 0) sy = 0
    else if (sy >= ih) sy = ih - 1
    const rowBase = sy * iw * 4 // jpeg-js hands back RGBA

    for (let x = 0; x < size; x++) {
      const s = rowBase + cols[x] * 4
      const o = (y * size + x) * 3
      if (filter) {
        filter(out, data[s], data[s + 1], data[s + 2])
        buf[o] = out[0]
        buf[o + 1] = out[1]
        buf[o + 2] = out[2]
      } else {
        buf[o] = data[s]
        buf[o + 1] = data[s + 1]
        buf[o + 2] = data[s + 2]
      }
    }
  }
}

/**
 * Paint one BackgroundSpec.style into `buf`.
 *
 * `k` converts CSS px to device px: the EPIC ray band and the star tiles are
 * authored in absolute CSS px, so the artwork genuinely depends on how large the
 * card is on screen — a 15px band is a sixth of a 96px thumbnail and a
 * seventeenth of a 256px card. There is therefore no single "correct" size, only
 * a chosen one; see cssSize in export-art.mjs.
 */
export function paintBackground(buf, size, spec, { cssSize, images }) {
  const style = spec.style
  const k = size / cssSize

  if (style.backgroundColor) fillSolid(buf, size, parseColor(style.backgroundColor))
  else fillSolid(buf, size, [0, 0, 0])

  if (!style.backgroundImage) return

  const layers = splitTopLevel(style.backgroundImage)
  const sizes = style.backgroundSize ? splitTopLevel(style.backgroundSize) : []
  const positions = style.backgroundPosition ? splitTopLevel(style.backgroundPosition) : []

  // In CSS the FIRST background-image layer paints on top, so the list is walked
  // backwards. raysSpec() relies on this: it lists three star layers ahead of
  // the ray field precisely so the stars land over the rays.
  for (let i = layers.length - 1; i >= 0; i--) {
    const layer = layers[i]

    if (layer.startsWith('repeating-linear-gradient(')) {
      fillLinearGradient(buf, size, parseRepeatingLinearGradient(layer), k)
      continue
    }

    if (layer.startsWith('radial-gradient(')) {
      const tile = parseBackgroundSize(sizes[i] ?? 'auto')
      if (!tile) throw new Error('paintBackground: a dot layer needs an explicit background-size')
      const offset = parseBackgroundPosition(positions[i] ?? '0 0')
      stampDots(buf, size, parseRadialGradientDot(layer), tile, offset, k)
      continue
    }

    if (layer.startsWith("url('") || layer.startsWith('url("') || layer.startsWith('url(')) {
      const url = /^url\(\s*['"]?(.*?)['"]?\s*\)$/s.exec(layer)
      if (!url) throw new Error(`paintBackground: unparseable url() layer ${layer}`)
      const image = images.get(decodeURIComponent(url[1]))
      if (!image) throw new Error(`paintBackground: no decoded image for ${url[1]}`)
      if (style.backgroundSize && style.backgroundSize.trim() !== 'cover') {
        throw new Error(`paintBackground: only background-size: cover is implemented`)
      }
      if (style.backgroundPosition && style.backgroundPosition.trim() !== 'center') {
        throw new Error(`paintBackground: only background-position: center is implemented`)
      }
      fillCoverImage(buf, size, image, style.filter)
      continue
    }

    throw new Error(`paintBackground: unsupported background layer ${layer}`)
  }
}

// ---------------------------------------------------------------------------
// character
// ---------------------------------------------------------------------------

/**
 * Blit the 32x32 bust over the background.
 *
 * Nearest-neighbour, matching `image-rendering: pixelated` on the sprite canvas.
 * `null` cells are the transparent silhouette gap that lets the backdrop through
 * — the reason avatar.ts never paints a background of its own.
 */
export function blitAvatar(buf, size, grid) {
  const gridSize = grid.length
  const palette = new Map()
  const colOf = new Int32Array(size)
  for (let x = 0; x < size; x++) colOf[x] = Math.floor((x * gridSize) / size)

  for (let y = 0; y < size; y++) {
    const row = grid[Math.floor((y * gridSize) / size)]
    for (let x = 0; x < size; x++) {
      const css = row[colOf[x]]
      if (!css) continue
      let rgb = palette.get(css)
      if (!rgb) {
        rgb = parseColor(css)
        palette.set(css, rgb)
      }
      const o = (y * size + x) * 3
      buf[o] = rgb[0]
      buf[o + 1] = rgb[1]
      buf[o + 2] = rgb[2]
    }
  }
}

/** Deflate of the raw pixels — a cheap, stable fingerprint for the run summary. */
export function pixelBytes(buf) {
  return deflateSync(buf, { level: 1 }).length
}
