import { readFileSync, writeFileSync, readdirSync } from 'node:fs'

const DIR = 'C:/Users/skizp/crypto/new_projects/xnfts/supabase/migrations'
const OUT = 'C:/Users/skizp/crypto/new_projects/xnfts/supabase/RUN-THIS-FIRST.sql'

// protocol_config stays on its own: it is the row an operator edits and may want
// to re-run independently, and bundling it would mean re-running a megabyte of
// seed data every time the CA changes.
const EXCLUDE = '20260806120000_protocol_config.sql'

const files = readdirSync(DIR)
  .filter((f) => f.endsWith('.sql') && f !== EXCLUDE)
  .sort()

const header = `-- =========================================================================
-- xNFTs — complete database setup, part 1 of 2
-- =========================================================================
--
-- Run this ENTIRE file in the Supabase SQL Editor, then run
-- protocol_config.sql afterwards.
--
-- This is ${files.length} migrations concatenated in dependency order. The order matters:
-- later sections reference tables earlier ones create, so do not reorder or
-- run parts of it out of sequence.
--
-- Safe to re-run. Every statement uses "if not exists", "or replace", or
-- "on conflict do nothing", so running it twice does not duplicate data or
-- error out.
--
-- If it fails, the banner above the failure tells you which original migration
-- the problem is in — send me that name and the error text.
--
-- Sections, in order:
${files.map((f, i) => `--   ${String(i + 1).padStart(2)}. ${f}`).join('\n')}
--
-- =========================================================================


`

let out = header
let bytes = 0

for (const [i, file] of files.entries()) {
  const sql = readFileSync(`${DIR}/${file}`, 'utf8')
  bytes += sql.length
  out += `
-- =========================================================================
-- SECTION ${i + 1} of ${files.length} — ${file}
-- =========================================================================

${sql.trimEnd()}

`
}

writeFileSync(OUT, out)

// The config migration gets a friendlier standalone name alongside its original,
// so an operator following the guide does not have to decode a timestamp.
const cfg = readFileSync(`${DIR}/${EXCLUDE}`, 'utf8')
const cfgOut = `-- =========================================================================
-- xNFTs — complete database setup, part 2 of 2
-- =========================================================================
--
-- Run this AFTER RUN-THIS-FIRST.sql.
--
-- This creates protocol_config: the single row holding your contract address,
-- project wallet, treasury and market links. Nothing on the site arms until
-- that row is filled in.
--
-- After running this, go to Table Editor -> protocol_config and edit the row.
-- Changes take effect on the live site within about 15 seconds. No redeploy.
--
-- Kept separate from part 1 on purpose: this is the file you may want to
-- re-run, and bundling it would mean re-running a megabyte of seed data to
-- change one address.
-- =========================================================================


${cfg.trimEnd()}
`
writeFileSync('C:/Users/skizp/crypto/new_projects/xnfts/supabase/RUN-THIS-SECOND.sql', cfgOut)

console.log(`RUN-THIS-FIRST.sql   ${files.length} migrations, ${(out.length / 1024).toFixed(0)} kB`)
console.log(`RUN-THIS-SECOND.sql  protocol_config, ${(cfgOut.length / 1024).toFixed(1)} kB`)
