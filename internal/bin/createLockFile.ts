import * as fs from 'node:fs'
import { Configuration, Locator, Package, Project, structUtils } from '@yarnpkg/core'
import { ppath } from '@yarnpkg/fslib'
import { cleanLocatorString } from '../lib'

const packageRegistryDataPath = process.argv[3]
const topLevelPackageLocatorString = process.argv[4]

export default async function createLockFile() {
  const configuration = await Configuration.find(ppath.cwd(), null);
  const project = new Project(ppath.cwd(), { configuration })

  await (project as any).setupResolutions() // HACK setupResolutions is private

  const topLevelPackageLocator = structUtils.parseLocator(topLevelPackageLocatorString)

  const packageRegistryData = JSON.parse(fs.readFileSync(packageRegistryDataPath, 'utf8'))

  packageRegistryToProjectOriginalPackages(project, topLevelPackageLocator, packageRegistryData)

  project.storedPackages = project.originalPackages

  await project.persistLockfile()
}

function packageRegistryToProjectOriginalPackages(project: Project, topLevelPackageLocator: Locator, packageRegistryData: any) {
  packageRegistryData["root-workspace-0b6124@workspace:."] = {
    linkType: 'soft',
    languageName: 'unknown',
    packageDependencies: {
      [structUtils.stringifyIdent(topLevelPackageLocator)]: structUtils.stringifyLocator(topLevelPackageLocator),
    },
  }

  const packageRegistryDataEntries = Object.entries(packageRegistryData) as any

  for (let [locatorString, pkg] of packageRegistryDataEntries) {
    if (!pkg) continue

    const isTopLevelPackage = locatorString === topLevelPackageLocatorString || locatorString === 'root-workspace-0b6124@workspace:.'

    const dependencies = new Map()
    const dependenciesMeta = new Map(Object.entries(pkg.dependenciesMeta ?? {}))
    const peerDependencies = new Map()
    const peerDependenciesMeta = isTopLevelPackage ? new Map() : new Map(Object.entries(pkg.peerDependenciesMeta ?? {}))
    const bin = new Map(Object.entries(pkg.bin ?? {}))

    locatorString = cleanLocatorString(locatorString)
    const locator = structUtils.parseLocator(locatorString)

    const ident = structUtils.makeIdent(locator.scope, locator.name)
    const descriptor = structUtils.makeDescriptor(ident, locator.reference) // locators are also valid descriptors

    pkg.locatorHash = locator.locatorHash
    pkg.descriptorHash = descriptor.descriptorHash

    if (!isTopLevelPackage) {
      for (const dependencyName of Object.keys(pkg?.peerDependencies ?? {})) {
        const ident = structUtils.parseIdent(dependencyName)
        const descriptor = structUtils.makeDescriptor(ident, pkg.peerDependencies[dependencyName])
        peerDependencies.set(ident.identHash, descriptor)
      }
    }

    const origPackage: Package = {
      ...locator,
      languageName: pkg.languageName,
      linkType: pkg.linkType.toUpperCase(),
      conditions: null,
      dependencies,
      // TODO
      // dependenciesMeta: dependenciesMeta as any,
      dependenciesMeta: null as any,
      bin: bin as any,
      peerDependencies,
      peerDependenciesMeta: peerDependenciesMeta as any,
      version: null,
    }
    project.originalPackages.set(origPackage.locatorHash, origPackage)

    // storedResolutions is a map of descriptorHash -> locatorHash
    project.storedResolutions.set(descriptor.descriptorHash, origPackage.locatorHash)

    // storedChecksums is a map of locatorHash -> checksum
    if (pkg.checksum != null) project.storedChecksums.set(origPackage.locatorHash, '9/' + pkg.checksum)

    project.storedDescriptors.set(descriptor.descriptorHash, descriptor)
  }

  for (const [locatorString, _package] of packageRegistryDataEntries) {
    if (!_package) continue

    const pkg = project.originalPackages.get(_package.locatorHash)
    if (!pkg) continue

    const pkgDependencies = _package.packageDependencies ?? {}

    for (const dependencyName of Object.keys(pkgDependencies)) {
      const depLocatorString = pkgDependencies[dependencyName]
      const depPkg = packageRegistryData[depLocatorString]
      if (depPkg?.descriptorHash != null) {
        const depPkgDescriptor = project.storedDescriptors.get(depPkg.descriptorHash)
        if (depPkgDescriptor != null) {
          let descriptor = structUtils.makeDescriptor(structUtils.parseIdent(dependencyName), depPkgDescriptor.range)
          const range = structUtils.parseRange(descriptor.range)

          if (range.protocol === 'patch:') {
            descriptor = structUtils.parseDescriptor(range.source!)
          }

          project.storedResolutions.set(descriptor.descriptorHash, depPkg.locatorHash)
          project.storedDescriptors.set(descriptor.descriptorHash, descriptor)
          pkg.dependencies.set(descriptor.identHash, descriptor)
        }
      }
    }
  }
}
