// Copies webfonts out of node_modules into public/fonts so index.css can
// reference stable /fonts/* URLs. Runs on postinstall; safe to re-run.
//
// m42 is committed directly under public/fonts — it is a local licence, not an
// npm package — and is used for the wordmark only.
import { copyFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const dest = resolve(root, 'public/fonts')

const files = [
  [
    'node_modules/@fontsource-variable/geist/files/geist-latin-wght-normal.woff2',
    'Geist-Variable.woff2',
  ],
  [
    'node_modules/@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2',
    'GeistMono-Variable.woff2',
  ],
  [
    'node_modules/@fontsource-variable/roboto/files/roboto-latin-wght-normal.woff2',
    'Roboto-Variable.woff2',
  ],
]

mkdirSync(dest, { recursive: true })

for (const [from, name] of files) {
  const src = resolve(root, from)
  if (!existsSync(src)) {
    console.warn(`[copy-fonts] missing ${from} — falling back to a system face.`)
    continue
  }
  copyFileSync(src, resolve(dest, name))
  console.log(`[copy-fonts] ${name}`)
}
