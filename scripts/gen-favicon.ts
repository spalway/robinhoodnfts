// Render one xployee as the site favicon.
//
//   npx vite-node scripts/gen-favicon.ts
//
// Reuses the same generator the site renders and the same rasteriser
// scripts/export-art.mjs uses, so the tab icon is a real xployee rather than a
// drawing of one. A second implementation would agree today and drift on the
// first palette change.
import { writeFileSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
// @ts-expect-error — plain .mjs helpers, no type declarations
import { encodePng } from './lib/png.mjs'
// @ts-expect-error — plain .mjs helpers, no type declarations
import { paintBackground, blitAvatar } from './lib/paint.mjs'
import { buildAvatar } from '../src/lib/avatar'
import { backgroundFor } from '../src/lib/backgrounds'
import { collection } from '../src/lib/collection'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PUBLIC = join(ROOT, 'public')

/**
 * Which xployee is the face of the site.
 *
 * A RARE, deliberately, and not the X-RATED you might expect. X-RATED backdrops
 * are photographic JPEGs recoloured with CSS filters — gorgeous at 288px on the
 * xployee sheet and unreadable noise once a browser has squeezed them into a
 * 16px tab. RARE carries a flat vivid backdrop, so the silhouette still reads
 * when the whole image is sixteen pixels wide.
 *
 * Taken from the genesis crew rather than hardcoded, so it is a worker the site
 * actually shows rather than one that exists only here.
 */
function pickFace() {
  const crew = collection()
  const rare = crew.filter((x) => x.tier.id === 'mid')
  const chosen = rare[0] ?? crew[0]
  if (!chosen) throw new Error('collection is empty — nothing to render')
  return chosen
}

function renderAt(x: ReturnType<typeof pickFace>, size: number): Uint8Array {
  const buf = new Uint8Array(size * size * 3)
  // cssSize is the box the CSS background was authored against; the rasteriser
  // scales gradients and tiles from it. The avatar grid is 32, and the site
  // renders backgrounds against the same box, so they must agree here too.
  paintBackground(buf, size, backgroundFor(x), { cssSize: size, images: new Map() })
  blitAvatar(buf, size, buildAvatar(x))
  return encodePng({ width: size, height: size, rgb: buf })
}

const face = pickFace()

// 32 is the avatar's native grid, so this one is pixel-exact — no resampling at
// all. 180 is the iOS home-screen size; a whole multiple of 32 would be ideal
// but iOS wants 180, and nearest-neighbour from a 32-grid source stays crisp.
const outputs: [string, number][] = [
  ['favicon-32.png', 32],
  ['apple-touch-icon.png', 180],
]

for (const [name, size] of outputs) {
  writeFileSync(join(PUBLIC, name), renderAt(face, size))
  console.log(`${String(size).padStart(3)}px  ${name}`)
}

/**
 * The same worker as SVG, so the vector favicon is not a different picture from
 * the raster one.
 *
 * Emitted only when the backdrop is a flat colour — which is the case here and
 * is part of why a RARE was chosen. A gradient or a photographic scene would
 * need the whole CSS rasteriser reimplemented in SVG, and an SVG that only
 * approximated the PNG would be worse than not shipping one.
 */
function faviconSvg(x: ReturnType<typeof pickFace>): string | null {
  const bg = backgroundFor(x)
  const flat = bg.style.backgroundColor
  if (!flat || bg.style.backgroundImage) return null

  const grid = buildAvatar(x)
  const cells: string[] = []
  for (let y = 0; y < grid.length; y++) {
    for (let px = 0; px < grid[y].length; px++) {
      const colour = grid[y][px]
      // The avatar is transparent outside its silhouette — that is the invariant
      // the scenic backdrops depend on, and it means a null here is background
      // showing through, not a hole to fill.
      if (!colour) continue
      cells.push(`<rect x="${px}" y="${y}" width="1" height="1" fill="${colour}"/>`)
    }
  }

  return `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32" shape-rendering="crispEdges">
  <rect width="32" height="32" fill="${flat}"/>
  ${cells.join('\n  ')}
</svg>`
}

const svg = faviconSvg(face)
if (svg) {
  writeFileSync(join(PUBLIC, 'favicon.svg'), svg)
  console.log(` svg  favicon.svg`)
} else {
  console.log(' svg  SKIPPED — backdrop is not a flat colour; PNGs only')
}

console.log(
  `face: #${String(face.id).padStart(4, '0')}  ${face.tier.label}  ${backgroundFor(face).name}`,
)
