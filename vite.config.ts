import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
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
