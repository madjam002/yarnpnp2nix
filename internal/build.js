require('esbuild').build({
  entryPoints: [
    './bin/index',
  ],
  bundle: true,
  outdir: 'dist/',
  sourcemap: 'inline',
  platform: 'node',
  minify: true,
  target: 'node18',
  logLevel: 'warning',
  treeShaking: true,
})
