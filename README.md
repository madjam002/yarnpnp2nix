# yarnpnp2nix

Yet another way of packaging Node applications with Nix. Unlike alternatives, this plugin is built for performance (both speed and disk usage) and aims to be unique with the following goals:

- NPM dependencies should be stored in the /nix/store individually rather than in a huge "node_modules" derivation. Zip files should be used where possible to work well with Yarn PNP
- Rebuilding when just changing source code should be fast as dependencies shouldn't be fetched
- Adding a new dependency should just fetch that dependency rather than fetching or linking all node_modules again
- Build native modules (e.g canvas) once, and once they are built they shouldn't be built again across packages
- Unplugged/native modules should have their outputs hashed to try and enforce reproducibility
- When using workspaces, adding a dependency in another package (modifying the yarn.lock file) in the workspace shouldn't cause a different package to have to be rebuilt

Known caveats:
- Initial build can be a bit slow as each dependency is a separate derivation and needs to be fetched from the package registry. Still, a sample project with a couple of thousand dependencies (!!) only takes a couple of minutes to build all of the dependency derivations. Make sure you have enough parallelism in your `nix build` (either using the `-j` argument or setting your Nix config appropriately)

Possible future improvements:
- devDependencies should only be fetched if a package needs to be built/unplugged, currently all dependencies are included
- When adding a Yarn package, copy it straight into the nix store rather than a Yarn cache in the users home directory
- ...and run postinstall/install builds from within Nix by defaulting Yarn to --ignore-scripts


## License

Licensed under the MIT License.

View the full license [here](/LICENSE).
