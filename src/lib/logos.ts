// symbol -> 16x16 pixel mark.
//
// Each tile is the company's own mark, redrawn pixel by pixel on a 16-grid: the
// apple, the four squares, the double-X, the smile arrow, the bitcoin B. This
// is nominative use — the mark identifies the asset
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
//                wordmark and have no symbol to draw (SoFi, Fiserv), and for
//                the fallback when a symbol reaches here before this table does.
//
// Pure and table-driven — no RNG anywhere. Hashing a symbol into a hue would be
// shorter and would give Costco a random teal.

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
// the identifying. Three of these are red — Exxon, Lilly, Costco — and they stay
// apart because the SHAPES are nothing alike: two spread X's, a script L, a C
// over a blue band.
//
// The roster is Robinhood's, so the table is keyed on Robinhood's tickers: no
// `x` suffix, because their tokens do not carry one. Six entries changed with
// the roster (see stocks.ts) — JPMorgan's octagon, Visa's card, Honeywell's
// forged H, Coca-Cola's contour bottle and P&G's monogram all left with the
// tokens they identified, since drawing a mark for an asset that is not on the
// chain is the one thing a ticker tile must never do.

const LOGOS: Record<string, LogoSpec> = {
  // The eye. Concentric rather than spiral: the real mark's curl closes to
  // sub-pixel width here, and a half-drawn spiral reads as damage.
  NVDA: {
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
  AAPL: {
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
  MSFT: {
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
  // SoFi, and one of only two monograms in the table. Their identity is the
  // wordmark "SoFi" set in a blue-to-green gradient — there is no symbol behind
  // it to redraw, and a gradient across 16 pixels is four flat bands. The app
  // icon is a single S on their blue, which is what this is.
  SOFI: { kind: 'monogram', bg: '#00a9e0', fg: '#ffffff', glyph: 'S' },

  // Fiserv, the other monogram, for the same reason: a lowercase wordmark in
  // their orange, and the 5x7 font is caps-only. The orange is doing most of
  // the identifying here, which is fine — it is the one orange in the tape
  // apart from Strategy's bitcoin, and that tile is a shape, not a letter.
  FISV: { kind: 'monogram', bg: '#ff6600', fg: '#ffffff', glyph: 'F' },

  // The double-X, drawn as two. The real mark interlocks — the first X's right
  // arm passes through the second's left — and every attempt at that here
  // collapsed: at 16px the shared region is 4px wide and fills in solid, so the
  // pair read as one spiky blob rather than as two X's. Set apart they are
  // unmistakably Exxon; interlocked they were unmistakably nothing.
  XOM: {
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

  // GE's roundel, as its silhouette: the badge is a circle with an ornate rim
  // and a script GE inside, and the script is hopeless here — two joined
  // letters in about 9px of interior come out as a smudge. The rim survives,
  // and the rim is what the badge reads as at a glance.
  //
  // Kept apart from COIN deliberately, since both are round: this is a THIN
  // WHITE OUTLINE on GE blue, that one is a SOLID blue disc with a square
  // punched out of it, on navy. Different ground, different fill, different
  // hole. The pair that actually collided was this and JPMorgan's octagon, and
  // JPMorgan is not on Robinhood Chain.
  GE: {
    kind: 'mark',
    bg: '#3874cb',
    ink: { '#': '#ffffff' },
    art: [
      '................',
      '.....######.....',
      '...##########...',
      '..###......###..',
      '..##........##..',
      '.##..........##.',
      '.##..........##.',
      '.##..........##.',
      '.##..........##.',
      '.##..........##.',
      '.##..........##.',
      '..##........##..',
      '..###......###..',
      '...##########...',
      '.....######.....',
      '................',
    ],
  },

  // Lilly's identity is a script wordmark. This is its initial in the same
  // hand — the loop and the swept foot are what make it Lilly and not an L.
  LLY: {
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
  UNH: {
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

  // Costco is a two-colour wordmark — COSTCO in red over WHOLESALE in blue —
  // and that stacking is what the eye actually catches, more than the letters.
  // So: the C in white on the red, with the blue band under it. Same trick the
  // Visa card tile used before Robinhood's book made it moot.
  //
  // This is a drawn mark rather than a third monogram on purpose. The test
  // holds the table to at most two, and two is already spent on SoFi and
  // Fiserv — a tape of initials stops being a tape and starts being a spreadsheet.
  COST: {
    kind: 'mark',
    bg: '#e31837',
    ink: { '#': '#ffffff', b: '#005daa' },
    art: [
      '................',
      '................',
      '....########....',
      '...##########...',
      '..###......###..',
      '..##........##..',
      '..##............',
      '..##............',
      '..##............',
      '..##........##..',
      '..###......###..',
      '...##########...',
      '....########....',
      '................',
      '.bbbbbbbbbbbbbb.',
      '................',
    ],
  },

  // The smile, with the arrowhead swept up at the a-to-z end. The wordmark
  // above it is not attempted: "amazon" at 16px is six glyphs in eleven
  // pixels. The arrow alone is the thing people recognise, and it is the only
  // orange curve in the tape.
  AMZN: {
    kind: 'mark',
    bg: '#232f3e',
    ink: { '#': '#ff9900' },
    art: [
      '................',
      '................',
      '................',
      '.............##.',
      '............###.',
      '...........####.',
      '.##........#####',
      '.###......###.##',
      '..###....###..##',
      '..####..###.....',
      '...########.....',
      '....######......',
      '................',
      '................',
      '................',
      '................',
    ],
  },

  // Not a company: the broad market. Four rising bars.
  SPY: {
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

  // Not a company either: a Treasury bill. SGOV is a fund that holds nothing else.
  SGOV: {
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
  GLD: {
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
  COIN: {
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
  MSTR: {
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

  // Derive a mark rather than throwing: a stock token added to the registry ahead
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
