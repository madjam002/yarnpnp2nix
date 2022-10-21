import fs from 'fs'
import path from 'path'
import { PassThrough } from 'stream'
import { execa, execaSync } from 'execa'

const { generateInlinedScript } = require('@yarnpkg/pnp')

let getExistingManifestNix = require('../lib/getExistingManifest.nix.txt')

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

const plugin: Plugin<Hooks> = {
  name: `plugin-nix-store`,
  factory: require => {
    const { Configuration, Project, Cache, StreamReport, Manifest, tgzUtils, structUtils, miscUtils, scriptUtils } = require("@yarnpkg/core")
    const { BaseCommand } = require('@yarnpkg/cli')
    const { xfs, CwdFS, PortablePath } = require('@yarnpkg/fslib')
    const { ZipOpenFS } = require('@yarnpkg/libzip')
    const { getPnpPath, pnpUtils } = require('@yarnpkg/plugin-pnp')
    const { Option } = require('clipanion')
    const t = require('typanion')

    class FetchCommand extends BaseCommand {
      static paths = [['nix', 'fetch-by-locator']]

      locator = Option.String({validator: t.isString()})
      outDirectory = Option.String({validator: t.isString()})

      async execute() {
        const configuration = await Configuration.find(process.cwd(), this.context.plugins);
        const {project, workspace} = await Project.find(configuration, process.cwd());

        const fetcher = configuration.makeFetcher()

        const installReport = await StreamReport.start({
          configuration,
          stdout: this.context.stdout,
          includeLogs: !this.context.quiet,
        }, async report => {
          // await project.install({cache, report});

          configuration.values.set('enableMirror', false) // disable global cache as we want to output to outDirectory

          const fetchOptions = { checksums: new Map(), project, cache: new Cache(this.outDirectory, { check: false, configuration, immutable: false }), fetcher, report }
          const fetched = await fetcher.fetch(project.originalPackages.get(this.locator), fetchOptions)

          fs.renameSync(fetched.packageFs.target, path.join(this.outDirectory, 'output.zip'))
        });
      }
    }

    class CreateLockFileCommand extends BaseCommand {
      static paths = [['nix', 'create-lockfile']]

      packageRegistryDataJSON = Option.String({validator: t.isString()})

      async execute() {
        const configuration = await Configuration.find(process.cwd(), this.context.plugins);

        const project = new Project(process.cwd(), { configuration })
        await project.setupResolutions()

        const packageRegistryData = JSON.parse(this.packageRegistryDataJSON)

        for (const pkgName of Object.keys(packageRegistryData)) {
          for (const reference of Object.keys(packageRegistryData[pkgName])) {
            const pkg = packageRegistryData[pkgName][reference]?.manifest

            //  {
            //   identHash: '9ca470fa61f45e067b8912c4342a3400ef0a72ba40cc23c2c0b328fe2213be1f145c35685252f614b708022def6c86380b66b07686cf36dd332caae8d849136f',
            //   scope: null,
            //   name: 'typescript',
            //   locatorHash: '9c0a3355115b252fc54c3916c6fcccf92c84041e4ac48c6ff1334782d6b0b707fd13645250cee7bae78e22cc73b5b806db08dd49dd0afa0ffcb6adeb10543ad6',
            //   reference: 'npm:4.8.4',
            //   version: '4.8.4',
            //   languageName: 'node',
            //   linkType: 'HARD',
            //   conditions: null,
            //   dependencies: Map(0) {},
            //   peerDependencies: Map(0) {},
            //   dependenciesMeta: Map(0) {},
            //   peerDependenciesMeta: Map(0) {},
            //   bin: Map(2) { 'tsc' => 'bin/tsc', 'tsserver' => 'bin/tsserver' }
            // }

            const origPackage = {
              identHash: pkg.descriptorIdentHash,
              scope: pkg.scope,
              name: pkg.flatName,
              locatorHash: pkg.locatorHash,
              reference: pkg.reference,
              languageName: pkg.languageName,
              linkType: pkg.linkType,
              conditions: null,
              // it appears we don't need to bother storing dependencies as the above is enough to reconstruct the parts of the lock file that we need
              // dependencies: new Map(),
              // bin: pkg.bin, // TODO to map
            }
            project.originalPackages.set(pkg.locatorHash, origPackage)

            // storedResolutions is a map of descriptorHash -> locatorHash
            project.storedResolutions.set(pkg.descriptorHash, pkg.locatorHash)

            // storedChecksums is a map of locatorHash -> checksum
            if (pkg.checksum != null) project.storedChecksums.set(pkg.locatorHash, pkg.checksum)

            const descriptor = {
              identHash: pkg.descriptorIdentHash,
              scope: pkg.scope,
              name: pkg.flatName,
              descriptorHash: pkg.descriptorHash,
              range: pkg.descriptorRange,
            }
            project.storedDescriptors.set(pkg.descriptorHash, descriptor)
          }
        }

        project.storedPackages = project.originalPackages

        await project.persistLockfile()
      }
    }

    class ConvertToZipCommand extends BaseCommand {
      static paths = [['nix', 'convert-to-zip']]

      locator = Option.String({validator: t.isString()})
      tgzPath = Option.String({validator: t.isString()})
      outPath = Option.String({validator: t.isString()})

      async execute() {
        const configuration = await Configuration.find(process.cwd(), this.context.plugins);
        const {project, workspace} = await Project.find(configuration, process.cwd());

        const locator = project.originalPackages.get(this.locator)

        const { path } = await tgzUtils.convertToZip(fs.readFileSync(this.tgzPath), {
          compressionLevel: project.configuration.get(`compressionLevel`),
          prefixPath: structUtils.getIdentVendorPath(locator),
          stripComponents: 1,
        })
        fs.copyFileSync(path, this.outPath)
      }
    }

    class GeneratePnpFile extends BaseCommand {
      static paths = [['nix', 'generate-pnp-file']]

      outDirectory = Option.String({validator: t.isString()})
      packageRegistryDataJSON = Option.String({validator: t.isString()})
      topLevelPackageDirectory = Option.String({validator: t.isString()})

      async execute() {
        const configuration = await Configuration.find(process.cwd(), this.context.plugins);
        const {project, workspace} = await Project.find(configuration, process.cwd());

        const pnpPath = getPnpPath({ cwd: this.outDirectory });

        const pnpFallbackMode = project.configuration.get(`pnpFallbackMode`);

        const dependencyTreeRoots = project.workspaces.map(({anchoredLocator}) => ({name: structUtils.stringifyIdent(anchoredLocator), reference: anchoredLocator.reference}));
        const enableTopLevelFallback = pnpFallbackMode !== `none`;
        const fallbackExclusionList = [];
        const fallbackPool = new Map();
        const ignorePattern = miscUtils.buildIgnorePattern([`.yarn/sdks/**`, ...project.configuration.get(`pnpIgnorePatterns`)]);
        // const packageRegistry = this.packageRegistry;
        const shebang = project.configuration.get(`pnpShebang`);

        const packageRegistry = new Map()

        const packageRegistryData = JSON.parse(this.packageRegistryDataJSON)

        let topLevelPackage = null

        for (const pkgName of Object.keys(packageRegistryData)) {
          for (const reference of Object.keys(packageRegistryData[pkgName])) {
            const pkg = packageRegistryData[pkgName][reference]

            const packageDependencies = new Map()
            if (pkg.packageDependencies != null) {
              for (const dep of Object.keys(pkg.packageDependencies)) {
                packageDependencies.set(dep, pkg.packageDependencies[dep]);
              }
            }

            const packageData = {
              // packageLocation: pkg.packageLocation.startsWith('/nix/store') ? `../../..${pkg.packageLocation}` : pkg.packageLocation,
              packageLocation: pkg.packageLocation,
              packageDependencies,
              // packagePeers,
              linkType: pkg.linkType,
              // discardFromLookup: fetchResult.discardFromLookup || false,
            }

            miscUtils.getMapWithDefault(packageRegistry, pkgName).set(reference, packageData);

            if (pkg.packageLocation.startsWith(this.topLevelPackageDirectory)) {
              topLevelPackage = packageData
            }
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
          fallbackExclusionList,
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
    }

    class RunBuildScriptsCommand extends BaseCommand {
      static paths = [['nix', 'run-build-scripts']]

      locator = Option.String({validator: t.isString()})
      pnpRootDirectory = Option.String({validator: t.isString()})
      packageDirectory = Option.String({validator: t.isString()})

      async execute() {
        const configuration = await Configuration.find(process.cwd(), this.context.plugins);
        const {project, workspace} = await Project.find(configuration, process.cwd());

        const pkg = project.originalPackages.get(this.locator)

        project.cwd = this.pnpRootDirectory

        // need to find a way to make this work without restoring install state...
        // await project.restoreInstallState({
          //   restoreResolutions: true,
          // });
        project.storedPackages = project.originalPackages
        // next thing to fix is "couldn't find XXX in the currently installed PnP map"

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

          const exitCode = await scriptUtils.executePackageScript(pkg, scriptName, [], {cwd: this.packageDirectory, project, stdin: process.stdin, stdout: process.stdout, stderr: process.stderr});

          if (exitCode > 0) {
            return exitCode
          }
        }
      }
    }

    return {
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

          for (const [__, pkg] of project.originalPackages) {
            const linker = linkers.find(linker => linker.supportsPackage(pkg, linkerOptions));
            const installer = installers.get(linker)

            const src = pkg.reference.startsWith('workspace:') ? `./${pkg.reference.substring('workspace:'.length)}` : null
            const shouldBeUnplugged = src != null ? true : (installer?.shouldBeUnplugged != null ? installer.customData.store.get(pkg.locatorHash) != null ? installer.shouldBeUnplugged(pkg, installer.customData.store.get(pkg.locatorHash), project.getDependencyMeta(structUtils.isVirtualLocator(pkg) ? structUtils.devirtualizeLocator(pkg) : pkg, pkg.version)) : false : true)
            const willOutputBeZip = !src && !shouldBeUnplugged

            let installCondition = null

            if (pkg.conditions != null) {
              const conditions = pkg.conditions.split('&').map(part => part.trim().split('='))
              let nixConditions = []

              for (const condition of conditions) {
                const key = condition[0]
                const v = condition[1]
                if (key === 'os') {
                  if (v === 'linux') {
                    nixConditions.push('stdenv.isLinux')
                  } else if (v === 'darwin') {
                    nixConditions.push('stdenv.isDarwin')
                  } else {
                    nixConditions.push('false')
                  }
                } else if (key === 'cpu') {
                  const cpuMapping: any = {
                    'ia32': 'stdenv.isi686',
                    'x64': 'stdenv.isx86_64',
                    'arm': 'stdenv.isAarch32',
                    'arm64': 'stdenv.isAarch64',
                  }
                  if (cpuMapping[v] != null) {
                    nixConditions.push(cpuMapping[v])
                  } else {
                    nixConditions.push('false')
                  }
                } else if (key === 'libc') {
                  if (v !== 'glibc') {
                    // only glibc is supported on Nix, other implementations like musl are not supported
                    nixConditions.push('false')
                  }
                }
              }

              if (nixConditions.length > 0) {
                installCondition = `stdenv: ${nixConditions.map(cond => `(${cond})`).join(' && ')}`
              }
            }

            const dependencies = await Promise.all(Array.from(pkg.dependencies).map(async ([key, value]) => {
              const dependency = await project.configuration.reduceHook(hooks => {
                return hooks.reduceDependency;
              }, value, project, pkg, value, {
                // resolver,
                // resolveOptions,
              });

              const resolvedLocatorHash = project.storedResolutions.get(dependency?.descriptorHash ?? value.descriptorHash)
              const resolvedPkg = resolvedLocatorHash != null ? project.originalPackages.get(resolvedLocatorHash) :
                null
              return {
                key,
                name: structUtils.stringifyIdent(value),
                packageManifestId: structUtils.stringifyIdent(resolvedPkg) + '@' + resolvedPkg.reference,
              }
            }))

            const allVisibleDependencies = await Promise.all(Array.from(pkg.dependencies).map(async ([key, value]) => {
              // same as dependencies, but in yarn scriptUtils sometimes dependencies get resolved without the reduceDependency hook above,
              // which can resolve to different dependencies, and then scriptUtils expects those packages to be in the lock file/pnp map,
              // so we must include them in case they are used.
              const resolvedLocatorHash = project.storedResolutions.get(value.descriptorHash)
              const resolvedPkg = resolvedLocatorHash != null ? project.originalPackages.get(resolvedLocatorHash) :
                null
              return {
                key,
                name: structUtils.stringifyIdent(value),
                packageManifestId: structUtils.stringifyIdent(resolvedPkg) + '@' + resolvedPkg.reference,
              }
            }))

            const manifestPackageId = structUtils.stringifyIdent(pkg) + '@' + pkg.reference

            const packageInExistingManifest = existingManifest?.[manifestPackageId]

            let outputHash = packageInExistingManifest?.outputHash
            let outputHashByPlatform: any = packageInExistingManifest?.outputHashByPlatform ?? {}

            await (async function() {
              if (src != null) {
                // no outputHash for when a src is provided as the build will be completed locally.
                outputHash = null
                outputHashByPlatform = null
                return
              } else if (willOutputBeZip) {
                // simple, use the hash of the zip file
                outputHash = project.storedChecksums.get(pkg.locatorHash)?.substring(2) // first 2 characters are like a checksum version that yarn uses, we can discard
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
                      const res = await execa('nix', ['hash', 'path', '--type', 'sha512', unplugPath])
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

            const descriptorHash = getByValue(project.storedResolutions, pkg.locatorHash)
            const descriptor = project.storedDescriptors.get(descriptorHash)
            const yarnChecksum = project.storedChecksums.get(pkg.locatorHash)

            packageManifest[manifestPackageId] = {
              name: structUtils.stringifyIdent(pkg),
              reference: pkg.reference,
              locatorHash: pkg.locatorHash,
              linkType: pkg.linkType, // HARD package links are the most common, and mean that the target location is fully owned by the package manager. SOFT links, on the other hand, typically point to arbitrary user-defined locations on disk.
              outputName: [structUtils.stringifyIdent(pkg), pkg.version, pkg.locatorHash.substring(0, 10)].filter(part => !!part).join('-') + (willOutputBeZip ? '.zip' : ''),
              outputHash,
              outputHashByPlatform,
              src,
              shouldBeUnplugged,
              installCondition,
              bin: pkg.bin != null ? Object.fromEntries(pkg.bin) : null,

              // other things necessary for recreating lock file that we don't necessarily use
              flatName: pkg.name,
              descriptor: descriptor,
              languageName: pkg.languageName,
              scope: pkg.scope,
              checksum: yarnChecksum,

              // TODO this includes devDependencies, we need to split them out
              dependencies,
              otherVisibleDependencies: allVisibleDependencies.filter(dep => !dependencies.find(pkg => pkg.packageManifestId === dep.packageManifestId)),
            }
          }

          let manifestNix: string[] = []

          manifestNix.push('# This file is generated by running "yarn install" inside your project.')
          manifestNix.push('# It is essentially a version of yarn.lock that Nix can better understand')
          manifestNix.push('# Manual changes WILL be lost - proceed with caution!')
          manifestNix.push('let')
          manifestNix.push('  packages = {')

          function writeDependencies(key: string, dependencies: any[]) {
            if (dependencies.length > 0) {
              manifestNix.push(`      ${key} = {`)
              for (const dep of dependencies) {
                manifestNix.push(`        ${JSON.stringify(dep.name)} = packages.${JSON.stringify(dep.packageManifestId)};`)
              }
              manifestNix.push(`      };`)
            }
          }

          for (const key of Object.keys(packageManifest)) {
            const pkg = packageManifest[key]
            manifestNix.push(`    "${key}" = {`)
            manifestNix.push(`      name = ${JSON.stringify(pkg.name)};`)
            manifestNix.push(`      reference = ${JSON.stringify(pkg.reference)};`)
            manifestNix.push(`      locatorHash = ${JSON.stringify(pkg.locatorHash)};`)
            manifestNix.push(`      linkType = ${JSON.stringify(pkg.linkType)};`)
            manifestNix.push(`      outputName = ${JSON.stringify(pkg.outputName)};`)
            if (pkg.outputHash != null)
              manifestNix.push(`      outputHash = ${JSON.stringify(pkg.outputHash)};`)
            if (pkg.outputHashByPlatform && Object.keys(pkg.outputHashByPlatform).length > 0) {
              manifestNix.push(`      outputHashByPlatform = {`)
              for (const outputHashByPlatform of Object.keys(pkg.outputHashByPlatform)) {
                manifestNix.push(`        ${JSON.stringify(outputHashByPlatform)} = ${JSON.stringify(pkg.outputHashByPlatform[outputHashByPlatform])};`)
              }
              manifestNix.push(`      };`)
            }
            if (pkg.src)
              manifestNix.push(`      src = ${pkg.src};`)
            if (pkg.shouldBeUnplugged)
              manifestNix.push(`      shouldBeUnplugged = ${pkg.shouldBeUnplugged};`)
            if (pkg.installCondition)
              manifestNix.push(`      installCondition = ${pkg.installCondition};`)

            // other things necessary for recreating lock file that we don't necessarily use
            manifestNix.push(`      flatName = ${JSON.stringify(pkg.flatName)};`)
            manifestNix.push(`      descriptorHash = ${JSON.stringify(pkg.descriptor.descriptorHash)};`)
            manifestNix.push(`      languageName = ${JSON.stringify(pkg.languageName)};`)
            manifestNix.push(`      scope = ${JSON.stringify(pkg.scope)};`)
            manifestNix.push(`      descriptorRange = ${JSON.stringify(pkg.descriptor.range)};`)
            manifestNix.push(`      descriptorIdentHash = ${JSON.stringify(pkg.descriptor.identHash)};`)
            if (pkg.checksum)
              manifestNix.push(`      checksum = ${JSON.stringify(pkg.checksum)};`)

            if (pkg.bin && Object.keys(pkg.bin).length > 0) {
              manifestNix.push(`      bin = {`)
              for (const bin of Object.keys(pkg.bin)) {
                manifestNix.push(`        ${JSON.stringify(bin)} = ${JSON.stringify(pkg.bin[bin])};`)
              }
              manifestNix.push(`      };`)
            }

            writeDependencies('dependencies', pkg.dependencies)
            writeDependencies('otherVisibleDependencies', pkg.otherVisibleDependencies)

            manifestNix.push(`    };`)
          }

          manifestNix.push('  };')
          manifestNix.push('in')
          manifestNix.push('packages')
          manifestNix.push('')

          fs.writeFileSync(path.join(project.cwd, 'yarn-manifest.nix'), manifestNix.join('\n'), 'utf8')
        },
        populateYarnPaths: async (project: Project) => {
          if (process.env.YARNNIX_PACK_DIRECTORY != null) {
            const rootWorkspace = project.workspacesByCwd.get(project.cwd)
            if (rootWorkspace != null) {
              rootWorkspace.cwd = process.env.YARNNIX_PACK_DIRECTORY
            }
          }
        },
      },
      commands: [
        CreateLockFileCommand,
        FetchCommand,
        ConvertToZipCommand,
        GeneratePnpFile,
        RunBuildScriptsCommand,
      ],
    }
  },
};

function getByValue(map, searchValue) {
  for (let [key, value] of map.entries()) {
    if (value === searchValue)
      return key;
  }
}

module.exports = plugin;