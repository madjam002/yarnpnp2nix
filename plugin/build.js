require('esbuild')
  .build({
    entryPoints: [
      './index.ts',
    ],
    bundle: true,
    outdir: 'dist/',
    sourcemap: 'inline',
    platform: 'node',
    target: 'node16',
    logLevel: 'error',
    minify: true,
  })
  .catch(() => process.exit(1))
