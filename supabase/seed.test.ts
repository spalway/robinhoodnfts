// The committed seed SQL, checked against the generator that produced it.
//
// ===========================================================================
// WHY THIS TEST EXISTS
// ===========================================================================
// The four seed migrations are ~750 KB of value tuples emitted by importing
// `src/lib` and walking every serial. That is the right way to produce them —
// the rows in Postgres and the objects in the browser come from one piece of
// code — but it has a failure mode with no natural alarm: the generator runs
// once, the output is committed, and from then on `src/lib` and the migration
// are two copies that nothing compares.
//
// A drift here is not subtle in its consequences and is completely invisible in
// its symptoms. Change a skill's weight, a trait array's order, or the shuffle
// seed, and the browser renders #1885 as a Chain Teller while the database says
// Bills Desk — with no error anywhere, because both are internally consistent.
//
// So this reads the migration files as data and re-derives every field. It is the
// only check in the repository that can catch that class of divergence, and it is
// cheap: parsing 5,000 tuples takes milliseconds.
//
// ===========================================================================
// WHAT IT DELIBERATELY DOES NOT DO
// ===========================================================================
// It does not execute SQL. There is no local Postgres on this machine (no
// Docker), so the assertions the DATABASE makes — the tier check constraint, the
// apy reconciliation, the permutation completeness block — are not exercised
// here. Those run at `db push` time and are documented in supabase/README.md.
// This file covers the other half: that the numbers being pushed are the right
// numbers.
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

import { MAX_SUPPLY, buildXployee, UNIFORMS, HEADS, FACES, ACCESSORIES } from '../src/lib/xployee'
import { mintOrder, HIRED_COUNT, collection, serialForMint } from '../src/lib/collection'
import { tierForId } from '../src/lib/tiers'
import { GENESIS } from '../src/lib/accrual'
import { networkWallets } from '../src/lib/network'
import { SKILLS } from '../src/lib/skills'
import { STOCKS } from '../src/lib/stocks'

const DIR = new URL('./migrations/', import.meta.url)

function migration(name: string): string {
  return readFileSync(new URL(name, DIR), 'utf8')
}

/**
 * Splits one `(a,'b',c)` tuple into its fields.
 *
 * Hand-rolled rather than regexed per shape, because the background names are
 * free text and a positional regex would silently mis-split the first one that
 * contained a comma. This walks the string and only treats a comma as a
 * separator when it is outside a quoted literal — which is also how Postgres
 * reads it, so the parser and the database agree about where a field ends.
 */
function fields(tuple: string): string[] {
  const out: string[] = []
  let current = ''
  let quoted = false
  for (let i = 0; i < tuple.length; i++) {
    const ch = tuple[i]
    if (quoted) {
      // '' is an escaped apostrophe inside a SQL string literal, not the end.
      if (ch === "'" && tuple[i + 1] === "'") {
        current += "'"
        i++
      } else if (ch === "'") {
        quoted = false
      } else {
        current += ch
      }
      continue
    }
    if (ch === "'") {
      quoted = true
    } else if (ch === ',') {
      out.push(current.trim())
      current = ''
    } else {
      current += ch
    }
  }
  out.push(current.trim())
  // A trailing `::timestamptz` (or any other cast) belongs to the SQL, not to the
  // value. Stripped here rather than at each call site so a column that grows a
  // cast later does not quietly start failing a date comparison.
  return out.map((f) => f.replace(/::[a-z_ ]+$/i, '').trim())
}

/**
 * The value list of one INSERT, without the column list before it or the clauses
 * after it.
 *
 * Both ends matter. Starting at the statement would make the parser read the
 * COLUMN list as a tuple; running to the end of the file would make it read
 * `count(*)` inside the assertion blocks as one.
 */
function valuesBlock(sql: string, startMarker: string, endMarker = ';'): string {
  const from = sql.indexOf(startMarker)
  if (from < 0) throw new Error(`seed test: could not find ${startMarker}`)
  const values = sql.indexOf(' values', from)
  const to = sql.indexOf(endMarker, values)
  return sql.slice(values + ' values'.length, to < 0 ? undefined : to)
}

/** Every `(...)` value tuple in a migration's INSERT body. */
function tuples(sql: string): string[][] {
  const out: string[][] = []
  let depth = 0
  let current = ''
  let quoted = false
  for (let i = 0; i < sql.length; i++) {
    const ch = sql[i]
    if (quoted) {
      if (ch === "'" && sql[i + 1] === "'") {
        current += "''"
        i++
      } else {
        if (ch === "'") quoted = false
        current += ch
      }
      continue
    }
    if (ch === "'") {
      quoted = true
      if (depth > 0) current += ch
      continue
    }
    if (ch === '(') {
      depth++
      if (depth === 1) {
        current = ''
        continue
      }
    }
    if (ch === ')') {
      depth--
      if (depth === 0) {
        out.push(fields(current))
        continue
      }
    }
    if (depth > 0) current += ch
  }
  return out
}

// ---------------------------------------------------------------------------

describe('the reveal permutation in 20260806090200', () => {
  const sql = migration('20260806090200_seed_reveal_order.sql')

  // The array lives between `array[` and `]::integer[]`. Sliced rather than
  // regexed across the whole file so a number appearing in a comment cannot be
  // read as a serial.
  const start = sql.indexOf('array[')
  const end = sql.indexOf(']::integer[]')
  const serials = sql
    .slice(start + 'array['.length, end)
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map(Number)

  it('holds every serial exactly once', () => {
    expect(serials).toHaveLength(MAX_SUPPLY)
    expect(new Set(serials).size).toBe(MAX_SUPPLY)
    expect(Math.min(...serials)).toBe(0)
    expect(Math.max(...serials)).toBe(MAX_SUPPLY - 1)
    expect(serials.every(Number.isInteger)).toBe(true)
  })

  it('is the permutation mintOrder() produces, position for position', () => {
    // The assertion this whole file exists for. A one-element difference here
    // means the database would deal a serial the browser is not expecting.
    expect(serials).toEqual([...mintOrder()])
  })

  it('puts a genuinely rare serial inside the first few draws', () => {
    // Not a property of the shuffle so much as a sanity check that the committed
    // order is the shuffled one rather than 0..4999 written out.
    expect(serials.slice(0, 20)).not.toEqual(Array.from({ length: 20 }, (_, i) => i))
  })

  it('never deals a serial the genesis crew already holds', () => {
    // This used to assert a fixed serial at position 512. That worked while the
    // crew was a PREFIX of the permutation; it is now filtered by tier, so the
    // taken serials are scattered through the order and "position N" no longer
    // identifies the first free one. What still has to hold is the property that
    // assertion was protecting: no buyer is issued a serial already on display.
    const taken = new Set(collection().map((x) => x.id))
    for (let position = 0; position < 50; position++) {
      expect(taken.has(serialForMint(position))).toBe(false)
    }
  })
})

describe('the 5,000 xployees in 20260806090300', () => {
  const rows = tuples(valuesBlock(migration('20260806090300_seed_xployees.sql'), 'insert into public.xployees ('))

  it('has one row per serial, in order', () => {
    expect(rows).toHaveLength(MAX_SUPPLY)
    expect(rows.map((r) => Number(r[0]))).toEqual(Array.from({ length: MAX_SUPPLY }, (_, i) => i))
  })

  it('agrees with buildXployee on every single field', () => {
    // Every field, every serial. Spot-checking a sample would leave 4,990
    // opportunities for a divergence that only one collector ever notices.
    const wrong: string[] = []
    for (const row of rows) {
      const id = Number(row[0])
      const x = buildXployee(id, 0)
      if (row[1] !== x.tier.id) wrong.push(`#${id} tier ${row[1]} vs ${x.tier.id}`)
      if (row[2] !== x.mint) wrong.push(`#${id} art seed`)
      if (UNIFORMS[Number(row[3])] !== x.traits.uniform) wrong.push(`#${id} uniform`)
      if (HEADS[Number(row[4])] !== x.traits.head) wrong.push(`#${id} head`)
      if (FACES[Number(row[5])] !== x.traits.face) wrong.push(`#${id} face`)
      if (ACCESSORIES[Number(row[6])] !== x.traits.accessory) wrong.push(`#${id} accessory`)
      // The stored apy is the blend rounded to the column's six decimal places,
      // so the comparison is to that precision and not to the float.
      if (Math.abs(Number(row[7]) - x.apy) > 1e-6) wrong.push(`#${id} apy ${row[7]} vs ${x.apy}`)
    }
    expect(wrong.slice(0, 10)).toEqual([])
  })

  it('agrees with tierForId, which is what the SQL check constraint enforces', () => {
    for (const row of rows) {
      expect(row[1]).toBe(tierForId(Number(row[0]), MAX_SUPPLY).id)
    }
  })

  it('lays the tiers out in the published bands', () => {
    const counts: Record<string, number> = {}
    for (const row of rows) counts[row[1]] = (counts[row[1]] ?? 0) + 1
    // The four numbers the token page publishes as the supply table.
    expect(counts).toEqual({ xrated: 150, expert: 600, mid: 1250, entry: 3000 })

    const band = (tier: string) => rows.filter((r) => r[1] === tier).map((r) => Number(r[0]))
    expect(Math.min(...band('xrated'))).toBe(0)
    expect(Math.max(...band('xrated'))).toBe(149)
    expect(Math.min(...band('expert'))).toBe(150)
    expect(Math.max(...band('expert'))).toBe(749)
    expect(Math.min(...band('mid'))).toBe(750)
    expect(Math.max(...band('mid'))).toBe(1999)
    expect(Math.min(...band('entry'))).toBe(2000)
    expect(Math.max(...band('entry'))).toBe(4999)
  })

  it('gives every worker a distinct 44-character art seed', () => {
    const seeds = rows.map((r) => r[2])
    expect(new Set(seeds).size).toBe(MAX_SUPPLY)
    expect(seeds.every((s) => s.length === 44)).toBe(true)
  })

  it('names an overlay the check constraint allows', () => {
    const allowed = new Set(['none', 'snow', 'rain', 'thunder', 'sparks', 'embers', 'stars'])
    for (const row of rows) expect(allowed.has(row[9])).toBe(true)
  })

  it('states no skill count and no principal, so the trigger cannot be contradicted', () => {
    // Both are stamped from the tier by `xployees_stamp_identity`. A seed that
    // also stated them would be a second opinion that could disagree.
    const header = migration('20260806090300_seed_xployees.sql')
    const columns = header.slice(header.indexOf('insert into public.xployees ('), header.indexOf(') values'))
    expect(columns).not.toMatch(/\bskills\b/)
    expect(columns).not.toMatch(/\bprincipal\b/)
  })
})

/**
 * The 16-row skill REGISTRY, as distinct from the 7,900 held-skill rows below.
 *
 * This test is here because its absence cost something. `public.skills` mirrors
 * SKILLS in src/lib/skills.ts by hand, and when the roster moved from Backed's
 * xStocks to Robinhood's own tokens the TypeScript was updated and the SQL was
 * not. Every other seed table is checked against its generator, so the whole
 * suite stayed green while the database would have served `NVDAx` and `JPMx` —
 * a ticker with no token behind it and a company that is not on the chain — to
 * anything reading desks from Postgres rather than from the bundle.
 *
 * Ids, weights and base_apy are the load-bearing half: `pickDistinct` walks
 * SKILLS in order and selects by weight, so a disagreement there means the
 * database and the browser deal different desks for the same xployee. Ticker,
 * desk and label are display, and are checked for the same reason — they are
 * exactly what drifted.
 */
describe('the skill registry in 20260806090100', () => {
  const rows = tuples(valuesBlock(migration('20260806090100_collection.sql'), 'insert into public.skills ('))

  it('has one row per skill, in SKILLS order', () => {
    expect(rows).toHaveLength(SKILLS.length)
    expect(rows.map((r) => r[0])).toEqual(SKILLS.map((s) => s.id))
  })

  it('agrees with SKILLS on every field', () => {
    rows.forEach((row, i) => {
      const skill = SKILLS[i]
      expect({
        id: row[0],
        label: row[1],
        desk: row[2],
        ticker: row[3],
        baseApy: Number(row[4]),
        weight: Number(row[5]),
      }).toEqual({
        id: skill.id,
        label: skill.label,
        desk: skill.desk,
        ticker: skill.ticker,
        baseApy: skill.baseApy,
        weight: skill.weight,
      })
    })
  })

  it('names only tickers that are real Robinhood Chain tokens', () => {
    // The point of the whole roster change. A desk pointing at a symbol with no
    // contract behind it prices at its reference forever and looks live.
    const known = new Set(STOCKS.map((s) => s.symbol))
    for (const skill of SKILLS) expect(known).toContain(skill.ticker)
  })
})

describe('the 7,900 skill rows in 20260806090400', () => {
  const rows = tuples(
    valuesBlock(migration('20260806090400_seed_xployee_skills.sql'), 'insert into public.xployee_skills'),
  )

  it('has one row per held skill', () => {
    // 3000x1 + 1250x2 + 600x3 + 150x4.
    expect(rows).toHaveLength(7900)
  })

  it('agrees with rollSkills on the skill and the proficiency, in draw order', () => {
    const bySerial = new Map<number, string[][]>()
    for (const row of rows) {
      const id = Number(row[0])
      const list = bySerial.get(id)
      if (list) list.push(row)
      else bySerial.set(id, [row])
    }

    const wrong: string[] = []
    for (let id = 0; id < MAX_SUPPLY; id++) {
      const x = buildXployee(id, 0)
      const held = bySerial.get(id) ?? []
      if (held.length !== x.skills.length) {
        wrong.push(`#${id} holds ${held.length} skills, expected ${x.skills.length}`)
        continue
      }
      for (const row of held) {
        const slot = Number(row[1])
        const expected = x.skills[slot]
        if (row[2] !== expected.skill.id) wrong.push(`#${id} slot ${slot} skill`)
        // proficiency is rolled as an integer 60..100 and divided by 100, so the
        // stored integer is exact rather than rounded.
        if (Number(row[3]) !== Math.round(expected.proficiency * 100)) {
          wrong.push(`#${id} slot ${slot} proficiency`)
        }
      }
    }
    expect(wrong.slice(0, 10)).toEqual([])
  })

  it('keeps proficiency inside the 60..100 the column allows', () => {
    for (const row of rows) {
      const pct = Number(row[3])
      expect(pct).toBeGreaterThanOrEqual(60)
      expect(pct).toBeLessThanOrEqual(100)
    }
  })

  it('never gives one worker the same desk twice', () => {
    const seen = new Set<string>()
    for (const row of rows) {
      const key = `${row[0]}|${row[2]}`
      expect(seen.has(key)).toBe(false)
      seen.add(key)
    }
  })
})

describe('the genesis holding in 20260806090500', () => {
  const sql = migration('20260806090500_seed_xnet_genesis.sql')
  const genesisRows = tuples(valuesBlock(sql, 'insert into public.genesis_crew', 'on conflict'))

  it('seeds one holding, not a simulated network', () => {
    // Was 512 xployees across 97 invented wallets, then 35 across one. Those
    // wallets did not exist, and seeding them made a first-day protocol look
    // like it had a history. This is the whole shipped index.
    expect(genesisRows).toHaveLength(HIRED_COUNT)
    expect(HIRED_COUNT).toBe(1)
  })

  it('names the same serials collection() renders', () => {
    const crew = collection().map((x) => x.id)
    expect(genesisRows.map((r) => Number(r[0]))).toEqual(crew)
  })

  it('is #0000, the first X-RATED in the supply', () => {
    expect(genesisRows.map((r) => Number(r[0]))).toEqual([0])
    expect(collection()[0].tier.id).toBe('xrated')
  })

  it('hires at protocol genesis, so it opens with nothing accrued', () => {
    // A backdated hire time is how the previous build shipped workers carrying
    // most of a year of earnings on a site that had never been deployed.
    expect(Number(genesisRows[0][2])).toBe(GENESIS)
  })

  it('agrees with the collection on hire time, to the millisecond', () => {
    const byId = new Map(collection().map((x) => [x.id, x]))
    for (const row of genesisRows) {
      const x = byId.get(Number(row[0]))
      expect(x).toBeDefined()
      expect(Math.abs(Number(row[2]) - x!.hiredAt)).toBeLessThan(1)
    }
  })

  it('leaves ownership unassigned rather than baking in an address', () => {
    // The project wallet lives in protocol_config and is set after deploy, so a
    // literal here would be whatever was current when this was generated. An
    // obviously-unset owner is the honest state; assign_genesis_crew() resolves
    // it from config.
    for (const row of genesisRows) expect(row[1]).toBe('GENESIS-UNASSIGNED')
    expect(sql).toContain('create or replace function public.assign_genesis_crew')
    expect(sql).toContain('select dev_wallet into target')
  })

  it('owns each serial exactly once', () => {
    const serialsSeeded = genesisRows.map((r) => Number(r[0]))
    expect(new Set(serialsSeeded).size).toBe(HIRED_COUNT)
  })
})

describe('what the seed leaves for the mint', () => {
  it('reserves only the genesis holding, so the pool is the rest of the supply', () => {
    // 5000 - 1, and it is the number the mint page renders as "remaining".
    expect(MAX_SUPPLY - HIRED_COUNT).toBe(4999)
  })

  it('leaves every rare serial that is not already hired available to mint', () => {
    // The reason the rate limit exists: how many X-RATED are still in the pool
    // after the genesis crew takes its share. If this ever reaches zero the mint
    // has no rarity left to protect and the whole design premise has changed.
    const hired = new Set(collection().map((x) => x.id))
    const rareInPool = [...Array(150).keys()].filter((id) => !hired.has(id))
    expect(rareInPool.length).toBeGreaterThan(0)
    expect(rareInPool.length).toBeLessThanOrEqual(150)
  })
})
