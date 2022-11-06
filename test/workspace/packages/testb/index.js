#!/usr/bin/env node

console.log('hello from testb 5!')

// test importing various packages which will throw an exception if there are any issues with yarnpnp2nix
require('styled-components')
require('test-portal')
require('react-dom')
require('sharp')
require('resolve-dir') // resolve-dir has circular package dependencies
require('test-tgz-redux-saga-core')
require('testa')
require('testa/runtimeTest')

const { createCanvas } = require('canvas')
const canvas = createCanvas(200, 200)
const ctx = canvas.getContext('2d')
const text = ctx.measureText('Awesome!')
console.log('got text width', text.width)
ctx.strokeStyle = 'rgba(0,0,0,0.5)'
ctx.beginPath()
ctx.lineTo(50, 102)
ctx.lineTo(50 + text.width, 102)
ctx.stroke()

// test knex + pg to see if peer dependencies are working properly
const knex = require('knex')({
  client: 'pg',
  connection: {
    host: '127.0.0.1',
  },
})

require('pg')
knex('test')
console.log('Knex successfully included')

console.log('Imported all packages successfully')
