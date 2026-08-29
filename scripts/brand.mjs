// Brand assets for X/Twitter: a 1500x500 header and a 400x400 avatar.
//
// Authored as SVG and rasterised with resvg rather than drawn by hand, so the
// two stay editable and can be re-rendered at any size. Both are built from the
// same tokens the site uses (index.css) — paper/ink, the four rarity hues, and
// the m42 wordmark — because a banner that invents its own palette stops
// reading as the same product the moment someone lands on the site.
//
//   npm run brand
import { Resvg } from '@resvg/resvg-js'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const OUT = join(ROOT, 'public', 'brand')
const M42 = join(ROOT, 'public', 'fonts', 'm42.ttf')

// index.css tokens. Kept as literals here on purpose: this script runs outside
// the bundle and cannot import CSS, so the duplication is unavoidable — but it
// is one place, and a drift is visible the moment the banner sits next to the
// site.
const INK = '#ededed'
const PAPER = '#1c1c1c'
const T1 = '#44af63' // UNCOMMON
const T2 = '#1d84de' // RARE
const T3 = '#d211b0' // EPIC
const T4 = '#ccff00' // X-RATED, at the darkened value the tan ground needs
const UP = '#157f3a'
const DOWN = '#dc2626'
const MUTE = '#5f5f5f'

function avatar() {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400">
  <rect width="400" height="400" fill="${PAPER}"/>

  <!-- The ink stroke, not the rarity red: on tan the frame's job is to give the
       tile an edge in a timeline, and a red one now competes with the bar below
       the glyph rather than framing it. -->
  <rect x="0" y="0" width="400" height="400" fill="none" stroke="${INK}" stroke-width="18"/>

  <!-- Sized and placed so the glyph plus its bar centre as ONE block. At 210 the
       X very nearly touched the frame and the pair sat high, leaving a dead
       band along the bottom that reads as a cropping mistake at avatar size. -->
  <text x="200" y="278" font-family="M42_FLIGHT 721" font-size="180" fill="${INK}"
        text-anchor="middle">X</text>

  <!-- The laser bar. Same gesture as the X-RATED frame animation on the site,
       held at its bright end because a still image cannot breathe. -->
  <rect x="130" y="298" width="140" height="10" fill="${T4}"/>
</svg>`
}

function render(svg, width, file) {
  const r = new Resvg(svg, {
    fitTo: { mode: 'width', value: width },
    font: { fontFiles: [M42], loadSystemFonts: true, defaultFontFamily: 'Segoe UI' },
    // m42 is a bitmap face; smoothing its edges defeats the whole point.
    shapeRendering: 2,
    imageRendering: 1,
  })
  const png = r.render().asPng()
  writeFileSync(file, png)
  return png.length
}

mkdirSync(OUT, { recursive: true })
const a = render(avatar(), 400, join(OUT, 'x-avatar.png'))
writeFileSync(join(OUT, 'x-avatar.svg'), avatar())

console.log(`avatar   400x400  ${(a / 1024).toFixed(1)} kB  -> public/brand/x-avatar.png`)
console.log(`sources                             -> public/brand/*.svg`)
