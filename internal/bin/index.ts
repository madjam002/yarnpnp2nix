const commandMap = {
  createLockFile: require('./createLockFile').default,
  makePathWrappers: require('./makePathWrappers').default,
}

commandMap[process.argv[2]]()
