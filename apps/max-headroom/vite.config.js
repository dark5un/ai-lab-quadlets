import { defineConfig } from 'vite';

// Served under dufs at an arbitrary path -> relative base.
export default defineConfig({
  base: './',
  build: { target: 'es2022' },
});
