import { defineConfig } from 'vite';
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(here, 'tests', 'fixtures', 'bs-frames.csv');

// Served under dufs at an arbitrary path -> relative base.
export default defineConfig({
  base: './',
  // assets/ (facecap.glb, basis transcoder, LICENSE) -> copied verbatim to
  // dist/ root, fetched at runtime by URL (./facecap.glb, ./basis/...).
  publicDir: 'assets',
  build: { target: 'es2022' },
  plugins: [{
    name: 'max-headroom-fixture',
    // dev: serve the ARKit CSV fixture at ./fixture/bs-frames.csv
    configureServer(server) {
      server.middlewares.use('/fixture/bs-frames.csv', (_req, res) => {
        res.setHeader('content-type', 'text/csv');
        res.end(readFileSync(FIXTURE));
      });
    },
    // build: copy fixture into dist so ?feed=file works under vite preview/dufs
    closeBundle() {
      const out = join(here, 'dist', 'fixture');
      mkdirSync(out, { recursive: true });
      copyFileSync(FIXTURE, join(out, 'bs-frames.csv'));
    },
  }],
});
