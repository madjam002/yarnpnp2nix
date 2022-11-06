# yarnpnp2nix

Yet another way of packaging Node applications with Nix. Unlike alternatives, this plugin is built for performance (both speed and disk usage) and aims to be unique with the following goals:

- **Builds packages directly by reading yarn.lock**, no codegen\* or IFD needed
- **NPM dependencies should be stored in the /nix/store individually** rather than in a huge "node_modules" derivation. Zip files should be used where possible to work well with Yarn PNP
- Rebuilding when just changing source code should be fast as dependencies shouldn't be fetched
- Adding a new dependency should just fetch that dependency rather than fetching or linking all node_modules again
- Build native modules (e.g canvas) once, and once they are built they shouldn't be built again across packages
- Unplugged/native modules should have their outputs hashed to try and enforce reproducibility
- When using workspaces, adding a dependency in another package (modifying the yarn.lock file) in the workspace shouldn't cause a different package to have to be rebuilt
- devDependencies shouldn't be included as references in the final runtime derivation, only dependencies

\* Native / unplugged modules need to be flagged as such, along with their outputHashes for the built package, see examples in [test/flake.nix](./test/flake.nix). A Yarn plugin can be installed that will codegen a small manifest file that contains the list of native / unplugged modules.

## Usage

Requires a Yarn version > 3 project using PnP linking (the default). Zero installs are not required, so it's recommended to just use the global cache when developing your project rather than storing dependencies in your repo.

- Create a `flake.nix` if you haven't already for your project, add this repo (`yarnpnp2nix`) as an input (e.g `yarnpnp2nix.url = github:madjam002/yarnpnp2nix;`)

- See [test/flake.nix](./test/flake.nix) for an example on how to create Nix derivations for Yarn packages using `mkYarnPackagesFromLockFile`.

If you are using lots of native node modules, you may want to install the optional Yarn plugin which will codegen a small manifest that allows yarnpnp2nix to properly build native modules:

- Install Yarn plugin in your project:
  ```
  yarn plugin import https://github.com/madjam002/yarnpnp2nix/raw/master/plugin/dist/plugin-yarnpnp2nix.js
  ```

- Run `yarn` to make sure all packages are installed and to automatically generate a `yarn-manifest.nix` for your project.

## Other notes

Known caveats:
- Initial build can be a bit slow as each dependency is a separate derivation and needs to be fetched from the package registry. Still, a sample project with a couple of thousand dependencies (!!) only takes a couple of minutes to build all of the dependency derivations. Make sure you have enough parallelism in your `nix build` (either using the `-j` argument or setting your Nix config appropriately)

Possible future improvements:
- When adding a Yarn package, copy it straight into the nix store rather than a Yarn cache in the users home directory
- ...and run postinstall/install builds from within Nix by defaulting Yarn to --ignore-scripts

## Troubleshooting

### `hash mismatch in fixed-output derivation` when fetching dependencies

If you get hash mismatches, the dependency probably is a native module or unplugged (has postinstall scripts). Install the Yarn plugin as directed above or manually set the `shouldBeUnplugged` attribute in `packageOverrides`.

## License

Licensed under the MIT License.

View the full license [here](/LICENSE).
