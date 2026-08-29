// Split the migration bundle into chunks the Supabase SQL Editor will accept.
//
// The editor rejects a request over roughly a megabyte, and the full bundle is
// 1,031 kB — mostly the 5,000-row xployee seed.
//
// Splitting on byte offsets would cut statements in half, so this walks the SQL
// and splits only at TOP-LEVEL semicolons. "Top level" is the whole difficulty:
// a semicolon inside a dollar-quoted function body ($$ ... $$), a string
// literal, or a comment is not a statement boundary, and every migration here
// defines plpgsql functions full of them. Getting that wrong produces chunks
// that are individually valid-looking and collectively broken.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// PATHS ARE REPO-RELATIVE, and that is load-bearing rather than tidiness. These
// were three hardcoded absolute paths into new_projects/xnfts — the Solana
// project this repo was forked FROM. Read paths meant the fork bundled the other
// project's migrations; WRITE paths meant running `npm run sql:bundle` here
// silently regenerated the other project's committed SQL, in a repo whose
// database is live. Resolving from import.meta.url makes a fork operate on
// itself, which is the only thing it should ever do.
const SUPABASE = fileURLToPath(new URL('../supabase/', import.meta.url))

const SRC = `${SUPABASE}RUN-THIS-FIRST.sql`
const OUT = `${SUPABASE}sql-chunks`

/** Comfortably under the editor's limit, with room for the header. */
const TARGET_BYTES = 150_000

/**
 * Split into complete statements.
 *
 * Tracks four states a semicolon can hide in. Anything not in one of them, at
 * nesting depth zero, ends a statement.
 */
function splitStatements(sql) {
  const out = []
  let start = 0
  let i = 0

  while (i < sql.length) {
    const c = sql[i]

    // Line comment — runs to end of line.
    if (c === '-' && sql[i + 1] === '-') {
      const nl = sql.indexOf('\n', i)
      i = nl === -1 ? sql.length : nl + 1
      continue
    }

    // Block comment. Postgres nests these, so count depth rather than
    // stopping at the first */.
    if (c === '/' && sql[i + 1] === '*') {
      let depth = 1
      i += 2
      while (i < sql.length && depth > 0) {
        if (sql[i] === '/' && sql[i + 1] === '*') { depth++; i += 2 }
        else if (sql[i] === '*' && sql[i + 1] === '/') { depth--; i += 2 }
        else i++
      }
      continue
    }

    // Single-quoted string. '' is an escaped quote, not a terminator.
    if (c === "'") {
      i++
      while (i < sql.length) {
        if (sql[i] === "'" && sql[i + 1] === "'") { i += 2; continue }
        if (sql[i] === "'") { i++; break }
        i++
      }
      continue
    }

    // Double-quoted identifier.
    if (c === '"') {
      i++
      while (i < sql.length && sql[i] !== '"') i++
      i++
      continue
    }

    // Dollar-quoted block: $tag$ ... $tag$. The tag may be empty ($$) and must
    // match exactly to close, which is the whole reason Postgres has them.
    if (c === '$') {
      const m = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i))
      if (m) {
        const tag = m[0]
        const close = sql.indexOf(tag, i + tag.length)
        i = close === -1 ? sql.length : close + tag.length
        continue
      }
    }

    if (c === ';') {
      out.push(sql.slice(start, i + 1))
      start = i + 1
      i++
      continue
    }

    i++
  }

  const tail = sql.slice(start)
  if (tail.trim().length > 0) out.push(tail)
  return out
}

/**
 * Break one oversized `INSERT ... VALUES (...),(...);` into several smaller
 * INSERTs, each carrying a slice of the tuples.
 *
 * Statement-boundary splitting is not enough on its own: the xployee seed is a
 * SINGLE statement of 498 kB with 5,000 tuples, so no boundary exists inside it
 * to split on. The tuples are independent rows, though, so several INSERTs of
 * the same shape are exactly equivalent to one big one.
 *
 * Returns null for anything that is not a simple INSERT..VALUES — a statement
 * with an ON CONFLICT tail, a SELECT source, or a RETURNING clause is left
 * whole rather than guessed at.
 */
function splitInsertValues(stmt, targetBytes) {
  const m = /^([\s\S]*?\bvalues\b)([\s\S]*?);\s*$/i.exec(stmt)
  if (!m) return null

  const prefix = m[1]
  const body = m[2]
  // Anything clever after the tuples means this is not the simple shape.
  if (/\b(on\s+conflict|returning|select)\b/i.test(body)) return null

  // Walk the tuple list, tracking paren depth and quotes so a ')' or ',' inside
  // a string literal is not mistaken for structure.
  const tuples = []
  let depth = 0
  let start = -1
  let i = 0
  while (i < body.length) {
    const c = body[i]
    if (c === "'") {
      i++
      while (i < body.length) {
        if (body[i] === "'" && body[i + 1] === "'") { i += 2; continue }
        if (body[i] === "'") { i++; break }
        i++
      }
      continue
    }
    if (c === '(') {
      if (depth === 0) start = i
      depth++
    } else if (c === ')') {
      depth--
      if (depth === 0 && start >= 0) {
        tuples.push(body.slice(start, i + 1))
        start = -1
      }
    }
    i++
  }

  if (tuples.length < 2) return null

  const out = []
  let batch = []
  let size = prefix.length
  for (const t of tuples) {
    if (batch.length > 0 && size + t.length > targetBytes) {
      out.push(`${prefix}\n${batch.join(',\n')};\n`)
      batch = []
      size = prefix.length
    }
    batch.push(t.trim())
    size += t.length + 2
  }
  if (batch.length > 0) out.push(`${prefix}\n${batch.join(',\n')};\n`)

  // Sanity: every tuple must survive, or the seed is silently short rows.
  const kept = out.reduce((n, s) => n + (s.match(/\n\(/g) || []).length, 0)
  if (kept !== tuples.length) return null

  return out
}

const sql = readFileSync(SRC, 'utf8')
const rawStatements = splitStatements(sql)

// Expand any statement too big to send on its own.
const statements = []
for (const stmt of rawStatements) {
  if (stmt.length <= TARGET_BYTES) {
    statements.push(stmt)
    continue
  }
  const parts = splitInsertValues(stmt, TARGET_BYTES)
  if (parts) statements.push(...parts)
  else statements.push(stmt) // not a shape we can safely divide — leave it
}

// Pack statements into chunks without ever splitting one. A single statement
// larger than the target gets its own chunk rather than being broken.
const chunks = []
let current = ''
for (const stmt of statements) {
  if (current.length > 0 && current.length + stmt.length > TARGET_BYTES) {
    chunks.push(current)
    current = ''
  }
  current += stmt
}
if (current.trim().length > 0) chunks.push(current)

try { rmSync(OUT, { recursive: true }) } catch { /* first run */ }
mkdirSync(OUT, { recursive: true })

const pad = (n) => String(n).padStart(2, '0')

chunks.forEach((chunk, idx) => {
  const n = idx + 1
  const header = `-- =========================================================================
-- xNFTs database setup — PART ${pad(n)} of ${pad(chunks.length)}
-- =========================================================================
--
-- Run these IN ORDER, one at a time, in the Supabase SQL Editor.
-- Wait for each to finish before starting the next.
--
-- Split only at statement boundaries, so no statement is cut in half. Safe to
-- re-run: every statement uses "if not exists", "or replace", or
-- "on conflict do nothing".
--
-- After all ${pad(chunks.length)} parts, run RUN-THIS-SECOND.sql (protocol_config).
-- =========================================================================

`
  writeFileSync(`${OUT}/part-${pad(n)}.sql`, header + chunk.trimStart())
})

// Verification. A byte-for-byte round trip is no longer possible once a big
// INSERT has been rewritten into several, so check the two things that actually
// matter instead: every value tuple survived, and no statement was truncated.
const countTuples = (s) => (s.match(/\n?\(\s*\d+\s*,/g) || []).length
const srcTuples = countTuples(sql)
const outTuples = chunks.reduce((n, c) => n + countTuples(c), 0)

const srcSemis = (sql.match(/;/g) || []).length
const outSemis = chunks.reduce((n, c) => n + (c.match(/;/g) || []).length, 0)

console.log(`statements        : ${rawStatements.length} -> ${statements.length} after value-splitting`)
console.log(`chunks written    : ${chunks.length}`)
console.log(`value tuples      : ${srcTuples} source / ${outTuples} output  ${srcTuples === outTuples ? 'OK' : 'MISMATCH — DO NOT USE'}`)
console.log(`semicolons        : ${srcSemis} source / ${outSemis} output  (output >= source is expected)`)
for (const f of readdirSync(OUT).sort()) {
  const size = readFileSync(`${OUT}/${f}`).length
  console.log(`  ${(size / 1024).toFixed(0).padStart(4)} kB  ${f}`)
}
