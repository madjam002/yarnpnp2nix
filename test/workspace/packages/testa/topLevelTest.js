// The .pnp.cjs generated for a Nix build has to expose the package being built
// as the top level package, both for pnpapi.getPackageInformation(topLevel) and
// for top level fallback resolution.
//
// @yarnpkg/pnp 4.1.3 stopped serializing whatever the caller placed at
// packageRegistry[null][null] and started deriving that entry from the
// dependency tree root whose packageLocation is "./". Packages built here live
// at ./node_modules/<name>/, so nothing matches and the entry silently
// disappears; the plugin puts it back.
const { expect } = require('chai')
const pnpapi = require('pnpapi')

const info = pnpapi.getPackageInformation(pnpapi.topLevel)

expect(info, 'the top level package is missing from the generated .pnp.cjs').to
  .not.be.null
expect(info.packageLocation).to.match(/[\\/]node_modules[\\/]testa[\\/]$/)

console.log('testa top level package test passed')
