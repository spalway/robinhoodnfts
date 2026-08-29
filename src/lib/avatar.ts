// traits -> 32x32 pixel bust portrait.
//
// Pure: returns a grid of colour strings. Rendering (canvas, scaling, tier
// effects) lives in components/PixelAvatar.tsx so this stays testable and
// reusable for exports.
//
// The character NEVER paints a background. Every cell that is not part of the
// bust stays `null` so the scenic tier layer behind it shows through — which is
// also why the palette here is deliberately neutral: the background carries
// rarity, the character carries identity.
import { rngFrom, pick } from './rng'
import type { Xployee } from './xployee'

export const GRID = 32

export type PixelGrid = (string | null)[][]

// ---------------------------------------------------------------------------
// palette
// ---------------------------------------------------------------------------

/** Silhouette ink. Dark enough to hold the figure against busy scenic art. */
const OUTLINE = '#15131b'
/** Facial linework — warmer than OUTLINE so features don't read as holes. */
const LINE = '#2c2119'
const SCLERA = '#f4f1ec'
const GLINT = '#ffffff'
const PUPIL = '#191316'
const CORD = '#e8e3d8'
const SHIRT = '#eef0f4'
const SHIRT_DARK = '#c8ccd6'
const APRON = '#ded3bd'
const APRON_DARK = '#b3a68c'
const TIE = '#8f2f36'
const TIE_DARK = '#682027'
const STEEL = '#24262e'
const STEEL_LIT = '#464b59'

interface SkinTone {
  light: string
  base: string
  shadow: string
  deep: string
  blush: string
}

const SKINS: readonly SkinTone[] = [
  { light: '#ffeeda', base: '#f6d9bd', shadow: '#dcb595', deep: '#bd9070', blush: '#e79a8b' },
  { light: '#fbe0c2', base: '#f0c9a0', shadow: '#d3a77e', deep: '#b28460', blush: '#df8b79' },
  { light: '#f5d3a6', base: '#e8bd8e', shadow: '#c79a6c', deep: '#a67a4f', blush: '#d3826e' },
  { light: '#e5b98a', base: '#d1a06f', shadow: '#b07f52', deep: '#8d6238', blush: '#bc6e5b' },
  { light: '#c8956a', base: '#b07d4f', shadow: '#8e5f36', deep: '#6e4725', blush: '#9b5543' },
  { light: '#a06f45', base: '#8a5a34', shadow: '#6c4324', deep: '#4e2f18', blush: '#7c4331' },
  { light: '#7a533a', base: '#63402a', shadow: '#4a2e1c', deep: '#331e11', blush: '#5b3223' },
  { light: '#fce3cb', base: '#f2cdb0', shadow: '#d6a98a', deep: '#b6886a', blush: '#e28f7e' },
]

interface HairTone {
  base: string
  shine: string
  dark: string
}

const HAIRS: readonly HairTone[] = [
  { base: '#1c1b23', shine: '#3d3c50', dark: '#0e0d13' },
  { base: '#3b2a1e', shine: '#5e4531', dark: '#231a12' },
  { base: '#5d3f26', shine: '#836044', dark: '#3a2716' },
  { base: '#7a3b1f', shine: '#a75c33', dark: '#4c2412' },
  { base: '#c9a15c', shine: '#e8c98a', dark: '#9a7638' },
  { base: '#d8d2c3', shine: '#f3efe6', dark: '#a8a193' },
  { base: '#8f8f96', shine: '#b7b7bf', dark: '#64646b' },
  { base: '#4a4a52', shine: '#6e6e79', dark: '#2e2e34' },
  { base: '#a85526', shine: '#cf7c45', dark: '#793917' },
  { base: '#22202e', shine: '#454363', dark: '#131120' },
]

const IRISES = ['#3b2a1c', '#2c4a63', '#3a5a3f', '#4a3a5a', '#5a4632', '#2f3d4a', '#6b3a2a'] as const
const FRAMES = ['#26262e', '#6b5a3a', '#3a4a5a', '#8f8f97'] as const

interface Cloth {
  base: string
  dark: string
  light: string
}

/**
 * Fabric is chosen per uniform, never from the tier. Tier identity now lives in
 * the background layer, so tinting the character would double-signal it.
 */
const CLOTHS: Record<string, readonly Cloth[]> = {
  Coverall: [
    { base: '#3f5a7a', dark: '#2a3d54', light: '#5d7c9e' },
    { base: '#7b6b4a', dark: '#564a33', light: '#9c8b68' },
    { base: '#4e5a44', dark: '#36402f', light: '#6d7a62' },
  ],
  Suit: [
    { base: '#2b2f3d', dark: '#1a1d27', light: '#454b60' },
    { base: '#26262c', dark: '#161619', light: '#3d3d47' },
    { base: '#3a3340', dark: '#25202a', light: '#564c5a' },
  ],
  Vest: [
    { base: '#4a4136', dark: '#332c24', light: '#68594a' },
    { base: '#3b414d', dark: '#272b34', light: '#565d6c' },
    { base: '#523a3a', dark: '#382626', light: '#705353' },
  ],
  Polo: [
    { base: '#8b4444', dark: '#642f2f', light: '#ad6666' },
    { base: '#3f6b8c', dark: '#2c4c66', light: '#6390b0' },
    { base: '#4a7a58', dark: '#33573e', light: '#6d9d7b' },
    { base: '#6d6d78', dark: '#4d4d56', light: '#90909b' },
  ],
  Apron: [
    { base: '#5c6470', dark: '#40464f', light: '#7d8794' },
    { base: '#6b4f42', dark: '#4b372e', light: '#8d6c5c' },
  ],
  'Lab Coat': [{ base: '#e7eaef', dark: '#b9bfca', light: '#f8fafc' }],
  Hoodie: [
    { base: '#57606f', dark: '#3d4552', light: '#78828f' },
    { base: '#6b5b7a', dark: '#4c3f58', light: '#8d7c9c' },
    { base: '#4a5d52', dark: '#334239', light: '#6a7f73' },
    { base: '#7a5a4a', dark: '#573f33', light: '#9c7a68' },
  ],
  Overcoat: [
    { base: '#3a3226', dark: '#252018', light: '#564b39' },
    { base: '#2c3038', dark: '#1c1f25', light: '#464b56' },
    { base: '#453a3a', dark: '#2e2626', light: '#615252' },
  ],
}

const FALLBACK_CLOTH: Cloth = { base: '#4a4a52', dark: '#31313a', light: '#6b6b76' }

// ---------------------------------------------------------------------------
// geometry — every span is inclusive on both ends
// ---------------------------------------------------------------------------

/** Head silhouette, row by row, starting at HEAD_TOP. */
const HEAD_TOP = 5
const HEAD_ROWS: readonly (readonly [number, number])[] = [
  [11, 20], // 5
  [10, 21], // 6
  [10, 21], // 7
  [9, 22], //  8
  [9, 22], //  9
  [9, 22], // 10
  [9, 22], // 11
  [9, 22], // 12
  [9, 22], // 13
  [9, 22], // 14
  [9, 22], // 15
  [10, 21], // 16
  [10, 21], // 17
  [11, 20], // 18
  [12, 19], // 19
]

/** Rows above the skull, so hair can sit on top of the head with volume. */
const CROWN_TOP = 1
const CROWN_ROWS: readonly (readonly [number, number])[] = [
  [14, 17], // 1
  [13, 18], // 2
  [12, 19], // 3
  [11, 20], // 4
]

/** Shoulders / chest, starting at TORSO_TOP. */
const TORSO_TOP = 23
const TORSO_ROWS: readonly (readonly [number, number])[] = [
  [10, 21], // 23
  [8, 23], //  24
  [6, 25], //  25
  [5, 26], //  26
  [4, 27], //  27
  [3, 28], //  28
  [3, 28], //  29
  [3, 28], //  30
  [3, 28], //  31
]

const EYE_ROW = 12
const EYE_L = 11
const EYE_R = 18

function headSpan(y: number): readonly [number, number] | null {
  const i = y - HEAD_TOP
  return i >= 0 && i < HEAD_ROWS.length ? HEAD_ROWS[i] : null
}

function torsoSpan(y: number): readonly [number, number] | null {
  const i = y - TORSO_TOP
  return i >= 0 && i < TORSO_ROWS.length ? TORSO_ROWS[i] : null
}

/** Skull outline extended upward through the crown, optionally bulged sideways. */
function scalpSpan(y: number, bulge = 0): readonly [number, number] | null {
  const c = y - CROWN_TOP
  const raw = c >= 0 && c < CROWN_ROWS.length ? CROWN_ROWS[c] : headSpan(y)
  if (!raw) return null
  return [raw[0] - bulge, raw[1] + bulge]
}

// ---------------------------------------------------------------------------
// primitives
// ---------------------------------------------------------------------------

function blank(): PixelGrid {
  return Array.from({ length: GRID }, () => Array<string | null>(GRID).fill(null))
}

function px(g: PixelGrid, x: number, y: number, color: string) {
  if (y >= 0 && y < GRID && x >= 0 && x < GRID) g[y][x] = color
}

function rect(g: PixelGrid, x: number, y: number, w: number, h: number, color: string) {
  for (let yy = y; yy < y + h; yy++) {
    for (let xx = x; xx < x + w; xx++) px(g, xx, yy, color)
  }
}

/** Horizontal run, inclusive of x0 and x1 — the natural unit for row tables. */
function span(g: PixelGrid, y: number, x0: number, x1: number, color: string) {
  for (let x = x0; x <= x1; x++) px(g, x, y, color)
}

/** Paint a list of explicit points — used for brows, lapels and other curves. */
function dots(g: PixelGrid, points: readonly (readonly [number, number])[], color: string) {
  for (const [x, y] of points) px(g, x, y, color)
}

/** Mirror a point set about the face's centre line (x = 15.5). */
function mirrored(points: readonly (readonly [number, number])[]): (readonly [number, number])[] {
  return points.map(([x, y]) => [31 - x, y] as const)
}

// ---------------------------------------------------------------------------
// build
// ---------------------------------------------------------------------------

/**
 * Builds the bust.
 *
 * Layer order matters: neck before torso so collars can cut into it, hair after
 * the head so it covers the hairline, face after hair so brows stay readable,
 * accessories last, outline last of all.
 */
export function buildAvatar(x: Xployee): PixelGrid {
  const g = blank()
  const rng = rngFrom('avatar', x.mint)

  // Every roll happens up front, in a fixed order, so trait branches below can
  // never shift the RNG stream and change an unrelated feature.
  const skin = pick(rng, SKINS)
  const hair = pick(rng, HAIRS)
  const iris = pick(rng, IRISES)
  const frame = pick(rng, FRAMES)
  const cloth = pick(rng, CLOTHS[x.traits.uniform] ?? [FALLBACK_CLOTH])
  const gear = pick(rng, CLOTHS.Polo)
  const blush = rng() < 0.45

  drawNeck(g, skin)
  drawTorso(g, cloth)
  drawUniform(g, x.traits.uniform, cloth, skin)
  drawHead(g, skin)
  drawHair(g, x.traits.head, hair, skin, gear)
  drawFace(g, x.traits.face, skin, hair, iris, blush)
  drawAccessory(g, x.traits.accessory, frame)
  drawOutline(g)

  return g
}

// ---------------------------------------------------------------------------
// layers
// ---------------------------------------------------------------------------

function drawNeck(g: PixelGrid, skin: SkinTone) {
  // Runs under the collar; the torso paints over rows 23+.
  rect(g, 13, 20, 6, 5, skin.base)
  span(g, 20, 13, 18, skin.deep) // the chin throws a hard shadow
  span(g, 21, 13, 18, skin.shadow)
  px(g, 18, 22, skin.shadow)
  px(g, 13, 22, skin.shadow)
}

function drawTorso(g: PixelGrid, cloth: Cloth) {
  for (let y = TORSO_TOP; y < GRID; y++) {
    const s = torsoSpan(y)
    if (s) span(g, y, s[0], s[1], cloth.base)
  }

  // Key light sits top-left, so the far shoulder rolls into shadow.
  for (let y = 24; y <= 27; y++) {
    const s = torsoSpan(y)
    if (s) span(g, y, s[0], s[0] + 1, cloth.light)
  }
  for (let y = 25; y < GRID; y++) {
    const s = torsoSpan(y)
    if (s) span(g, y, s[1] - 2, s[1], cloth.dark)
  }

  // Fabric creases where the sleeve meets the body.
  dots(g, [[9, 27], [9, 28], [22, 27], [22, 28]], cloth.dark)
  span(g, 24, 10, 12, cloth.dark) // shoulder shadow under the collar
}

function drawUniform(g: PixelGrid, uniform: string, cloth: Cloth, skin: SkinTone) {
  switch (uniform) {
    case 'Suit': {
      span(g, 23, 13, 18, SHIRT)
      span(g, 24, 14, 17, SHIRT)
      span(g, 25, 14, 17, SHIRT)
      const lapel = [
        [13, 24],
        [13, 25],
        [14, 26],
        [14, 27],
        [15, 28],
      ] as const
      dots(g, lapel, cloth.light)
      dots(g, mirrored(lapel), cloth.light)
      dots(g, [[12, 23], [12, 24]], cloth.dark)
      dots(g, [[19, 23], [19, 24]], cloth.dark)
      // tie: knot, then a widening blade
      span(g, 25, 15, 16, TIE_DARK)
      span(g, 26, 15, 16, TIE)
      span(g, 27, 15, 16, TIE)
      span(g, 28, 16, 16, TIE)
      span(g, 29, 15, 17, TIE)
      span(g, 30, 15, 17, TIE)
      span(g, 31, 16, 16, TIE)
      px(g, 15, 26, TIE_DARK)
      break
    }

    case 'Overcoat': {
      span(g, 22, 12, 19, cloth.dark) // popped collar behind the neck
      span(g, 23, 14, 17, skin.shadow)
      const lapel = [
        [12, 23],
        [12, 24],
        [13, 24],
        [13, 25],
        [14, 25],
        [13, 26],
        [14, 26],
        [15, 26],
        [14, 27],
        [15, 27],
        [14, 28],
        [15, 28],
      ] as const
      dots(g, lapel, cloth.dark)
      dots(g, mirrored(lapel), cloth.dark)
      dots(g, [[11, 23], [11, 24], [12, 25], [12, 26], [13, 27], [13, 28]], cloth.light)
      dots(g, [[20, 23], [20, 24], [19, 25], [19, 26], [18, 27], [18, 28]], cloth.light)
      span(g, 29, 4, 27, cloth.dark) // belt
      span(g, 29, 15, 16, '#c9c4b4') // buckle
      break
    }

    case 'Lab Coat': {
      span(g, 23, 14, 17, skin.shadow)
      span(g, 24, 14, 17, '#495468') // tee under the coat
      span(g, 25, 15, 16, '#495468')
      dots(g, [[12, 23], [13, 23], [13, 24]], cloth.dark)
      dots(g, [[19, 23], [18, 23], [18, 24]], cloth.dark)
      for (let y = 26; y < GRID; y++) px(g, 15, y, cloth.dark) // button placket
      dots(g, [[15, 27], [15, 30]], '#9aa1ad')
      // patch pocket with a pen in it
      span(g, 27, 6, 9, cloth.dark)
      dots(g, [[6, 28], [9, 28], [6, 29], [9, 29]], cloth.dark)
      span(g, 30, 6, 9, cloth.dark)
      dots(g, [[8, 25], [8, 26]], '#2b6cb0')
      break
    }

    case 'Vest': {
      // Shirt sleeves and a V-neck read instantly as "waistcoat over shirt".
      for (let y = 26; y < GRID; y++) {
        const s = torsoSpan(y)
        if (!s) continue
        span(g, y, s[0], s[0] + 1, SHIRT)
        span(g, y, s[1] - 1, s[1], SHIRT)
      }
      span(g, 23, 12, 19, SHIRT)
      span(g, 24, 13, 18, SHIRT)
      span(g, 25, 14, 17, SHIRT)
      span(g, 26, 15, 16, SHIRT)
      span(g, 23, 14, 17, skin.shadow) // neck opening
      dots(g, [[12, 23], [13, 24], [14, 25], [15, 26]], cloth.dark)
      dots(g, [[19, 23], [18, 24], [17, 25], [16, 26]], cloth.dark)
      dots(g, [[13, 23], [14, 24], [15, 25]], SHIRT_DARK)
      for (let y = 27; y < GRID; y++) px(g, 15, y, cloth.dark)
      dots(g, [[16, 28], [16, 30]], cloth.light) // buttons
      break
    }

    case 'Apron': {
      span(g, 23, 12, 19, cloth.dark) // shirt collar band
      span(g, 23, 14, 17, skin.shadow)
      dots(g, [[13, 24], [13, 25], [14, 25]], APRON) // shoulder straps
      dots(g, [[18, 24], [18, 25], [17, 25]], APRON)
      rect(g, 12, 26, 8, 6, APRON)
      span(g, 26, 12, 19, APRON_DARK) // bib hem
      span(g, 29, 13, 18, APRON_DARK) // pocket mouth
      px(g, 15, 30, APRON_DARK)
      px(g, 16, 30, APRON_DARK)
      span(g, 30, 4, 11, APRON_DARK) // waist ties heading round the back
      span(g, 30, 20, 27, APRON_DARK)
      break
    }

    case 'Hoodie': {
      // Hood bunches beside the neck, then rolls across the shoulders.
      span(g, 22, 10, 12, cloth.dark)
      span(g, 22, 19, 21, cloth.dark)
      span(g, 23, 10, 21, cloth.dark)
      span(g, 24, 11, 20, cloth.base)
      dots(g, [[11, 22], [20, 22]], cloth.light)
      // drawstrings, deliberately uneven
      for (let y = 24; y <= 28; y++) px(g, 14, y, CORD)
      for (let y = 24; y <= 26; y++) px(g, 17, y, CORD)
      px(g, 14, 29, '#8a8578')
      px(g, 17, 27, '#8a8578')
      span(g, 29, 9, 22, cloth.dark) // kangaroo pocket
      dots(g, [[9, 30], [22, 30]], cloth.dark)
      break
    }

    case 'Polo': {
      span(g, 23, 12, 14, cloth.light) // collar wings
      span(g, 23, 17, 19, cloth.light)
      px(g, 12, 24, cloth.light)
      px(g, 19, 24, cloth.light)
      span(g, 23, 15, 16, skin.shadow)
      for (let y = 24; y <= 27; y++) span(g, y, 15, 16, cloth.light) // placket
      for (let y = 24; y <= 27; y++) px(g, 15, y, cloth.dark)
      dots(g, [[16, 25], [16, 27]], cloth.dark) // buttons
      span(g, 30, 3, 5, cloth.dark) // sleeve hems
      span(g, 30, 26, 28, cloth.dark)
      break
    }

    default: {
      // Coverall — the workwear default.
      span(g, 23, 12, 14, cloth.dark)
      span(g, 23, 17, 19, cloth.dark)
      span(g, 23, 15, 16, skin.shadow)
      for (let y = 24; y < GRID; y++) {
        px(g, 15, y, cloth.dark) // zip tape
        px(g, 16, y, cloth.light) // zip teeth catching the light
      }
      span(g, 27, 4, 27, cloth.dark) // yoke seam
      span(g, 28, 7, 10, cloth.dark) // pocket flaps
      span(g, 28, 21, 24, cloth.dark)
      dots(g, [[7, 29], [10, 29], [21, 29], [24, 29]], cloth.dark)
      dots(g, [[9, 25], [9, 26], [22, 25], [22, 26]], cloth.dark) // shoulder seams
      break
    }
  }
}

function drawHead(g: PixelGrid, skin: SkinTone) {
  for (let y = HEAD_TOP; y < HEAD_TOP + HEAD_ROWS.length; y++) {
    const s = headSpan(y)
    if (s) span(g, y, s[0], s[1], skin.base)
  }

  // Ears sit proud of the skull by a pixel so headsets have something to grip.
  dots(g, [[8, 12], [8, 13]], skin.base)
  px(g, 8, 14, skin.shadow)
  dots(g, [[23, 12], [23, 13], [23, 14]], skin.shadow)

  // Light from the top-left: the far edge of the face falls off.
  for (let y = 9; y <= 18; y++) {
    const s = headSpan(y)
    if (s) px(g, s[1], y, skin.shadow)
  }

  span(g, 8, 11, 16, skin.light) // forehead plane (usually under hair)
  dots(g, [[11, 15], [12, 15]], skin.light) // near cheekbone

  // Jawline and chin.
  span(g, 18, 11, 13, skin.shadow)
  span(g, 18, 18, 20, skin.shadow)
  span(g, 19, 12, 19, skin.shadow)
  px(g, 15, 19, skin.base)
  px(g, 16, 19, skin.base)
}

function drawHair(g: PixelGrid, style: string, hair: HairTone, skin: SkinTone, gear: Cloth) {
  switch (style) {
    case 'Bald': {
      // No hair, so the skull needs its own read: a specular cap plus stubble.
      span(g, 5, 13, 17, skin.light)
      span(g, 6, 12, 14, skin.light)
      px(g, 15, 6, skin.light)
      for (let y = 6; y <= 8; y++) {
        const s = headSpan(y)
        if (s) px(g, s[1], y, skin.shadow)
      }
      dots(g, [[9, 11], [9, 12], [9, 13], [22, 11], [22, 12], [22, 13]], hair.dark)
      break
    }

    case 'Sweep': {
      hairMass(g, hair.base, 3, 7, 0)
      // Fringe combed across the brow, low on the near side.
      span(g, 8, 9, 16, hair.base)
      span(g, 9, 9, 12, hair.base)
      dots(g, [[11, 4], [12, 4], [13, 5], [14, 5], [15, 6]], hair.shine)
      px(g, 13, 9, hair.dark) // the swept edge tucks under itself
      sideburns(g, hair.dark, 10, 12)
      hairShadow(g, skin, 8, 17, 21)
      hairShadow(g, skin, 9, 14, 20)
      break
    }

    case 'Bun': {
      hairMass(g, hair.base, 3, 7, 0)
      rect(g, 13, 1, 6, 3, hair.base) // top knot
      span(g, 0, 14, 17, hair.base)
      span(g, 1, 14, 17, hair.shine)
      span(g, 4, 14, 17, hair.dark) // the band that holds it
      dots(g, [[11, 5], [12, 5], [13, 4]], hair.shine)
      sideburns(g, hair.dark, 8, 10)
      hairShadow(g, skin, 8, 10, 21)
      break
    }

    case 'Mohawk': {
      hairMass(g, hair.dark, 5, 7, 0) // sides shaved to stubble
      span(g, 0, 15, 16, hair.base)
      rect(g, 14, 1, 4, 7, hair.base) // the crest
      for (let y = 1; y <= 7; y++) px(g, 15, y, hair.shine)
      px(g, 14, 1, hair.dark)
      px(g, 17, 1, hair.dark)
      hairShadow(g, skin, 8, 10, 21)
      break
    }

    case 'Cap': {
      hairMass(g, gear.base, 2, 7, 0)
      span(g, 8, 9, 22, gear.base) // band, pulled down over the hairline
      span(g, 1, 15, 16, gear.dark) // button
      span(g, 3, 12, 16, gear.light) // panel highlight
      px(g, 12, 5, gear.light)
      span(g, 9, 5, 15, gear.dark) // brim, worn to the near side
      span(g, 9, 6, 13, gear.base)
      sideburns(g, hair.base, 10, 12)
      px(g, 22, 9, hair.base) // hair escaping under the band
      hairShadow(g, skin, 9, 16, 21)
      break
    }

    case 'Helmet': {
      const SHELL = '#e8b830'
      const SHELL_DARK = '#a8801a'
      const SHELL_LIT = '#ffe07a'
      hairMass(g, SHELL, 2, 7, 1)
      span(g, 1, 13, 18, SHELL)
      span(g, 7, 9, 22, SHELL_DARK) // shell curls under above the brim
      for (let y = 1; y <= 7; y++) span(g, y, 15, 16, SHELL_LIT) // centre ridge
      dots(g, [[11, 3], [12, 3], [10, 4]], SHELL_LIT)
      span(g, 8, 7, 24, SHELL) // full brim
      span(g, 9, 8, 23, SHELL_DARK) // and its underside
      dots(g, [[9, 10], [9, 11], [22, 10], [22, 11]], STEEL) // chin strap
      hairShadow(g, skin, 10, 10, 21)
      break
    }

    case 'Curls': {
      hairMass(g, hair.base, 3, 8, 1)
      span(g, 9, 8, 11, hair.base) // volume spilling past the temples
      span(g, 9, 20, 23, hair.base)
      dots(g, [[8, 10], [9, 10], [22, 10], [23, 10]], hair.base)
      // Texture: offset bumps around the perimeter rather than a smooth edge.
      dots(g, [[11, 2], [13, 2], [15, 2], [17, 2], [19, 2]], hair.base)
      dots(g, [[12, 1], [16, 1], [18, 1]], hair.base)
      dots(g, [[13, 1], [17, 1], [10, 8], [21, 8]], hair.dark)
      dots(g, [[12, 3], [16, 3], [19, 4], [10, 6]], hair.shine)
      hairShadow(g, skin, 9, 12, 19)
      break
    }

    case 'Bowl': {
      hairMass(g, hair.base, 3, 8, 0)
      span(g, 9, 9, 22, hair.base) // blunt fringe, cut straight across
      span(g, 4, 12, 18, hair.shine)
      span(g, 9, 11, 20, hair.dark) // the cut edge sits in its own shadow
      for (let y = 10; y <= 13; y++) {
        px(g, 9, y, hair.base) // side flaps past the ears
        px(g, 22, y, hair.base)
      }
      hairShadow(g, skin, 10, 11, 20)
      break
    }

    case 'Tie-back': {
      hairMass(g, hair.base, 3, 7, 0)
      span(g, 4, 11, 19, hair.shine) // slicked back — one long unbroken shine
      span(g, 5, 12, 18, hair.dark)
      rect(g, 23, 8, 2, 8, hair.base) // tail falling behind the far ear
      dots(g, [[24, 16], [24, 17], [23, 16]], hair.base)
      dots(g, [[24, 10], [24, 13]], hair.shine)
      span(g, 8, 22, 24, hair.dark) // tie band
      sideburns(g, hair.dark, 9, 10)
      hairShadow(g, skin, 8, 10, 21)
      break
    }

    default: {
      // Crop — short, neat, squared off at the temples.
      hairMass(g, hair.base, 3, 7, 0)
      span(g, 4, 12, 18, hair.shine)
      px(g, 11, 5, hair.shine)
      span(g, 7, 10, 21, hair.dark) // clipper line just above the hairline
      span(g, 8, 9, 11, hair.base) // temples come down a row
      span(g, 8, 20, 22, hair.base)
      sideburns(g, hair.dark, 9, 11)
      hairShadow(g, skin, 8, 12, 19)
      break
    }
  }
}

/** Fills the skull outline for a row range — the shared base of every hairstyle. */
function hairMass(g: PixelGrid, color: string, top: number, bottom: number, bulge: number) {
  for (let y = top; y <= bottom; y++) {
    const s = scalpSpan(y, bulge)
    if (s) span(g, y, s[0], s[1], color)
  }
}

/** Hair falling in front of the ears. */
function sideburns(g: PixelGrid, color: string, top: number, bottom: number) {
  for (let y = top; y <= bottom; y++) {
    const s = headSpan(y)
    if (!s) continue
    px(g, s[0], y, color)
    px(g, s[1], y, color)
  }
}

/** The forehead directly under a hairline never catches the key light. */
function hairShadow(g: PixelGrid, skin: SkinTone, y: number, x0: number, x1: number) {
  span(g, y, x0, x1, skin.shadow)
}

function drawFace(
  g: PixelGrid,
  face: string,
  skin: SkinTone,
  hair: HairTone,
  iris: string,
  blush: boolean,
) {
  drawBrows(g, face, hair)
  drawEyes(g, face, skin, iris)
  drawNose(g, skin)
  drawMouth(g, face, skin)
  if (blush) {
    dots(g, [[10, 15], [11, 16], [10, 16]], skin.blush)
    dots(g, [[21, 15], [20, 16], [21, 16]], skin.blush)
  }
}

function drawBrows(g: PixelGrid, face: string, hair: HairTone) {
  // Brows carry most of the expression, so each face gets its own shape.
  let left: readonly (readonly [number, number])[]
  switch (face) {
    case 'Focused':
      left = [[10, 9], [11, 9], [12, 10], [13, 10]]
      break
    case 'Weary':
      left = [[10, 10], [11, 10], [12, 9], [13, 9]]
      break
    case 'Smirk':
      left = [[10, 10], [11, 10], [12, 10], [13, 10]]
      break
    case 'Grin':
      left = [[10, 10], [11, 9], [12, 9], [13, 10]]
      break
    case 'Scowl':
      left = [[10, 9], [11, 9], [12, 10], [13, 11]]
      break
    case 'Blank':
      left = [[10, 10], [11, 10], [12, 10]]
      break
    case 'Squint':
      left = [[10, 10], [11, 10], [12, 10], [13, 10], [11, 9], [12, 9]]
      break
    default:
      left = [[10, 10], [11, 10], [12, 10], [13, 10]]
      break
  }

  dots(g, left, hair.dark)
  // Smirk is the one asymmetric face: the far brow rides high on its own.
  dots(g, face === 'Smirk' ? [[18, 9], [19, 9], [20, 9], [21, 9]] : mirrored(left), hair.dark)
}

function drawEyes(g: PixelGrid, face: string, skin: SkinTone, iris: string) {
  for (const x0 of [EYE_L, EYE_R]) {
    const ix = x0 + 1 // both irises sit right of centre so the gaze reads level

    if (face === 'Squint') {
      span(g, EYE_ROW, x0, x0 + 2, SCLERA)
      span(g, EYE_ROW, ix, ix + 1, iris)
      span(g, EYE_ROW - 1, x0, x0 + 2, LINE)
      span(g, EYE_ROW + 1, x0, x0 + 2, LINE)
      continue
    }

    span(g, EYE_ROW, x0, x0 + 2, SCLERA)
    span(g, EYE_ROW + 1, x0, x0 + 2, SCLERA)
    span(g, EYE_ROW - 1, x0, x0 + 2, LINE) // lash line

    if (face === 'Blank') {
      // No iris at all — a vacant stare, just a pinprick pupil.
      px(g, ix, EYE_ROW + 1, PUPIL)
      continue
    }

    rect(g, ix, EYE_ROW, 2, 2, iris)
    px(g, ix + 1, EYE_ROW + 1, PUPIL)
    px(g, ix, EYE_ROW, GLINT) // catchlight

    if (face === 'Weary') {
      span(g, EYE_ROW, x0, x0 + 2, skin.shadow) // heavy lid over the top of the eye
      px(g, ix, EYE_ROW + 1, iris)
      px(g, ix + 1, EYE_ROW + 1, PUPIL)
      span(g, EYE_ROW + 2, x0, x0 + 2, skin.deep) // under-eye bags
    } else {
      span(g, EYE_ROW + 2, x0, x0 + 2, skin.shadow)
    }
  }
}

function drawNose(g: PixelGrid, skin: SkinTone) {
  px(g, 15, 14, skin.light) // bridge catches the key light
  px(g, 16, 14, skin.shadow)
  px(g, 16, 15, skin.shadow)
  px(g, 15, 16, skin.shadow)
  px(g, 16, 16, skin.deep) // nostril side
}

function drawMouth(g: PixelGrid, face: string, skin: SkinTone) {
  switch (face) {
    case 'Focused':
      span(g, 17, 14, 17, LINE)
      px(g, 13, 16, LINE)
      px(g, 18, 16, LINE)
      break
    case 'Weary':
      span(g, 18, 15, 16, LINE)
      px(g, 14, 17, skin.shadow)
      px(g, 17, 17, skin.shadow)
      break
    case 'Smirk':
      span(g, 17, 14, 17, LINE)
      px(g, 18, 16, LINE)
      px(g, 19, 16, LINE)
      px(g, 18, 17, skin.shadow)
      break
    case 'Grin':
      span(g, 17, 13, 18, LINE)
      span(g, 18, 14, 17, '#f0ece6') // teeth
      px(g, 13, 16, LINE)
      px(g, 18, 16, LINE)
      span(g, 19, 14, 17, skin.shadow) // lower lip
      break
    case 'Scowl':
      span(g, 17, 14, 17, LINE)
      px(g, 13, 18, LINE)
      px(g, 18, 18, LINE)
      break
    case 'Blank':
      span(g, 17, 15, 16, LINE)
      break
    case 'Squint':
      span(g, 17, 13, 18, LINE)
      break
    default:
      span(g, 17, 14, 17, LINE)
      px(g, 18, 17, skin.shadow)
      break
  }
}

function drawAccessory(g: PixelGrid, accessory: string, frame: string) {
  switch (accessory) {
    case 'Glasses':
      // Rims only — the lenses stay clear so the eyes still carry expression.
      for (const x0 of [10, 17]) {
        span(g, 11, x0, x0 + 4, frame)
        span(g, 14, x0, x0 + 4, frame)
        px(g, x0, 12, frame)
        px(g, x0, 13, frame)
        px(g, x0 + 4, 12, frame)
        px(g, x0 + 4, 13, frame)
      }
      span(g, 12, 15, 16, frame) // bridge
      px(g, 9, 11, frame) // temples heading for the ears
      px(g, 22, 11, frame)
      break

    case 'Shades':
      rect(g, 10, 11, 5, 3, '#191a20')
      rect(g, 17, 11, 5, 3, '#191a20')
      span(g, 12, 15, 16, '#191a20')
      dots(g, [[11, 12], [12, 11]], '#5b6478') // raked glint
      dots(g, [[18, 12], [19, 11]], '#5b6478')
      px(g, 9, 11, '#191a20')
      px(g, 22, 11, '#191a20')
      break

    case 'Visor':
      rect(g, 8, 11, 16, 3, STEEL)
      span(g, 12, 9, 22, '#7fe3ff')
      px(g, 11, 12, '#dffaff')
      px(g, 8, 14, STEEL)
      px(g, 23, 14, STEEL)
      break

    case 'Headset':
      // Band arcs over whatever the head trait already put there.
      span(g, 3, 13, 18, STEEL)
      dots(g, [[12, 4], [11, 5], [10, 6], [9, 7], [8, 8], [8, 9]], STEEL)
      dots(g, [[19, 4], [20, 5], [21, 6], [22, 7], [23, 8], [23, 9]], STEEL)
      rect(g, 7, 10, 2, 5, STEEL)
      rect(g, 23, 10, 2, 5, STEEL)
      px(g, 8, 11, STEEL_LIT)
      px(g, 8, 12, STEEL_LIT)
      dots(g, [[7, 15], [8, 16], [9, 17]], STEEL) // mic boom
      span(g, 18, 10, 11, STEEL_LIT)
      break

    case 'Earpiece':
      dots(g, [[23, 12], [23, 13], [22, 14], [21, 15]], '#26262e')
      px(g, 24, 12, '#8ad4ff')
      break

    case 'Badge':
      rect(g, 6, 27, 4, 4, '#f2f2f5')
      rect(g, 7, 28, 2, 2, '#7f8a9c')
      span(g, 30, 7, 8, '#b9bcc4')
      px(g, 7, 26, '#9a9aa2') // clip
      px(g, 8, 26, '#9a9aa2')
      break

    case 'Lanyard':
      dots(g, [[13, 23], [13, 24], [13, 25], [14, 26]], '#2f3a55')
      dots(g, [[18, 23], [18, 24], [18, 25], [17, 26]], '#2f3a55')
      rect(g, 14, 27, 4, 4, '#f2f2f5')
      span(g, 27, 14, 17, '#2f3a55')
      span(g, 29, 15, 16, '#a8adb8')
      break

    case 'Cigar':
      span(g, 18, 19, 22, '#6b4a2a')
      px(g, 19, 18, '#4a3218')
      px(g, 23, 18, '#ff8a3d') // ember
      break

    default:
      break // None
  }
}

/**
 * One-pixel silhouette outline, so the bust holds its shape over the detailed
 * city and space backdrops the rarer tiers sit on.
 *
 * Marks are collected before any are painted — otherwise the outline would
 * seed off itself and creep outward a ring at a time.
 */
function drawOutline(g: PixelGrid) {
  const marks: [number, number][] = []

  for (let y = 0; y < GRID; y++) {
    for (let x = 0; x < GRID; x++) {
      if (g[y][x] !== null) continue
      let touching = false
      for (let dy = -1; dy <= 1 && !touching; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          if (dx === 0 && dy === 0) continue
          const ny = y + dy
          const nx = x + dx
          if (ny < 0 || ny >= GRID || nx < 0 || nx >= GRID) continue
          if (g[ny][nx] !== null) {
            touching = true
            break
          }
        }
      }
      if (touching) marks.push([x, y])
    }
  }

  for (const [x, y] of marks) g[y][x] = OUTLINE
}
