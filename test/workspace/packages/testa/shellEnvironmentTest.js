const enhancedResolve = require('enhanced-resolve')
const path = require('path')

const resolve = enhancedResolve.create.sync({
  extensions: ['.js', '.jsx', '.ts', '.tsx', '.mjs', '.css', '.scss', '.sass'],
  mainFields: ['main', 'module', 'source'],
  // Is it right? https://github.com/webpack/enhanced-resolve/issues/283#issuecomment-775162497
  conditionNames: ['require'],
  exportsFields: [], // we do that because 'package.json' is usually not present in exports
});

console.log('got resolution', resolve(process.cwd(), path.join('resolve-dir', 'package.json')))
