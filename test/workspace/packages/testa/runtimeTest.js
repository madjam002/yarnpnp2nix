const { expect } = require('chai')

expect(() => require('color')).to.throw() // as we've put color in filterDependencies

require('teste')

console.log('testa runtime passed')
