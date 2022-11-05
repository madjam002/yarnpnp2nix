import { structUtils, Manifest} from '@yarnpkg/core'
import type * as PnpApi from 'pnpapi'
import { ZipOpenFS } from '@yarnpkg/libzip'
import { PosixFS } from '@yarnpkg/fslib'

const libzip = require(`@yarnpkg/libzip`).getLibzipSync()

const zipOpenFs = new ZipOpenFS({libzip});
const crossFs = new PosixFS(zipOpenFs);

export function cleanLocatorString(locatorString: string) {
  const locator = structUtils.parseLocator(locatorString)
  const range = structUtils.parseRange(locator.reference)

  if (range.protocol === 'patch:') {
    return structUtils.stringifyLocator({
      ...locator,
      reference: structUtils.makeRange({...range, params: null}),
    })
  }

  return locatorString
}

export function readPackageJSON(packageInformation: PnpApi.PackageInformation) {
  return Manifest.fromText(crossFs.readFileSync(packageInformation.packageLocation + 'package.json', 'utf8'))
}
