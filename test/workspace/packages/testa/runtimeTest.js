const { expect } = require('chai')

expect(() => require('color')).to.throw() // as we've put color in filterDependencies

console.log('testa runtime passed')
