// `teste` sets packageDirectory (see test/flake.nix), so its files live at
// <drv>/pkg/teste rather than <drv>/node_modules/teste.
//
// testa depends on teste but does not itself opt out, which is the case that
// regresses easily: the plugin falls back to `<drvPath>/node_modules/<name>`
// for every package except the one being built, so a relocated *dependency*
// resolves to a path that does not exist unless the registry says where it
// actually went.
const { expect } = require('chai')
const fs = require('fs')
const path = require('path')
const pnpapi = require('pnpapi')

// teste has a peer dependency, so it is reached through a virtual path rather
// than by its workspace: reference. Ask resolution where it is instead of
// guessing a locator.
const resolved = pnpapi.resolveToUnqualified('teste', __dirname + '/')
expect(resolved, 'teste did not resolve from testa').to.be.a('string')

// The whole point of packageDirectory is the path Node ends up loading from,
// which for a virtual package is the virtual path, so check that one too.
expect(
  resolved,
  'teste set packageDirectory = "pkg", so nothing about the path it is loaded from may still say node_modules',
).to.not.match(/[\\/]node_modules[\\/]/)

// PnP reports package directories with a trailing separator
const real = (pnpapi.resolveVirtual(resolved) ?? resolved).replace(/[\\/]$/, '')
expect(real).to.not.match(/[\\/]node_modules[\\/]/)
expect(real, `teste resolved to ${real}`).to.match(/[\\/]pkg[\\/]teste$/)

// ...and the files are really there, not just recorded
expect(
  fs.existsSync(real),
  `teste is recorded at ${real}, but nothing is there`,
).to.equal(true)
expect(fs.existsSync(path.join(real, 'index.js'))).to.equal(true)

console.log('testa packageDirectory test passed')
