import { defineConfig, loadEnv } from 'vite'
import { resolve } from 'path'
import { readFileSync, writeFileSync } from 'fs'
import { sentryVitePlugin } from '@sentry/vite-plugin'

function swPlugin() {
  return {
    name: 'sw-cache-version',
    closeBundle() {
      const src  = resolve(__dirname, 'apps/customer/sw.js')
      const dest = resolve(__dirname, 'dist/apps/customer/sw.js')
      const ver  = Date.now().toString(36)
      const code = readFileSync(src, 'utf8').replace('__SW_CACHE_VERSION__', ver)
      writeFileSync(dest, code)
    },
    configureServer(server) {
      server.middlewares.use('/apps/customer/sw.js', (_req, res) => {
        const src  = resolve(__dirname, 'apps/customer/sw.js')
        const code = readFileSync(src, 'utf8').replace('__SW_CACHE_VERSION__', 'dev')
        res.setHeader('Content-Type', 'application/javascript')
        res.end(code)
      })
    }
  }
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  return {
    plugins: [
      swPlugin(),
      sentryVitePlugin({
        org: 'libber-xf',
        project: 'javascript',
        authToken: env.SENTRY_AUTH_TOKEN,
      }),
    ],
    build: {
      sourcemap: 'hidden',
      rollupOptions: {
        input: {
          customer:         resolve(__dirname, 'apps/customer/index.html'),
          customerSave:     resolve(__dirname, 'apps/customer/save.html'),
          customerSettings: resolve(__dirname, 'apps/customer/settings.html'),
          staffApply:   resolve(__dirname, 'apps/staff/index.html'),
          staffPage:    resolve(__dirname, 'apps/staff/page.html'),
          staffManager: resolve(__dirname, 'apps/staff/manager.html'),
        }
      }
    }
  }
})
