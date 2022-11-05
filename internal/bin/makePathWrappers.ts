import * as fs from 'node:fs'
import * as path from 'node:path'
import { structUtils } from '@yarnpkg/core'
import { xfs } from '@yarnpkg/fslib'
import type * as PnpApi from 'pnpapi'
import { readPackageJSON } from '../lib'

const binWrappersOutDirectory = process.argv[3]
const pnpOutDirectory = process.argv[4]

export default async function makePathWrappers() {
  const outDirectoryReal = fs.realpathSync(pnpOutDirectory)

  const pnpApi: typeof PnpApi = require(path.join(outDirectoryReal, '.pnp.cjs'))
  if (!pnpApi) throw new Error('Could not find pnp api')

  const topLevelPackage = pnpApi.getPackageInformation(pnpApi.topLevel)

  for (const [__, dep] of Object.entries(Array.from(topLevelPackage.packageDependencies))) {
    const depLocator = (pnpApi as any).getLocator(dep[0], dep[1])
    if (depLocator.reference == null) continue

    const devirtualisedLocator = structUtils.ensureDevirtualizedLocator(depLocator)
    const depPkg = pnpApi.getPackageInformation(depLocator)
    const devirtualisedPkg = pnpApi.getPackageInformation(devirtualisedLocator)

    const packageManifest = readPackageJSON(devirtualisedPkg)

    for (const [bin, binScript] of Array.from(packageManifest.bin)) {
      const resolvedBinPath = path.join(depPkg.packageLocation, binScript)
      await xfs.writeFilePromise(path.join(binWrappersOutDirectory, bin) as any, `node ${resolvedBinPath} "$@"`, {
        mode: 0o755,
      })
    }
  }
}
