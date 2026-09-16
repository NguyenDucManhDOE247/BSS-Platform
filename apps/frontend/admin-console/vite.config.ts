import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  // B-06: the Ingress serves this app under the path prefix /admin (see
  // infrastructure/kubernetes/base/ingress.yaml). Vite defaults `base` to "/", so every built
  // asset URL in dist/index.html was an absolute "/assets/..." — through the Ingress that
  // resolves to web-portal (which owns "/"), not back to this app. `basename="/admin"` on
  // <BrowserRouter> (src/main.tsx) only fixes client-side routing; it does nothing for the
  // asset URLs Vite bakes into the HTML at build time — this `base` is the other half.
  base: '/admin/',
  plugins: [react()],
  server: {
    port: 3001,
    proxy: {
      '/api': { target: 'http://localhost:8080', changeOrigin: true },
    },
  },
  build: { outDir: 'dist', sourcemap: true },
  test: { globals: true, environment: 'jsdom' },
});
