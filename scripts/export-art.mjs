// Render every xployee in the collection to a PNG file plus a metadata JSON.
//
//   npm run export:art                 # all 5,000 at 512px into export/art
//   npm run export:art -- --only 0-49  # a slice, same bytes as the full run
//   npm run export:art -- --verify     # re-render and compare to the manifest
//
// WHY THIS EXISTS
// The art has always been generated in the browser: src/lib/avatar.ts returns a
// 32x32 grid of colours and src/lib/backgrounds.ts returns a React style object,
// and <XployeeArt> turns the pair into a picture on a canvas. That is fine while
// the only consumer is the site. It stops being fine the moment a database row
// has to point at an image — a marketplace thumbnail, a Twitter card, a wallet
// preview and an operator looking at #1885 in the SQL editor cannot each run a
// TypeScript bundle. `public.xployees.image_path` already exists and already
// generates `xployees/0000.png` from the serial; this is what fills it in.
//
// WHY IT IMPORTS src/lib INSTEAD OF REIMPLEMENTING IT
// A second generator is a second answer. It would agree on the day it was
// written and diverge on the first change to a palette, a trait table or a
// weight, and the divergence is silent in both directions: the site keeps
// rendering one #1885 and the bucket keeps serving another, each internally
// consistent. So the real modules are loaded — through Vite, so the extensionless
// TypeScript imports resolve exactly as they do in the app — and the only code
// written here is the part a browser would otherwise do: rasterising CSS.
//
// See scripts/README.md for what that rasteriser reproduces exactly and the two
// places it cannot.
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createServer } from 'vite'
import jpeg from 'jpeg-js'
import { encodePng } from './lib/png.mjs'
import { paintBackground, blitAvatar } from './lib/paint.mjs'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')

/**
 * Bumped whenever anything in this directory changes what a pixel is.
 *
 * It is written into every metadata file and into the manifest, so "these files
 * were produced by a renderer that predates the exposure fix" is answerable
 * without diffing images. It does NOT track changes to src/lib — those move the
 * art itself and are caught by the per-file hashes.
 */
const RENDERER_VERSION = 1

// ---------------------------------------------------------------------------
// arguments
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = {
    out: join(ROOT, 'export', 'art'),
    size: 512,
    // The CSS px width the art is rendered "as if" at — see the note on cssSize
    // below. 256 is a card in the collection grid at a normal desktop width.
    cssSize: 256,
    only: null,
    skipExisting: false,
    verify: false,
    quiet: false,
  }

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    const next = () => {
      const v = argv[++i]
      if (v === undefined) throw new Error(`${arg} needs a value`)
      return v
    }
    switch (arg) {
      case '--out': opts.out = resolve(next()); break
      case '--size': opts.size = Number(next()); break
      case '--css-size': opts.cssSize = Number(next()); break
      case '--only': opts.only = parseRanges(next()); break
      case '--skip-existing': opts.skipExisting = true; break
      case '--verify': opts.verify = true; break
      case '--quiet': opts.quiet = true; break
      case '--help':
      case '-h':
        console.log(USAGE)
        process.exit(0)
        break
      default:
        throw new Error(`unknown argument ${arg}`)
    }
  }

  if (!Number.isInteger(opts.size) || opts.size <= 0) throw new Error('--size must be a positive integer')
  if (!Number.isInteger(opts.cssSize) || opts.cssSize <= 0) throw new Error('--css-size must be a positive integer')
  return opts
}

const USAGE = `
render every xployee to a PNG plus a metadata JSON

  --out <dir>        output root (default: export/art)
  --size <px>        output edge in pixels (default: 512)
  --css-size <px>    the CSS px width the art is rendered as if at (default: 256)
  --only <ranges>    e.g. 0-49,1885,4999 — renders a subset, identical bytes
  --skip-existing    leave files that are already on disk alone
  --verify           re-render and compare against the manifest; writes nothing
  --quiet            no progress output
`

function parseRanges(text) {
  const out = new Set()
  for (const part of text.split(',')) {
    const m = /^(\d+)(?:-(\d+))?$/.exec(part.trim())
    if (!m) throw new Error(`--only: cannot parse "${part}"`)
    const from = Number(m[1])
    const to = m[2] === undefined ? from : Number(m[2])
    if (to < from) throw new Error(`--only: reversed range "${part}"`)
    for (let i = from; i <= to; i++) out.add(i)
  }
  return [...out].sort((a, b) => a - b)
}

// ---------------------------------------------------------------------------
// the collection modules, loaded through Vite
// ---------------------------------------------------------------------------

async function loadLib() {
  const server = await createServer({
    configFile: false,
    root: ROOT,
    // Nothing is served, so the dependency pre-bundler has no job here. Left on
    // it scans index.html and races the shutdown, printing an alarming esbuild
    // error at the end of a run that succeeded.
    optimizeDeps: { noDiscovery: true, include: [] },
    server: { middlewareMode: true },
    appType: 'custom',
    logLevel: 'error',
  })

  try {
    const [xployee, tiers, skills, backgrounds, avatar, rng] = await Promise.all([
      server.ssrLoadModule('/src/lib/xployee.ts'),
      server.ssrLoadModule('/src/lib/tiers.ts'),
      server.ssrLoadModule('/src/lib/skills.ts'),
      server.ssrLoadModule('/src/lib/backgrounds.ts'),
      server.ssrLoadModule('/src/lib/avatar.ts'),
      server.ssrLoadModule('/src/lib/rng.ts'),
    ])
    return { server, xployee, tiers, skills, backgrounds, avatar, rng }
  } catch (err) {
    await server.close()
    throw err
  }
}

/**
 * Decode every X-RATED source once, keyed by the path that appears in the
 * `url()` of a background layer.
 *
 * jpeg-js rather than a native decoder on purpose. The requirement is that the
 * same serial produces the same file on every machine; a libjpeg build differs
 * between platforms in the last bit of an IDCT, and a pure-JS decoder pinned in
 * package.json does not differ at all.
 */
function decodeScenes(dir, urlPrefix) {
  const images = new Map()
  const { readdirSync } = require('node:fs')
  for (const file of readdirSync(dir).sort()) {
    if (!/\.jpe?g$/i.test(file)) continue
    const raw = jpeg.decode(readFileSync(join(dir, file)), { useTArray: true })
    images.set(`${urlPrefix}${file}`, raw)
  }
  return images
}

// ---------------------------------------------------------------------------
// metadata
// ---------------------------------------------------------------------------

function buildMetadata(x, bg, lib, opts, imagePath, sha256) {
  const { UNIFORMS, HEADS, FACES, ACCESSORIES } = lib.xployee
  const { effectiveApy } = lib.skills

  return {
    // These first four are the join keys. `serial` is the 0-based id that
    // `public.xployees.id` carries, NOT a 1-based ordinal — #0000 exists and is
    // X-RATED, and off-by-one here would re-tier the whole collection.
    serial: x.id,
    serial_display: lib.xployee.serial(x.id),
    name: `xployee ${lib.xployee.serial(x.id)}`,
    image: imagePath,
    image_sha256: sha256,

    tier: x.tier.label,
    tier_id: x.tier.id,

    // Not a token mint and not a wallet. `fakeAddress('xployee:' + id)` produces
    // a base58 string that looks exactly like a Solana address, which is why it
    // is named for what it is: nothing may derive an on-chain account from it.
    art_seed: x.mint,

    apy: x.apy,
    principal_usd: x.principal,

    background: { kind: bg.kind, name: bg.name, overlay: bg.overlay },

    traits: {
      uniform: x.traits.uniform,
      head: x.traits.head,
      face: x.traits.face,
      accessory: x.traits.accessory,
      // The indices are what public.xployees stores (uniform_idx and friends),
      // so an operator can compare a file against a row without a lookup table.
      uniform_idx: UNIFORMS.indexOf(x.traits.uniform),
      head_idx: HEADS.indexOf(x.traits.head),
      face_idx: FACES.indexOf(x.traits.face),
      accessory_idx: ACCESSORIES.indexOf(x.traits.accessory),
    },

    skills: x.skills.map((held) => ({
      id: held.skill.id,
      label: held.skill.label,
      desk: held.skill.desk,
      ticker: held.skill.ticker,
      base_apy: held.skill.baseApy,
      proficiency: held.proficiency,
      effective_apy: effectiveApy(held),
    })),

    attributes: [
      { trait_type: 'Tier', value: x.tier.label },
      { trait_type: 'Skills', value: x.skills.length },
      { trait_type: 'Uniform', value: x.traits.uniform },
      { trait_type: 'Head', value: x.traits.head },
      { trait_type: 'Face', value: x.traits.face },
      { trait_type: 'Accessory', value: x.traits.accessory },
      { trait_type: 'Backdrop', value: bg.name },
      { trait_type: 'Weather', value: bg.overlay },
      ...x.skills.map((held) => ({ trait_type: 'Desk', value: held.skill.desk })),
    ],

    // Stated rather than implied. This file is NOT Metaplex token metadata and
    // there is no mint account behind it; ownership of #1885 is a row in
    // Postgres. Anything that treats an `image`+`attributes` document as proof
    // of an on-chain asset would be wrong about this one, so it says so.
    onchain: false,
    ownership: 'off-chain — public.xployees.owner',

    generator: {
      renderer_version: RENDERER_VERSION,
      size: opts.size,
      css_size: opts.cssSize,
      particles: false,
      frame: false,
    },
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  const lib = await loadLib()

  try {
    const { MAX_SUPPLY, buildXployee } = lib.xployee
    const { backgroundFor } = lib.backgrounds
    const { buildAvatar, GRID } = lib.avatar

    if (opts.size % GRID !== 0 && !opts.quiet) {
      console.error(
        `warning: --size ${opts.size} is not a multiple of ${GRID}, so sprite pixels will be ` +
          `uneven widths. The site has the same property in card grids; it is still crisp, ` +
          `but a multiple of ${GRID} is exact.`,
      )
    }

    const images = decodeScenes(join(ROOT, 'public', 'texture-files', 'xrated'), '/texture-files/xrated/')

    const serials = opts.only ?? Array.from({ length: MAX_SUPPLY }, (_, i) => i)
    for (const id of serials) {
      if (id < 0 || id >= MAX_SUPPLY) throw new Error(`serial ${id} is outside 0..${MAX_SUPPLY - 1}`)
    }

    const imageDir = join(opts.out, 'xployees')
    const metaDir = join(opts.out, 'metadata')
    if (!opts.verify) {
      mkdirSync(imageDir, { recursive: true })
      mkdirSync(metaDir, { recursive: true })
    }

    const buf = new Uint8Array(opts.size * opts.size * 3)
    const entries = []
    const mismatches = []
    let skipped = 0
    let bytes = 0
    const started = Date.now()

    const priorManifest =
      opts.verify && existsSync(join(opts.out, 'manifest.json'))
        ? JSON.parse(readFileSync(join(opts.out, 'manifest.json'), 'utf8'))
        : null
    const prior = new Map((priorManifest?.files ?? []).map((f) => [f.serial, f.sha256]))

    for (let n = 0; n < serials.length; n++) {
      const id = serials[n]
      const padded = String(id).padStart(4, '0')
      const imagePath = `xployees/${padded}.png`
      const imageFile = join(opts.out, imagePath)

      if (opts.skipExisting && !opts.verify && existsSync(imageFile)) {
        skipped++
        continue
      }

      // hiredAt is 0 because it is not part of identity: tier, skills, traits,
      // principal and apy are all pure functions of the serial. Passing a clock
      // reading here is how a "deterministic" export stops being one.
      const x = buildXployee(id, 0)
      const bg = backgroundFor(x)

      paintBackground(buf, opts.size, bg, { cssSize: opts.cssSize, images })
      blitAvatar(buf, opts.size, buildAvatar(x))

      const png = encodePng({ width: opts.size, height: opts.size, rgb: buf })
      const sha256 = createHash('sha256').update(png).digest('hex')

      if (opts.verify) {
        const was = prior.get(id)
        if (was === undefined) mismatches.push({ serial: id, reason: 'not in manifest' })
        else if (was !== sha256) mismatches.push({ serial: id, reason: 'hash changed', was, now: sha256 })
      } else {
        writeFileSync(imageFile, png)
        writeFileSync(
          join(metaDir, `${padded}.json`),
          JSON.stringify(buildMetadata(x, bg, lib, opts, imagePath, sha256), null, 2) + '\n',
        )
      }

      bytes += png.length
      entries.push({ serial: id, path: imagePath, sha256, bytes: png.length, tier: x.tier.id })

      if (!opts.quiet && (n % 100 === 99 || n === serials.length - 1)) {
        const done = n + 1
        const rate = done / ((Date.now() - started) / 1000)
        process.stderr.write(
          `\r${done}/${serials.length}  ${rate.toFixed(1)}/s  ${(bytes / 1e6).toFixed(1)} MB   `,
        )
      }
    }
    if (!opts.quiet) process.stderr.write('\n')

    if (opts.verify) {
      if (!priorManifest) {
        console.error('verify: no manifest.json in the output directory — nothing to compare against')
        process.exitCode = 1
        return
      }
      if (mismatches.length > 0) {
        console.error(`verify: ${mismatches.length} of ${entries.length} differ`)
        for (const m of mismatches.slice(0, 20)) console.error(`  #${String(m.serial).padStart(4, '0')} ${m.reason}`)
        process.exitCode = 1
        return
      }
      console.log(`verify: ${entries.length} images match the manifest`)
      return
    }

    // A partial run must not overwrite a full manifest with a slice of itself:
    // the manifest is what --verify compares against, and a truncated one turns
    // "4,950 images were never checked" into "everything passed".
    const manifestPath = join(opts.out, 'manifest.json')
    let files = entries
    if (opts.only || opts.skipExisting) {
      const existing = existsSync(manifestPath)
        ? JSON.parse(readFileSync(manifestPath, 'utf8')).files ?? []
        : []
      const merged = new Map(existing.map((f) => [f.serial, f]))
      for (const e of entries) merged.set(e.serial, e)
      files = [...merged.values()].sort((a, b) => a.serial - b.serial)
    }

    writeFileSync(
      manifestPath,
      JSON.stringify(
        {
          renderer_version: RENDERER_VERSION,
          size: opts.size,
          css_size: opts.cssSize,
          particles: false,
          frame: false,
          max_supply: MAX_SUPPLY,
          count: files.length,
          total_bytes: files.reduce((s, f) => s + f.bytes, 0),
          files,
        },
        null,
        2,
      ) + '\n',
    )

    if (!opts.quiet) {
      const secs = (Date.now() - started) / 1000
      console.log(
        `wrote ${entries.length} images (${skipped} skipped) in ${secs.toFixed(1)}s — ` +
          `${(bytes / 1e6).toFixed(1)} MB into ${opts.out}`,
      )
    }
  } finally {
    await lib.server.close()
  }
}

// `require` is reached for one readdirSync above; ESM has no bare require.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)

main().catch((err) => {
  console.error(err instanceof Error ? err.stack : err)
  process.exit(1)
})
