#!/usr/bin/env node

console.log('hello from testb 5!')

// test importing various packages which will throw an exception if there are any issues with yarnpnp2nix
require('test-portal')
require('next/image')
require('react-dom')
require('sharp')
require('test-tgz-redux-saga-core')
require('testa')

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

console.log('Imported all packages successfully')
