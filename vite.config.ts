import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
// @ts-expect-error — plain ESM, shared verbatim with server.mjs. Giving it a .d.ts
// would mean a second declaration of a contract that has exactly one caller here.
import { STOCK_PRICES_PATH, handleStockPrices } from './api/stock-prices.mjs'

/**
 * Mounts /api/stock-prices into the dev server.
 *
 * In production that route is served by server.mjs; without this plugin it would
 * simply 404 under `vite dev`, the tape would sit on cached reference prices,
 * and the difference would only surface after a deploy. Same module both sides,
 * so there is one implementation and dev tells the truth about prod.
 */
function stockPricesDevApi(): Plugin {
  return {
    name: 'xcorp-stock-prices-dev-api',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if ((req.url || '').split('?')[0] !== STOCK_PRICES_PATH) return next()
        handleStockPrices(req, res).catch(() => {
          res.statusCode = 502
          res.setHeader('Content-Type', 'application/json; charset=utf-8')
          res.end(JSON.stringify({ ok: false, error: 'Price lookup failed.' }))
        })
      })
    },
  }
}

export default defineConfig({
  plugins: [react(), tailwindcss(), stockPricesDevApi()],
  server: { port: 5181, strictPort: true },
  preview: {
    port: 4173,
    strictPort: true,
    // A Cloudflare quick tunnel arrives with a *.trycloudflare.com Host header,
    // which Vite's preview server rejects by default as a DNS-rebinding guard.
    // This box only ever serves the built site, so allowing it is safe here.
    allowedHosts: true,
  },
})
