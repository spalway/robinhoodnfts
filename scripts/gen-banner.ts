// The X header: the xCorp wordmark, and nothing else.
//
//   npm run banner
//
// Text, on the site's own charcoal. This replaced a staggered V of seven portraits —
// good at showing what the art looks like, and wrong for a header, because a
// timeline crops it to a strip and the one job a header has is to say the name.
//
// Authored as SVG and rasterised rather than blitted pixel by pixel like the
// version before it: the whole image is one line of type now, and type is the
// one thing resvg does better than a hand-rolled canvas.
import { Resvg } from '@resvg/resvg-js'
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'public', 'brand')
const M42 = join(ROOT, 'public', 'fonts', 'm42.ttf')

const W = 1500
const H = 500

// index.css tokens. Restated because this runs outside the bundle and cannot
// import CSS — but a banner that invents its own palette stops reading as the
// same product the moment somebody lands on the site.
const PAPER = '#1c1c1c'
const INK = '#ededed'
const RULE = '#ccff00'  // the accent, and the only colour on the image
const MUTE = '#a3a3a3'

/**
 * m42's internal family name is NOT "m42".
 *
 * The file is m42.ttf, but its name table says `M42_FLIGHT 721`, and resvg
 * matches on the family in the table rather than on the filename. Asking for
 * "m42" falls through to the default font silently, which looks exactly like
 * the wordmark failing to load.
 */
const M42_FAMILY = 'M42_FLIGHT 721'

/**
 * How wide the wordmark should end up, and why this is measured not chosen.
 *
 * m42's advance is about 1.43x its font-size, so seven characters at a size
 * that seems reasonable in the abstract runs past 1500px and the x and the s
 * are clipped off both ends — which is what the first attempt did. `CAP` below
 * is therefore a starting guess that gets CORRECTED: render once, measure the
 * ink off the pixels, render again at the size that actually fits. A future
 * font swap then cannot silently overflow either.
 *
 * 820 of 1500 leaves ~340px of air each side, which keeps the whole
 * wordmark inside X's mobile crop.
 */
const TARGET_INK = 820
let CAP = 120

/**
 * The faked lowercase, and the ratio is the entire trick.
 *
 * m42 is a caps-only bitmap face, so the x and the s are simply set smaller —
 * that is what makes this read as "xCorp" rather than "XCORP". At 0.57,
 * which is what the site shipped with, they read as small capitals instead. A
 * real lowercase x-height is about half the cap height, so this and the `.wm-*`
 * sizes in index.css both sit near 0.48.
 */
const SMALL_RATIO = 0.48

/** All caps, no descenders, so optical centring means centring the cap band. */
const baselineFor = (cap: number) => Math.round(H / 2 - cap * 0.5 + cap * 0.86)

function banner(cap: number): string {
  const small = Math.round(cap * SMALL_RATIO)
  const y = baselineFor(cap)
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <rect width="${W}" height="${H}" fill="${PAPER}"/>
  <text x="${W / 2}" y="${y}" font-family="${M42_FAMILY}" fill="${INK}"
        text-anchor="middle" letter-spacing="6">
    <tspan font-size="${small}">X</tspan><tspan font-size="${cap}">CORP</tspan>
  </text>
  <rect x="${W / 2 - 210}" y="${y + 54}" width="420" height="5" fill="${RULE}"/>
  <text x="${W / 2}" y="${y + 100}" font-family="Geist, Segoe UI, sans-serif" font-size="21"
        fill="${MUTE}" text-anchor="middle" letter-spacing="7">GENERATIVE PIXEL WORKERS ON ROBINHOOD CHAIN</text>
</svg>`
}

function render(svg: string) {
  return new Resvg(svg, {
    fitTo: { mode: 'width', value: W },
    font: { fontFiles: [M42], loadSystemFonts: true, defaultFontFamily: 'Segoe UI' },
    // m42 is a bitmap face; smoothing its edges defeats the whole point.
    shapeRendering: 2,
    imageRendering: 1,
  }).render()
}

/** Horizontal extent of every pixel that is not the ground. */
function inkWidth(pixels: Buffer, w: number, h: number): number {
  let min = w
  let max = -1
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4
      const isGround =
        Math.abs(pixels[i] - 0x1c) < 12 &&
        Math.abs(pixels[i + 1] - 0x1c) < 12 &&
        Math.abs(pixels[i + 2] - 0x1c) < 12
      if (isGround) continue
      if (x < min) min = x
      if (x > max) max = x
    }
  }
  return max < 0 ? 0 : max - min + 1
}

mkdirSync(OUT, { recursive: true })

// Pass one: measure. At any cap size that fits, the wordmark is wider than the
// tagline, so the ink extent is the wordmark's.
const probe = render(banner(CAP))
const measured = inkWidth(probe.pixels, probe.width, probe.height)
if (measured > 0) CAP = Math.max(40, Math.round((CAP * TARGET_INK) / measured))

// Pass two: the one that ships.
const svg = banner(CAP)
const out = render(svg)
const png = out.asPng()
writeFileSync(join(OUT, 'x-banner.png'), png)
writeFileSync(join(OUT, 'x-banner.svg'), svg)

console.log(`banner ${W}x${H}  ${(png.length / 1024).toFixed(1)} kB  -> public/brand/x-banner.png`)
console.log(
  `cap ${CAP}  small ${Math.round(CAP * SMALL_RATIO)}  ink ${inkWidth(out.pixels, out.width, out.height)}px of ${W}`,
)
