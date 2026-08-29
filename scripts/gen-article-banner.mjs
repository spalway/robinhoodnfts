// The X article banner: the wordmark, centred, on ink.
//
//   node scripts/gen-article-banner.mjs
//
// 1600x900 — the 16:9 card X renders above a linked article. Deliberately plain:
// an article card is read at thumbnail size in a timeline, so it gets the
// wordmark, one line of positioning, and nothing else. The crew banner
// (scripts/gen-banner.ts) is the busy one, and it is 1500x500 for the profile
// header, which is a different slot.
//
// THE WORDMARK IS NOT A STRING. m42 is a 2001 caps-only bitmap face, so
// lowercase does not exist in it — "xNFTs" is faked exactly the way
// src/components/Layout.tsx fakes it, by setting the X and the S at a smaller
// size on the same baseline. Typing "xNFTs" and hoping would render XNFTS, which
// is the one thing the brand rule in src/index.css exists to prevent: the
// lowercase x is the brand.
import { Resvg } from '@resvg/resvg-js'
import { writeFileSync, readFileSync, existsSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'public', 'brand', 'x-article-banner.png')
const M42 = join(ROOT, 'public', 'fonts', 'm42.ttf')

const W = 1600
const H = 900

// Straight from src/index.css. Inverted, because the brand's banner ground is
// ink — see public/brand/x-banner.png, which is the same black.
const INK = '#000000'
const PAPER = '#ffffff'
/**
 * The subline's grey. ink-mute (#5f5f5f) is calibrated against white paper and
 * vanishes on ink, so this is its mirror — a comparable step down from the
 * ground rather than the same hex.
 */
const MUTE = '#9a9a9a'

/**
 * NFT's size in px, and the X/S size beside it.
 *
 * Both are multiples of 16 on purpose. m42 is a bitmap face on a 1024 em, so its
 * strokes sit on a coarse design grid; a size that is not a whole number of grid
 * steps rasterises some stems a pixel fatter than their neighbours, and on a
 * face this blocky that reads as a broken logo rather than as antialiasing.
 *
 * 176/104 is the closest pair on that grid to the CSS ratio (.wm-24 over .wm-42
 * is 0.571). It lands at 0.591 — a fifth of a device pixel at this size, invisible.
 */
const BIG = 176
const SMALL = 104

/** Gap from the wordmark's baseline down to the subline's. */
const SUB_GAP = 104
const SUB_SIZE = 44

/**
 * Roboto ships as woff2 only, which resvg's font database cannot read — it
 * handles ttf/otf/ttc and nothing else. So the subline falls back to whatever
 * grotesque the machine has. Arial is the closest common stand-in for Roboto's
 * proportions; Helvetica and Liberation Sans cover mac and linux.
 */
const SUB_STACK = 'Roboto, Arial, Helvetica, Liberation Sans, sans-serif'

if (!existsSync(M42)) {
  throw new Error(`m42 not found at ${M42} — run \`npm install\` (postinstall copies the fonts).`)
}

/**
 * The font's OWN family name, read out of its `name` table.
 *
 * Not the string in the CSS. src/index.css declares `@font-face { font-family:
 * 'm42' }`, which is a local alias a browser honours and a rasteriser knows
 * nothing about — resvg matches on the name baked into the file, which is
 * "M42_FLIGHT 721". Asking for "m42" got a silent fallback to Arial and a banner
 * whose logo was not the logo, which is the kind of wrong that ships.
 *
 * Read rather than hardcoded so replacing the .ttf cannot reintroduce it.
 */
function familyName(path) {
  const b = readFileSync(path)
  const tables = b.readUInt16BE(4)
  let nameOff = null
  for (let i = 0; i < tables; i++) {
    const p = 12 + i * 16
    if (b.toString('ascii', p, p + 4) === 'name') nameOff = b.readUInt32BE(p + 8)
  }
  if (nameOff === null) throw new Error(`${path} has no name table`)

  const count = b.readUInt16BE(nameOff + 2)
  const strings = nameOff + b.readUInt16BE(nameOff + 4)
  for (let i = 0; i < count; i++) {
    const r = nameOff + 6 + i * 12
    // nameID 1 is the family. Platform 3 (Windows) stores it UTF-16BE.
    if (b.readUInt16BE(r + 6) !== 1) continue
    const platform = b.readUInt16BE(r)
    const len = b.readUInt16BE(r + 8)
    const off = b.readUInt16BE(r + 10)
    const raw = b.subarray(strings + off, strings + off + len)
    return platform === 3 ? Buffer.from(raw).swap16().toString('utf16le') : raw.toString('latin1')
  }
  throw new Error(`${path} declares no family name`)
}

const WORDMARK_FAMILY = familyName(M42)

/** Nominal baseline. The centring pass below corrects whatever this lands on. */
const BASELINE = 460

function build(dx, dy) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <rect width="${W}" height="${H}" fill="${INK}"/>
  <g transform="translate(${dx.toFixed(2)} ${dy.toFixed(2)})">
    <!-- One <text> with three <tspan>s, not three <text> elements. They share a
         baseline and SVG advances each tspan by its own width, so text-anchor
         centres the whole run — three separately positioned texts would have to
         be measured and nudged by hand, and would drift on any size change. -->
    <text x="${W / 2}" y="${BASELINE}"
          text-anchor="middle"
          font-family="${WORDMARK_FAMILY}"
          fill="${PAPER}"><tspan font-size="${SMALL}">X</tspan><tspan font-size="${BIG}">NFT</tspan><tspan font-size="${SMALL}">S</tspan></text>

    <text x="${W / 2}" y="${BASELINE + SUB_GAP}"
          text-anchor="middle"
          font-family="${SUB_STACK}"
          font-size="${SUB_SIZE}"
          font-weight="500"
          letter-spacing="1.2"
          fill="${MUTE}">Powered by xStocks</text>
  </g>
</svg>`
}

function render(svg) {
  return new Resvg(svg, {
    background: INK,
    font: {
      fontFiles: [M42],
      // On for the subline only. m42 is loaded explicitly and matched by its own
      // family name above, so a stray system font cannot displace the logo.
      loadSystemFonts: true,
      defaultFontFamily: 'Arial',
    },
    fitTo: { mode: 'width', value: W },
  }).render()
}

/**
 * The bounding box of everything that is not the background.
 *
 * Centring by arithmetic does not work here. `text-anchor: middle` centres on
 * the text's ADVANCE width, which includes the side bearings either side of the
 * glyphs — and on a bitmap face those are lopsided enough to push the mark
 * visibly off centre. The vertical case is worse: the block's true extent runs
 * from the cap line of NFT to the descender of the subline, and no single
 * baseline number predicts it. So: render, look at the pixels, and move.
 */
function inkBounds(rendered) {
  const { width, height } = rendered
  const px = rendered.pixels
  let minX = width
  let minY = height
  let maxX = -1
  let maxY = -1

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4
      // Any lift off pure black counts, so a glyph's antialiased edge is part of
      // the mark rather than being trimmed off it.
      if (px[i] > 8 || px[i + 1] > 8 || px[i + 2] > 8) {
        if (x < minX) minX = x
        if (x > maxX) maxX = x
        if (y < minY) minY = y
        if (y > maxY) maxY = y
      }
    }
  }
  if (maxX < 0) throw new Error('nothing rendered — the banner is empty')
  return { minX, minY, maxX, maxY, w: maxX - minX + 1, h: maxY - minY + 1 }
}

// Pass 1: draw it wherever it falls and measure the result.
const probe = inkBounds(render(build(0, 0)))

// Pass 2: shift by the difference between the mark's centre and the canvas's.
const dx = W / 2 - (probe.minX + probe.maxX) / 2
const dy = H / 2 - (probe.minY + probe.maxY) / 2

const final = render(build(dx, dy))
const check = inkBounds(final)

writeFileSync(OUT, final.asPng())

const offX = (check.minX + check.maxX) / 2 - W / 2
const offY = (check.minY + check.maxY) / 2 - H / 2
console.log(`wrote ${OUT}`)
console.log(`  canvas    ${W}x${H}`)
console.log(`  mark      ${check.w}x${check.h}  (${((check.w / W) * 100).toFixed(1)}% of width)`)
console.log(`  centred   off by ${offX.toFixed(1)}px x, ${offY.toFixed(1)}px y`)
console.log(`  wordmark  ${WORDMARK_FAMILY} @ ${BIG}/${SMALL}`)
