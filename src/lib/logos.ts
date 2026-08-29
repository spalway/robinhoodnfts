// symbol -> 16x16 pixel mark.
//
// Each tile is the company's own mark, redrawn pixel by pixel on a 16-grid: the
// apple, the four squares, the octagon, the interlocked double-X, the contour
// bottle, the bitcoin B. This is nominative use — the mark identifies the asset
// the desk actually trades, which is the same reason every brokerage puts a
// ticker logo next to a price. Nothing here is a lifted asset; there is no
// image file in the repo and no request to a brand's CDN. Every mark is
// hand-authored, and hand-authoring is also what makes them legible: these
// render at exactly 16px, and downsampling a 400px PNG to 16px turns the
// detailed ones (Circle's C, the Nvidia spiral) into grey mush.
//
// Two shapes of spec:
//
//   'mark'     — a drawn logo. Most tickers.
//   'monogram' — initials in the brand colour, for identities that ARE a
//                wordmark and have no symbol to draw (P&G), and for the
//                fallback when a symbol reaches here before this table does.
//
// Pure and table-driven — no RNG anywhere. Hashing a symbol into a hue would be
// shorter and would give Coca-Cola a random teal.

export interface MarkSpec {
  kind: 'mark'
  /** Tile ground; every '.' in `art`. */
  bg: string
  /** art character -> colour. A character with no entry is left as ground. */
  ink: Record<string, string>
  /** LOGO_GRID rows of LOGO_GRID characters. */
  art: readonly string[]
}

export interface MonogramSpec {
  kind: 'monogram'
  bg: string
  fg: string
  /** 1–2 characters, drawn from FONT. */
  glyph: string
}

export type LogoSpec = MarkSpec | MonogramSpec

export const LOGO_GRID = 16

// ---------------------------------------------------------------------------
// 5x7 pixel font — the monogram path only
// ---------------------------------------------------------------------------
//
// Hand-authored so each letter stays legible inside a 16px tile: 5 wide, 7
// tall, one clear pixel of counter in every enclosed shape. Wider "true" forms
// (a two-storey G, a tailed Q) get simplified rather than crammed — at this
// size a crammed glyph turns into a blob.

const FONT_W = 5
const FONT_H = 7

const FONT: Record<string, readonly string[]> = {
  A: ['.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
  B: ['####.', '#...#', '#...#', '####.', '#...#', '#...#', '####.'],
  C: ['.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.'],
  D: ['####.', '#...#', '#...#', '#...#', '#...#', '#...#', '####.'],
  E: ['#####', '#....', '#....', '####.', '#....', '#....', '#####'],
  F: ['#####', '#....', '#....', '####.', '#....', '#....', '#....'],
  G: ['.###.', '#...#', '#....', '#.###', '#...#', '#...#', '.###.'],
  H: ['#...#', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'],
  I: ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '#####'],
  J: ['..###', '...#.', '...#.', '...#.', '...#.', '#..#.', '.##..'],
  K: ['#...#', '#..#.', '#.#..', '##...', '#.#..', '#..#.', '#...#'],
  L: ['#....', '#....', '#....', '#....', '#....', '#....', '#####'],
  M: ['#...#', '##.##', '#.#.#', '#.#.#', '#...#', '#...#', '#...#'],
  N: ['#...#', '##..#', '#.#.#', '#.#.#', '#..##', '#...#', '#...#'],
  O: ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
  P: ['####.', '#...#', '#...#', '####.', '#....', '#....', '#....'],
  Q: ['.###.', '#...#', '#...#', '#...#', '#.#.#', '#..#.', '.##.#'],
  R: ['####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#'],
  S: ['.####', '#....', '#....', '.###.', '....#', '....#', '####.'],
  T: ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'],
  U: ['#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'],
  V: ['#...#', '#...#', '#...#', '#...#', '#...#', '.#.#.', '..#..'],
  W: ['#...#', '#...#', '#...#', '#.#.#', '#.#.#', '##.##', '#...#'],
  X: ['#...#', '#...#', '.#.#.', '..#..', '.#.#.', '#...#', '#...#'],
  Y: ['#...#', '#...#', '.#.#.', '..#..', '..#..', '..#..', '..#..'],
  Z: ['#####', '....#', '...#.', '..#..', '.#...', '#....', '#####'],
  '0': ['.###.', '#...#', '#..##', '#.#.#', '##..#', '#...#', '.###.'],
  '1': ['..#..', '.##..', '..#..', '..#..', '..#..', '..#..', '.###.'],
  '2': ['.###.', '#...#', '....#', '...#.', '..#..', '.#...', '#####'],
  '3': ['#####', '...#.', '..#..', '...#.', '....#', '#...#', '.###.'],
  '4': ['...#.', '..##.', '.#.#.', '#..#.', '#####', '...#.', '...#.'],
  '5': ['#####', '#....', '####.', '....#', '....#', '#...#', '.###.'],
  '6': ['..##.', '.#...', '#....', '####.', '#...#', '#...#', '.###.'],
  '7': ['#####', '....#', '...#.', '..#..', '.#...', '.#...', '.#...'],
  '8': ['.###.', '#...#', '#...#', '.###.', '#...#', '#...#', '.###.'],
  '9': ['.###.', '#...#', '#...#', '.####', '....#', '...#.', '.##..'],
}

// ---------------------------------------------------------------------------
// the marks
// ---------------------------------------------------------------------------
//
// Grounds are the brand's own colour, because at 16px the colour is doing half
// the identifying. Four of these are red — Exxon, Coca-Cola, Lilly — and they
// stay apart because the SHAPES are nothing alike: interlocked X's, a contour
// bottle, a script L. Honeywell, which would have been a fourth red tile, is
// inverted to red-on-black instead so the tape does not grow a red block.

const LOGOS: Record<string, LogoSpec> = {
  // The eye. Concentric rather than spiral: the real mark's curl closes to
  // sub-pixel width here, and a half-drawn spiral reads as damage.
  NVDAx: {
    kind: 'mark',
    bg: '#0b0b0b',
    ink: { '#': '#76b900' },
    art: [
      '................',
      '................',
      '................',
      '.....######.....',
      '...##########...',
      '..###......###..',
      '.###..####..###.',
      '.##..##..##..##.',
      '.##..##..##..##.',
      '.###..####..###.',
      '..###......###..',
      '...##########...',
      '.....######.....',
      '................',
      '................',
      '................',
    ],
  },

  // The apple. The bite is the right edge stepping in for four rows and back
  // out again; the notch at row 4 is the dip the leaf grows from.
  AAPLx: {
    kind: 'mark',
    bg: '#1d1d1f',
    ink: { '#': '#f5f5f7' },
    art: [
      '................',
      '..........##....',
      '.........##.....',
      '........##......',
      '....####.####...',
      '...###########..',
      '..###########...',
      '..##########....',
      '..##########....',
      '..##########....',
      '..###########...',
      '...##########...',
      '...##########...',
      '...###....###...',
      '....##.....##...',
      '................',
    ],
  },

  // The four squares, on charcoal rather than the official white: a white tile
  // on white paper is not a tile, it is a hole.
  MSFTx: {
    kind: 'mark',
    bg: '#2b2b30',
    ink: { r: '#f25022', g: '#7fba00', b: '#00a4ef', y: '#ffb900' },
    art: [
      '................',
      '................',
      '..rrrrr..ggggg..',
      '..rrrrr..ggggg..',
      '..rrrrr..ggggg..',
      '..rrrrr..ggggg..',
      '..rrrrr..ggggg..',
      '................',
      '................',
      '..bbbbb..yyyyy..',
      '..bbbbb..yyyyy..',
      '..bbbbb..yyyyy..',
      '..bbbbb..yyyyy..',
      '..bbbbb..yyyyy..',
      '................',
      '................',
    ],
  },

  // The Chase octagon. The real one is four trapezoids with radial gaps; the
  // gaps are one pixel wide at this size and close up the moment the browser
  // scales the canvas, so it is drawn as the ring they form.
  //
  // The hole is square and the corners are true 45-degree facets, both on
  // purpose: rounded off, this becomes a blue ring with a hole in it, which is
  // also what COINx is. The two sit six tiles apart in the tape.
  JPMx: {
    kind: 'mark',
    bg: '#117aca',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '.....######.....',
      '....########....',
      '...##########...',
      '..############..',
      '.####......####.',
      '.####......####.',
      '.####......####.',
      '.####......####.',
      '.####......####.',
      '.####......####.',
      '..############..',
      '...##########...',
      '....########....',
      '.....######.....',
      '................',
    ],
  },

  // Visa is a wordmark — "VISA" cannot be set at 16px — so this is the card:
  // the navy, the V, and the gold bar under it.
  Vx: {
    kind: 'mark',
    bg: '#1a1f71',
    ink: { '#': '#ffffff', g: '#f7b600' },
    art: [
      '................',
      '................',
      '.##..........##.',
      '.###........###.',
      '.###........###.',
      '..###......###..',
      '..###......###..',
      '...###....###...',
      '...###....###...',
      '....###..###....',
      '....###..###....',
      '.....######.....',
      '......####......',
      '................',
      '.gggggggggggggg.',
      '................',
    ],
  },

  // The double-X, drawn as two. The real mark interlocks — the first X's right
  // arm passes through the second's left — and every attempt at that here
  // collapsed: at 16px the shared region is 4px wide and fills in solid, so the
  // pair read as one spiky blob rather than as two X's. Set apart they are
  // unmistakably Exxon; interlocked they were unmistakably nothing.
  XOMx: {
    kind: 'mark',
    bg: '#ed1b2e',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '................',
      '................',
      '................',
      '##....####....##',
      '.##..##..##..##.',
      '..####....####..',
      '...##......##...',
      '...##......##...',
      '..####....####..',
      '.##..##..##..##.',
      '##....####....##',
      '................',
      '................',
      '................',
      '................',
    ],
  },

  // Honeywell: the forged H, its crossbar offset into two stepped bars. Red on
  // black rather than the official black on red — see the note above the table.
  HONx: {
    kind: 'mark',
    bg: '#141414',
    ink: { '#': '#ee1c25' },
    art: [
      '................',
      '................',
      '................',
      '..##........##..',
      '..##........##..',
      '..##........##..',
      '..##........##..',
      '..###########...',
      '...###########..',
      '..##........##..',
      '..##........##..',
      '..##........##..',
      '..##........##..',
      '................',
      '................',
      '................',
    ],
  },

  // Lilly's identity is a script wordmark. This is its initial in the same
  // hand — the loop and the swept foot are what make it Lilly and not an L.
  LLYx: {
    kind: 'mark',
    bg: '#c8102e',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '................',
      '.........####...',
      '........##..##..',
      '.......##...##..',
      '.......##..##...',
      '......###.##....',
      '......#####.....',
      '.....####.......',
      '.....###........',
      '....###.........',
      '....###.........',
      '....####........',
      '....##########..',
      '................',
      '................',
    ],
  },

  // The shield-U.
  UNHx: {
    kind: 'mark',
    bg: '#002677',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '................',
      '................',
      '..###......###..',
      '..###......###..',
      '..###......###..',
      '..###......###..',
      '..###......###..',
      '..###......###..',
      '..###......###..',
      '..###......###..',
      '..####....####..',
      '...##########...',
      '....########....',
      '................',
      '................',
    ],
  },

  // The contour bottle, not the ribbon. The ribbon's whole character is the
  // taper of its stroke, and a stroke that tapers between 2px and 1px does not
  // taper. The bottle survives the grid: neck, shoulder, waist, base.
  KOx: {
    kind: 'mark',
    bg: '#f40009',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '......####......',
      '.......##.......',
      '.......##.......',
      '......####......',
      '.....######.....',
      '....########....',
      '....########....',
      '.....######.....',
      '....########....',
      '...##########...',
      '...##########...',
      '...##########...',
      '...##########...',
      '....########....',
      '................',
    ],
  },

  // P&G is a wordmark with no symbol behind it, so this stays a monogram — the
  // one tile in the tape that is initials, and the reason the font below is not
  // dead code.
  PGx: { kind: 'monogram', bg: '#003da5', fg: '#ffffff', glyph: 'PG' },

  // Not a company: the broad market. Four rising bars.
  SPYx: {
    kind: 'mark',
    bg: '#1c2333',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '................',
      '.............###',
      '.............###',
      '.........###.###',
      '.........###.###',
      '.....###.###.###',
      '.....###.###.###',
      '.###.###.###.###',
      '.###.###.###.###',
      '.###.###.###.###',
      '.###.###.###.###',
      '.###.###.###.###',
      '.###.###.###.###',
      '................',
      '................',
    ],
  },

  // Not a company either: a bill.
  TBLLx: {
    kind: 'mark',
    bg: '#1b4d3e',
    ink: { '#': '#e8f3ec' },
    art: [
      '................',
      '................',
      '................',
      '................',
      '..############..',
      '..#..........#..',
      '..#...####...#..',
      '..#..#....#..#..',
      '..#..#....#..#..',
      '..#...####...#..',
      '..#..........#..',
      '..############..',
      '................',
      '................',
      '................',
      '................',
    ],
  },

  // A bar in three-quarter view. Three planes, not two: a lit top, a front,
  // and a shaded right side. Drawn with the top face as a stack of narrowing
  // rows it read as a mound — the shaded side is what makes it a solid.
  GLDx: {
    kind: 'mark',
    bg: '#241b00',
    ink: { '#': '#c9971f', l: '#f2cf62', d: '#8a6512' },
    art: [
      '................',
      '................',
      '................',
      '................',
      '...llllllllll...',
      '..llllllllllll..',
      '..##########dd..',
      '..##########dd..',
      '..##########dd..',
      '..##########dd..',
      '..##########dd..',
      '..##########dd..',
      '................',
      '................',
      '................',
      '................',
    ],
  },

  // The disc with the square knocked out. Coinbase blue on navy rather than
  // the official white on Coinbase blue: on a white tile the mark IS the
  // ground, and that would leave two blue rings in one tape (see JPMx).
  COINx: {
    kind: 'mark',
    bg: '#0a1733',
    ink: { '#': '#0052ff' },
    art: [
      '................',
      '.....######.....',
      '...##########...',
      '..############..',
      '..############..',
      '.##############.',
      '.#####....#####.',
      '.#####....#####.',
      '.#####....#####.',
      '.#####....#####.',
      '.##############.',
      '..############..',
      '..############..',
      '...##########...',
      '.....######.....',
      '................',
    ],
  },

  // Strategy holds bitcoin and is priced as a proxy for it, so the tape says
  // bitcoin. Their own mark is a wordmark; this is the thing on the balance
  // sheet, in the orange they rebranded into.
  MSTRx: {
    kind: 'mark',
    bg: '#f7931a',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '.....##...##....',
      '.....##...##....',
      '..###########...',
      '..############..',
      '..###.......##..',
      '..###......###..',
      '..###########...',
      '..###########...',
      '..###......###..',
      '..###.......##..',
      '..############..',
      '..###########...',
      '.....##...##....',
      '.....##...##....',
      '................',
    ],
  },
}

/** Neutral mark for a symbol not in the table — the tape must never blank. */
const FALLBACK: MonogramSpec = { kind: 'monogram', bg: '#000000', fg: '#ffffff', glyph: 'X' }

/**
 * Trim a glyph to something the font can actually draw. Table entries go
 * through this too, so an unknown character can never reach the renderer.
 */
function normaliseGlyph(raw: string): string {
  let out = ''
  for (const ch of raw.toUpperCase()) {
    if (!FONT[ch]) continue
    out += ch
    if (out.length === 2) break
  }
  return out || FALLBACK.glyph
}

export function logoFor(symbol: string): LogoSpec {
  const spec = LOGOS[symbol]
  if (spec) return spec.kind === 'mark' ? spec : { ...spec, glyph: normaliseGlyph(spec.glyph) }

  // Derive a mark rather than throwing: an xStock added to the registry ahead
  // of this table should still render, just without the drawn logo.
  const stem = symbol.endsWith('x') ? symbol.slice(0, -1) : symbol
  return { ...FALLBACK, glyph: normaliseGlyph(stem) }
}

/** Every symbol with a drawn mark. Exported for the tests that police them. */
export function knownSymbols(): string[] {
  return Object.keys(LOGOS)
}

// ---------------------------------------------------------------------------
// raster
// ---------------------------------------------------------------------------

type Grid = (string | null)[][]

function set(grid: Grid, x: number, y: number, color: string): void {
  if (x < 0 || y < 0 || x >= LOGO_GRID || y >= LOGO_GRID) return
  grid[y][x] = color
}

function drawChar(grid: Grid, ch: string, ox: number, oy: number, scale: number, color: string): void {
  const rows = FONT[ch]
  if (!rows) return
  for (let y = 0; y < FONT_H; y++) {
    for (let x = 0; x < FONT_W; x++) {
      if (rows[y][x] !== '#') continue
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          set(grid, ox + x * scale + sx, oy + y * scale + sy, color)
        }
      }
    }
  }
}

/**
 * LOGO_GRID x LOGO_GRID of colour strings, indexed [y][x] to match avatar.ts.
 *
 * The four extreme corner pixels come back `null`: knocking them out rounds the
 * tile just enough that a row of sixteen of these reads as a set of marks
 * rather than a row of colour swatches.
 */
export function buildLogo(symbol: string): (string | null)[][] {
  const spec = logoFor(symbol)
  const grid: Grid = Array.from({ length: LOGO_GRID }, () =>
    Array<string | null>(LOGO_GRID).fill(spec.bg),
  )

  if (spec.kind === 'mark') {
    for (let y = 0; y < LOGO_GRID; y++) {
      const row = spec.art[y] ?? ''
      for (let x = 0; x < LOGO_GRID; x++) {
        // A character with no palette entry — '.', or a typo — is ground. That
        // is what makes '.' mean "leave it" without a special case, and the
        // test below is what catches the typo.
        const color = spec.ink[row[x]]
        if (color) set(grid, x, y, color)
      }
    }
  } else if (spec.glyph.length >= 2) {
    // 5 + 1 gutter + 5 = 11 wide, sat on the optical centre line.
    drawChar(grid, spec.glyph[0], 2, 4, 1, spec.fg)
    drawChar(grid, spec.glyph[1], 8, 4, 1, spec.fg)
  } else {
    // A lone 5x7 letter is lost in a 16px tile, so it doubles to 10x14.
    drawChar(grid, spec.glyph[0], 3, 1, 2, spec.fg)
  }

  grid[0][0] = null
  grid[0][LOGO_GRID - 1] = null
  grid[LOGO_GRID - 1][0] = null
  grid[LOGO_GRID - 1][LOGO_GRID - 1] = null

  return grid
}
