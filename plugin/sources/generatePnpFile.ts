import * as fs from 'node:fs'
import * as path from 'node:path'
import { PassThrough } from 'node:stream'
import { Project, StreamReport, structUtils, miscUtils } from '@yarnpkg/core'
import { xfs, VirtualFS } from '@yarnpkg/fslib'
import { getPnpPath } from '@yarnpkg/plugin-pnp'
import { generateInlinedScript } from '@yarnpkg/pnp'
import { mapKeys } from 'lodash'
import { cleanLocatorString } from './lib'

export default async function generatePnpFile(project: Project, { outDirectory, packageRegistryDataPath, topLevelPackageLocatorString}: {
  outDirectory: string,
  packageRegistryDataPath: string,
  topLevelPackageLocatorString: string,
}) {
  const pnpPath = getPnpPath({ cwd: outDirectory } as any);

  const pnpFallbackMode = project.configuration.get(`pnpFallbackMode`);
  const pnpIgnorePatterns = project.configuration.get(`pnpIgnorePatterns`);

  const dependencyTreeRoots: any[] = [] //project.workspaces.map(({anchoredLocator}) => ({name: structUtils.stringifyIdent(anchoredLocator), reference: anchoredLocator.reference}));
  const enableTopLevelFallback = pnpFallbackMode !== `none`;
  const fallbackPool = new Map();
  const ignorePattern = miscUtils.buildIgnorePattern([`.yarn/sdks/**`, ...pnpIgnorePatterns]);
  // const shebang = project.configuration.get(`pnpShebang`);
  const shebang = '#!/usr/bin/env node'

  const packageRegistry = new Map()

  const topLevelPackageLocatorClean = cleanLocatorString(topLevelPackageLocatorString)

  const _packageRegistryData = await resolvePackageRegistryData(project, JSON.parse(fs.readFileSync(packageRegistryDataPath, 'utf8')))

  const cleanedPackageRegistryData = mapKeys(_packageRegistryData, (value, key) => cleanLocatorString(key))

  let topLevelPackage = null

  const outDirectoryReal = fs.realpathSync(outDirectory)

  for (const [__, pkg] of project.storedPackages) {
    const stringifiedLocator = structUtils.stringifyLocator(pkg)
    const isVirtual = structUtils.isVirtualLocator(pkg);

    const devirtualisedLocator = isVirtual ? structUtils.devirtualizeLocator(pkg) : pkg

    const devirtualisedPkgData = cleanedPackageRegistryData[structUtils.stringifyLocator(devirtualisedLocator)]
    if (!devirtualisedPkgData) {
      continue
    }

    const packageDependencies = new Map()
    const packagePeers = new Set()

    for (const [__, descriptor] of Array.from(pkg?.peerDependencies ?? new Map())) {
      const ident = structUtils.stringifyIdent(descriptor)
      packageDependencies.set(ident, null);
      packagePeers.add(ident);
    }

    Array.from(pkg.dependencies).forEach(([key, value]) => {
      const resolutionHash = project.storedResolutions.get(value.descriptorHash)
      let resolvedPkg = resolutionHash != null ? project.storedPackages.get(resolutionHash) :
        null
      if (!resolvedPkg) {
        throw new Error('generatePnpFile(): Failed to resolve ' + value.name)
      }
      packageDependencies.set(structUtils.stringifyIdent(value), [structUtils.stringifyIdent(resolvedPkg), resolvedPkg.reference])
    })

    const packageLocationAbs = devirtualisedPkgData.packageLocation ?? (devirtualisedPkgData.packageOut + '/node_modules/' + devirtualisedPkgData.identString)
    const relativePackageLocation = path.relative(outDirectoryReal, packageLocationAbs)
    let packageLocation = (relativePackageLocation.startsWith('../') ? relativePackageLocation : ('./' + relativePackageLocation)) + '/'

    if (isVirtual) {
      packageLocation = './' + VirtualFS.makeVirtualPath('./.yarn/__virtual__' as any, structUtils.slugifyLocator(pkg), relativePackageLocation as any) + '/'
    }

    const packageData = {
      packageLocation,
      packageDependencies,
      packagePeers,
      linkType: pkg.linkType,
      // discardFromLookup: fetchResult.discardFromLookup || false,
    }

    miscUtils.getMapWithDefault(packageRegistry, structUtils.stringifyIdent(pkg)).set(pkg.reference, packageData);

    if (pkg.reference.startsWith('workspace:')) {
      dependencyTreeRoots.push({
        name: structUtils.stringifyIdent(pkg),
        reference: pkg.reference,
      })
    }

    if (stringifiedLocator === topLevelPackageLocatorClean) {
      topLevelPackage = packageData
    }
  }

  if (topLevelPackage != null) {
    miscUtils.getMapWithDefault(packageRegistry, null).set(null, topLevelPackage);
  } else {
    throw new Error('Could not determine topLevelPackage, this is NEEDED for the .pnp.cjs to be correctly generated')
  }

  const pnpSettings = {
    dependencyTreeRoots,
    enableTopLevelFallback,
    fallbackExclusionList: pnpFallbackMode === `dependencies-only` ? dependencyTreeRoots : [],
    fallbackPool,
    ignorePattern,
    packageRegistry,
    shebang,
  }

  const loaderFile = generateInlinedScript(pnpSettings);

  await xfs.changeFilePromise(pnpPath.cjs, loaderFile, {
    automaticNewlines: true,
    mode: 0o755,
  });
}

async function resolvePackageRegistryData(project: Project, packageRegistryData: any) {
  const report = new StreamReport({ stdout: new PassThrough(), configuration: project.configuration })

  await project.resolveEverything({ lockfileOnly: true, checkResolutions: false, report, cache: null, resolver: null })

  return packageRegistryData
}
