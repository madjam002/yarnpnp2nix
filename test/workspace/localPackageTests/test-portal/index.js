const _fetch = require('isomorphic-fetch')

module.exports = function fetch(path, opts) {
  return _fetch(path, {
    ...opts,
  })
}
