import { describe, expect, it } from 'vitest'
import { LOGO_GRID, buildLogo, knownSymbols, logoFor } from './logos'
import { STOCKS } from './stocks'

/**
 * The marks are ASCII art, which means every defect in them is a typo that
 * still parses. A row one character short silently drops a column; a character
 * missing from the palette silently becomes ground. Neither throws, neither is
 * visible at 16px until someone squints at the tape. So these are the tests.
 */

describe('the art grids', () => {
  const marks = knownSymbols()
    .map((symbol) => [symbol, logoFor(symbol)] as const)
    .filter((entry): entry is [string, Extract<ReturnType<typeof logoFor>, { kind: 'mark' }>] =>
      entry[1].kind === 'mark',
    )

  it('draws a mark for nearly every ticker', () => {
    // Not all of them: an identity that is only a wordmark has no symbol to
    // draw. But if this ever drops far, the tape has quietly become monograms
    // again.
    expect(marks.length).toBeGreaterThanOrEqual(STOCKS.length - 2)
  })

  it.each(marks)('%s is exactly %d rows of %d', (symbol, spec) => {
    expect(spec.art).toHaveLength(LOGO_GRID)
    for (const [y, row] of spec.art.entries()) {
      expect(`${symbol} row ${y}: ${row.length}`).toBe(`${symbol} row ${y}: ${LOGO_GRID}`)
    }
  })

  it.each(marks)('%s paints every character it uses', (symbol, spec) => {
    // '.' is ground by convention. Anything else with no palette entry is a
    // typo that would have rendered as a hole in the mark.
    const unpainted = new Set<string>()
    for (const row of spec.art) {
      for (const ch of row) {
        if (ch !== '.' && !spec.ink[ch]) unpainted.add(ch)
      }
    }
    expect([symbol, [...unpainted]]).toEqual([symbol, []])
  })

  it.each(marks)('%s uses every colour it declares', (symbol, spec) => {
    // The other direction: a palette entry nothing references means the mark
    // was edited and the colour was left behind.
    const used = new Set([...spec.art.join('')])
    for (const ch of Object.keys(spec.ink)) {
      expect(`${symbol}:${ch} used`).toBe(`${symbol}:${ch} ${used.has(ch) ? 'used' : 'orphaned'}`)
    }
  })

  it.each(marks)('%s never draws in its own ground colour', (symbol, spec) => {
    // A mark painted the same colour as the tile is a blank tile, and it is
    // invisible in every way a reviewer would look for it.
    for (const [ch, color] of Object.entries(spec.ink)) {
      expect(`${symbol}:${ch}`).toBe(
        color.toLowerCase() === spec.bg.toLowerCase() ? `${symbol}:${ch} == bg` : `${symbol}:${ch}`,
      )
    }
  })

  it.each(marks)('%s is neither empty nor solid', (symbol, spec) => {
    const inked = [...spec.art.join('')].filter((ch) => ch !== '.').length
    const total = LOGO_GRID * LOGO_GRID
    // A mark that fills the tile has no silhouette left to recognise, and one
    // that fills almost none of it is a speck.
    expect(`${symbol} ${inked > total * 0.08 && inked < total * 0.8}`).toBe(`${symbol} true`)
  })
})

describe('buildLogo', () => {
  it('covers every xStock in the registry', () => {
    for (const stock of STOCKS) {
      const spec = logoFor(stock.symbol)
      // The fallback is black-on-white initials. Reaching it means the ticker
      // shipped without a mark.
      expect(`${stock.symbol} ${spec.bg}`).not.toBe(`${stock.symbol} #000000`)
    }
  })

  it.each(STOCKS.map((s) => s.symbol))('%s rasterises to a full grid', (symbol) => {
    const grid = buildLogo(symbol)
    expect(grid).toHaveLength(LOGO_GRID)
    for (const row of grid) expect(row).toHaveLength(LOGO_GRID)
  })

  it('knocks out the four extreme corners', () => {
    const grid = buildLogo('AAPLx')
    const last = LOGO_GRID - 1
    expect([grid[0][0], grid[0][last], grid[last][0], grid[last][last]]).toEqual([
      null,
      null,
      null,
      null,
    ])
  })

  it('paints something other than ground', () => {
    // Guards the whole rasteriser: if the art loop stopped matching palette
    // characters, every tile would come back as a flat rectangle of bg.
    for (const symbol of STOCKS.map((s) => s.symbol)) {
      const spec = logoFor(symbol)
      const distinct = new Set(buildLogo(symbol).flat().filter(Boolean))
      expect(`${symbol} ${distinct.size}`).not.toBe(`${symbol} 1`)
      expect(distinct.has(spec.bg)).toBe(true)
    }
  })

  it('falls back to initials for a symbol added ahead of the table', () => {
    const spec = logoFor('AMZNx')
    expect(spec).toEqual({ kind: 'monogram', bg: '#000000', fg: '#ffffff', glyph: 'AM' })
    expect(buildLogo('AMZNx')).toHaveLength(LOGO_GRID)
  })

  it('never blanks on a symbol the font cannot set', () => {
    // Every character unknown to the font is dropped, so a purely numeric or
    // symbolic ticker would normalise to the empty string.
    expect(logoFor('!!!')).toMatchObject({ glyph: 'X' })
    expect(buildLogo('!!!').flat().filter(Boolean).length).toBeGreaterThan(0)
  })
})
