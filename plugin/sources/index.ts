import { Configuration, Project, Cache, StreamReport, Manifest, tgzUtils, structUtils, scriptUtils } from '@yarnpkg/core'
import { BaseCommand } from '@yarnpkg/cli'
import { Installer, Linker } from '@yarnpkg/core'
import { xfs, CwdFS, PortablePath, ppath } from '@yarnpkg/fslib'
import { ZipOpenFS } from '@yarnpkg/libzip'
import { pnpUtils } from '@yarnpkg/plugin-pnp'
import * as t from 'typanion'
import { Option } from 'clipanion'
import { execa, execaSync } from 'execa'
import * as fs from 'node:fs'
import * as path from 'node:path'
import { PassThrough } from 'node:stream'
import generatePnpFile from './generatePnpFile'
import { cleanLocatorString } from './lib'

let getExistingManifestNix = require('../../lib/getExistingManifest.nix.txt')

let _nixCurrentSystem: string

export function nixCurrentSystem() {
  if (!!_nixCurrentSystem) return _nixCurrentSystem
  const res = JSON.parse(execaSync('nix', [
    'eval',
    '--impure',
    '--json',
    '--expr',
    'builtins.currentSystem',
  ]).stdout)
  _nixCurrentSystem = res
  return res
}

export async function getExistingYarnManifest(manifestPath: string) {
  try {
    const nixArgs = [
      'eval',
      '--json',
      '--impure',
      '--expr',
      getExistingManifestNix +
        '\n' +
        `
        getPackages (import ${manifestPath})
      `,
    ]
    const { stdout } = await execa('nix', nixArgs, { stderr: 'ignore' })
    return JSON.parse(stdout)
  } catch (ex) {
    return null
  }
}

class FetchCommand extends BaseCommand {
  static paths = [['nix', 'fetch-by-locator']]

  locator = Option.String({validator: t.isString()})
  outDirectory = Option.String({validator: t.isString()})

  async execute() {
    const configuration = await Configuration.find(ppath.cwd(), this.context.plugins);
    const {project, workspace} = await Project.find(configuration, ppath.cwd());

    const fetcher = configuration.makeFetcher()

    const installReport = await StreamReport.start({
      configuration,
      stdout: this.context.stdout,
      includeLogs: !this.context.quiet,
    }, async report => {
      configuration.values.set('enableMirror', false) // disable global cache as we want to output to outDirectory

      let locator = {
        ...(JSON.parse(this.locator)),
        locatorHash: '',
        identHash: '',
      }

      locator = structUtils.parseLocator(structUtils.stringifyLocator(locator))

      if (structUtils.isVirtualLocator(locator)) {
        locator = structUtils.devirtualizeLocator(locator)
      }

      const fetchOptions = { checksums: new Map(), project, cache: new Cache(this.outDirectory as any, { check: false, configuration, immutable: false }), fetcher, report }
      const fetched = await fetcher.fetch(locator, fetchOptions)

      fs.renameSync((fetched.packageFs as any).target, path.join(this.outDirectory, 'output.zip'))
    });
  }
}

class ConvertToZipCommand extends BaseCommand {
  static paths = [['nix', 'convert-to-zip']]

  locator = Option.String({validator: t.isString()})
  tgzPath = Option.String({validator: t.isString()})
  outPath = Option.String({validator: t.isString()})

  async execute() {
    const configuration = await Configuration.find(ppath.cwd(), this.context.plugins);
    const {project, workspace} = await Project.find(configuration, ppath.cwd());

    const locator = {
      ...(JSON.parse(this.locator)),
      locatorHash: '',
      identHash: '',
    }

    const { path } = (await tgzUtils.convertToZip(fs.readFileSync(this.tgzPath), {
      compressionLevel: project.configuration.get(`compressionLevel`),
      prefixPath: structUtils.getIdentVendorPath(locator),
      stripComponents: 1,
    })) as any
    fs.copyFileSync(path, this.outPath)
  }
}

class GeneratePnpFile extends BaseCommand {
  static paths = [['nix', 'generate-pnp-file']]

  outDirectory = Option.String({validator: t.isString()})
  packageRegistryDataPath = Option.String({validator: t.isString()})
  topLevelPackageLocatorString = Option.String({validator: t.isString()})

  async execute() {
    const configuration = await Configuration.find(ppath.cwd(), this.context.plugins);
    const {project, workspace} = await Project.find(configuration, ppath.cwd());

    await generatePnpFile(project, {
      outDirectory: this.outDirectory,
      packageRegistryDataPath: this.packageRegistryDataPath,
      topLevelPackageLocatorString: this.topLevelPackageLocatorString
    })
  }
}

class RunBuildScriptsCommand extends BaseCommand {
  static paths = [['nix', 'run-build-scripts']]

  topLevelPackageLocatorString = Option.String({validator: t.isString()})
  pnpRootDirectory = Option.String({validator: t.isString()})
  packageDirectory = Option.String({validator: t.isString()})

  async execute() {
    const configuration = await Configuration.find(ppath.cwd(), this.context.plugins);
    const {project} = await Project.find(configuration, ppath.cwd());

    const topLevelLocator = structUtils.parseLocator(cleanLocatorString(this.topLevelPackageLocatorString))

    const pkg = project.originalPackages.get(topLevelLocator.locatorHash)
    if (!pkg) {
      throw new Error('runBuildScripts(): Could not determine top level package ' + this.topLevelPackageLocatorString)
    }

    ;(project as any).cwd = this.pnpRootDirectory
    project.storedPackages = project.originalPackages

    const manifest = await ZipOpenFS.openPromise(async (zipOpenFs) => {
      const linkers = project.configuration.getLinkers();
      const linkerOptions = {project, report: new StreamReport({stdout: new PassThrough(), configuration})};

      const linker = linkers.find(linker => linker.supportsPackage(pkg, linkerOptions));
      if (!linker)
        throw new Error(`The package ${structUtils.prettyLocator(project.configuration, pkg)} isn't supported by any of the available linkers`);

      const packageLocation = await linker.findPackageLocation(pkg, linkerOptions);
      const packageFs = new CwdFS(packageLocation, {baseFs: zipOpenFs});
      const manifest = await Manifest.find(PortablePath.dot, {baseFs: packageFs});

      return manifest
    })

    for (const scriptName of [`preinstall`, `install`, `postinstall`]) {
      if (!manifest.scripts.has(scriptName)) continue

      const exitCode = await scriptUtils.executePackageScript(pkg, scriptName, [], {cwd: this.packageDirectory as any, project, stdin: process.stdin, stdout: process.stdout, stderr: process.stderr});

      if (exitCode > 0) {
        return exitCode
      }
    }
  }
}

export default {
  hooks: {
    afterAllInstalled: async (project, opts) => {
      const linkers = project.configuration.getLinkers();
      const linkerOptions = {project, report: null};

      const existingManifest = await getExistingYarnManifest(path.join(project.cwd, 'yarn-manifest.nix'))

      const installers = new Map(linkers.map(linker => {
        const installer = linker.makeInstaller(linkerOptions);

        const customDataKey = linker.getCustomDataKey();
        const customData = project.linkersCustomData.get(customDataKey);
        if (typeof customData !== `undefined`)
          installer.attachCustomData(customData);

        return [linker, installer] as [Linker, Installer];
      }));

      const packageManifest: any = {}

      for (const [__, pkg] of project.storedPackages) {
        // skip virtual packages, we resolve these at runtime now during the derivation buildPhase
        const isVirtual = structUtils.isVirtualLocator(pkg)
        if (isVirtual) {
          continue
        }

        const originalPackage = project.originalPackages.get(__)

        const resolutions = {}

        Array.from(pkg.dependencies).forEach(async ([key, value]) => {
          const originalDependency = originalPackage.dependencies.get(key)
          if (!originalDependency) return

          const resolvedDevirtualisedDescriptor = structUtils.ensureDevirtualizedDescriptor(value)
          const originalDevirtualisedDescriptor = structUtils.ensureDevirtualizedDescriptor(originalDependency)

          const originalRange = structUtils.makeRange({...structUtils.parseRange(originalDevirtualisedDescriptor.range), params: null})
          const resolvedRange = structUtils.makeRange({...structUtils.parseRange(resolvedDevirtualisedDescriptor.range), params: null})

          if (originalRange !== resolvedRange) {
            resolutions[structUtils.stringifyDescriptor(originalDevirtualisedDescriptor)] =
              structUtils.stringifyDescriptor(resolvedDevirtualisedDescriptor)
          }
        })

        const linker = linkers.find(linker => linker.supportsPackage(pkg, linkerOptions));
        const installer: any = installers.get(linker)

        const willProbablyHaveSource =
          pkg.reference.startsWith('workspace:') ||
          pkg.reference.startsWith('file:') ||
          pkg.reference.startsWith('portal:')

        const shouldBeUnplugged = installer?.shouldBeUnplugged != null ? installer.customData.store.get(pkg.locatorHash) != null ? installer.shouldBeUnplugged(pkg, installer.customData.store.get(pkg.locatorHash), project.getDependencyMeta(structUtils.isVirtualLocator(pkg) ? structUtils.devirtualizeLocator(pkg) : pkg, pkg.version)) : false : true

        const manifestPackageId = structUtils.stringifyIdent(pkg) + '@' + pkg.reference

        const packageInExistingManifest = existingManifest?.[manifestPackageId]

        let outputHash = packageInExistingManifest?.outputHash
        let outputHashByPlatform: any = packageInExistingManifest?.outputHashByPlatform ?? {}

        await (async function() {
          if (willProbablyHaveSource) {
            // no outputHash for when a src is provided as the build will be completed locally.
            outputHash = null
            outputHashByPlatform = null
            return
          } else if (shouldBeUnplugged) {
            const shouldHashBePlatformSpecific = true // TODO only if package or dependencies have platform conditions maybe?
            if (shouldHashBePlatformSpecific) {
              if (outputHashByPlatform[nixCurrentSystem()]) {
                // got existing hash for this platform in the manifest, use existing hash
                outputHash = null
                return
              } else {
                const unplugPath = pnpUtils.getUnpluggedPath(pkg, {configuration: project.configuration});
                if (unplugPath != null && await xfs.existsPromise(unplugPath)) {
                  // console.log('fetching hash for', unplugPath)
                  const res = await execaSync('nix', ['hash', 'path', '--type', 'sha512', unplugPath])
                  if (res.stdout != null) {
                    outputHash = null
                    if (!outputHashByPlatform) outputHashByPlatform = {}
                    outputHashByPlatform[nixCurrentSystem()] = res.stdout
                    return
                  }
                } else {
                  // leave as is? to avoid removing hashes from incompatible platforms
                  if (Object.keys(outputHashByPlatform).length > 0 && outputHash == null) {
                    return
                  }
                }
              }
            }
            outputHash = ''
            outputHashByPlatform = null
            return
          } else {
            outputHash = null
            outputHashByPlatform = null
            return
          }
        })()

        if (shouldBeUnplugged || Object.keys(resolutions).length > 0) {
          packageManifest[manifestPackageId] = {
            shouldBeUnplugged,
            outputHash,
            outputHashByPlatform,
            resolutions,
          }
        }
      }

      let manifestNix: string[] = []

      manifestNix.push('# This file is generated by running "yarn install" inside your project.')
      manifestNix.push('# It is essentially a version of yarn.lock that Nix can better understand')
      manifestNix.push('# Manual changes WILL be lost - proceed with caution!')
      manifestNix.push('{')

      const alphabeticalKeys =
        Object.keys(packageManifest).sort((a, b) => a.localeCompare(b))

      for (const key of alphabeticalKeys) {
        const pkg = packageManifest[key]
        manifestNix.push(`  "${key}" = {`)

        if (pkg.shouldBeUnplugged)
          manifestNix.push(`    shouldBeUnplugged = ${pkg.shouldBeUnplugged};`)
        if (pkg.outputHash != null)
          manifestNix.push(`    outputHash = ${JSON.stringify(pkg.outputHash)};`)
        if (pkg.outputHashByPlatform && Object.keys(pkg.outputHashByPlatform).length > 0) {
          manifestNix.push(`    outputHashByPlatform = {`)
          for (const outputHashByPlatform of Object.keys(pkg.outputHashByPlatform)) {
            manifestNix.push(`      ${JSON.stringify(outputHashByPlatform)} = ${JSON.stringify(pkg.outputHashByPlatform[outputHashByPlatform])};`)
          }
          manifestNix.push(`    };`)
        }
        if (pkg.resolutions && Object.keys(pkg.resolutions).length > 0) {
          manifestNix.push(`    resolutions = {`)
          for (const resolution of Object.keys(pkg.resolutions)) {
            manifestNix.push(`      ${JSON.stringify(resolution)} = ${JSON.stringify(pkg.resolutions[resolution])};`)
          }
          manifestNix.push(`    };`)
        }

        manifestNix.push(`  };`)
      }

      manifestNix.push('}')
      manifestNix.push('')

      fs.writeFileSync(path.join(project.cwd, 'yarn-manifest.nix'), manifestNix.join('\n'), 'utf8')
    },
    populateYarnPaths: async (project: Project) => {
      const packageRegistryDataPath = process.env.YARNNIX_PACKAGE_REGISTRY_DATA_PATH
      if (!!packageRegistryDataPath) {
        const packageRegistryData = JSON.parse(fs.readFileSync(packageRegistryDataPath, 'utf8'))
        const packageRegistryPackages: any[] = Object.entries(packageRegistryData)

        for (const [locatorString, pkg] of packageRegistryPackages) {
          const locator = structUtils.parseLocator(locatorString)
          if (locator.reference.startsWith('workspace:')) {
            await (project as any).addWorkspace(pkg.packageLocation ?? path.join(pkg.packageOut, 'node_modules', pkg.identString))
          }
        }
      }
    },
  },
  commands: [
    FetchCommand,
    ConvertToZipCommand,
    GeneratePnpFile,
    RunBuildScriptsCommand,
  ],
}
