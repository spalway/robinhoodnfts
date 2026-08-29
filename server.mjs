// Static file server for the built site, for hosts that run a process rather
// than serving a folder — Railway, Render, Fly, a plain VPS.
//
// Zero dependencies on purpose. This is the one piece of infrastructure between
// a visitor and the site, and a supply-chain problem in a convenience package
// would be a bad place to find out. Node's own http and fs are enough.
//
// Two behaviours matter and both are easy to get wrong:
//
//   SPA FALLBACK. This app is a client-side router. A visitor who opens
//   /marketplace directly, or reloads on /xployee/62, is asking this server for a
//   file that does not exist. Without the fallback they get a 404 on every route
//   except "/", which looks exactly like a broken deploy. Anything that is not a
//   real file and does not look like an asset gets index.html and lets the router
//   sort it out.
//
//   CACHING. Vite fingerprints asset filenames (index-CS9U4OvA.js), so those are
//   immutable and can be cached for a year. index.html must NEVER be cached: it
//   is the file that points at the current fingerprints, and a stale copy sends
//   returning visitors to asset URLs that no longer exist. That failure looks
//   like a blank page for everyone who visited before the deploy.
import { createServer } from 'node:http'
import { createReadStream, existsSync, statSync } from 'node:fs'
import { extname, join, normalize, resolve } from 'node:path'

const ROOT = resolve('dist')
const PORT = Number(process.env.PORT) || 8080
// Railway (and every other container host) routes to the container's interface,
// not to loopback. Binding 127.0.0.1 here is the classic "deploy succeeded but
// the URL times out" mistake.
const HOST = '0.0.0.0'

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
}

if (!existsSync(ROOT)) {
  console.error('dist/ does not exist. Run `npm run build` before starting the server.')
  process.exit(1)
}

/** Resolve a URL path to a real file inside dist/, or null. */
function resolveFile(urlPath) {
  // normalize() collapses ../ before it is joined, so a crafted path cannot
  // escape dist/. The startsWith check is the belt to that braces.
  const clean = normalize(decodeURIComponent(urlPath.split('?')[0])).replace(/^(\.\.[/\\])+/, '')
  const full = join(ROOT, clean)
  if (!full.startsWith(ROOT)) return null
  if (!existsSync(full)) return null
  const stat = statSync(full)
  if (stat.isDirectory()) {
    const index = join(full, 'index.html')
    return existsSync(index) ? index : null
  }
  return full
}

function send(res, file, status = 200) {
  const ext = extname(file).toLowerCase()
  const isHtml = ext === '.html'
  res.writeHead(status, {
    'Content-Type': TYPES[ext] ?? 'application/octet-stream',
    // Fingerprinted assets never change under the same name; index.html always
    // must be re-fetched. See the header note.
    'Cache-Control': isHtml
      ? 'no-cache, no-store, must-revalidate'
      : 'public, max-age=31536000, immutable',
    'X-Content-Type-Options': 'nosniff',
  })
  createReadStream(file).pipe(res)
}

createServer((req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD' })
    res.end('Method Not Allowed')
    return
  }

  const file = resolveFile(req.url || '/')
  if (file) {
    send(res, file)
    return
  }

  // A missing path that carries a file extension is a genuinely missing asset —
  // returning index.html for it would hand the browser HTML where it expected
  // JavaScript, and the console error that produces sends people hunting in the
  // wrong place entirely. Only extensionless paths fall through to the router.
  if (extname(req.url || '')) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('Not Found')
    return
  }

  send(res, join(ROOT, 'index.html'))
}).listen(PORT, HOST, () => {
  console.log(`xNFTs serving dist/ on http://${HOST}:${PORT}`)
})
