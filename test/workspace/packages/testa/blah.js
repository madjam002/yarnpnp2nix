const { expect } = require('chai')

console.log('testing of package testa')

console.log('nodejs version', process.version)

// console.log(require('react-old'))
// console.log(require('typescript'))

expect(() => require('react-dom')).to.throw()

module.exports = {
  thisis: 'testa',
}
