import { defineConfig } from 'vite'
import { resolve } from 'path'

export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        customer: resolve(__dirname, 'apps/customer/index.html'),
        staffApply: resolve(__dirname, 'apps/staff/index.html'),
        staffPage: resolve(__dirname, 'apps/staff/page.html'),
        staffManager: resolve(__dirname, 'apps/staff/manager.html'),
      }
    }
  }
})
