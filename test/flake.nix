{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs/nixos-22.05;
    utils.url = github:gytis-ivaskevicius/flake-utils-plus;
    yarnpnp2nix.url = "../.";
    yarnpnp2nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, utils, yarnpnp2nix }:
    utils.lib.mkFlake {
      inherit self inputs;

      outputsBuilder = channels: rec {
        packages =
          let
            mkYarnPackagesFromLockFile = yarnpnp2nix.lib."${channels.nixpkgs.stdenv.system}".mkYarnPackagesFromLockFile;
            yarnPackages = mkYarnPackagesFromLockFile {
              yarnLock = ./workspace/yarn.lock; # REQUIRED
              yarnManifest = import ./workspace/yarn-manifest.nix; # OPTIONAL for if you're using native node modules, see below
              inherit packageOverrides; # OPTIONAL manual package overrides, see below
            };
            packageOverrides = {
              "esbuild@npm:0.15.10" = {
                # You can add outputHashes here in packageOverrides for native modules
                # e.g
                shouldBeUnplugged = true;
                outputHashByPlatform."x86_64-linux" = "sha512-1vaO639lFTNMppXf76TOY6NEbmVUkAiCNlYM/f3Q7Plf1TIGnyKgfHK7YiCwS8wtLYzzvrEp2JyIewZfhlu2xw==";
                outputHashByPlatform."aarch64-darwin" = "sha512-1vaO639lFTNMppXf76TOY6NEbmVUkAiCNlYM/f3Q7Plf1TIGnyKgfHK7YiCwS8wtLYzzvrEp2JyIewZfhlu2xw==";
              };
              # ... or alternatively install the Yarn plugin as described in README.md
              # to generate a yarn-manifest.nix (pass to mkYarnPackagesFromLockFile like above)
              "esbuild-darwin-arm64@npm:0.15.10" = {
                # e.g
                # outputHash = "sha512-3TVtFilKcMx170rnF8GfVtyqGUT/FnDcrZwlZX3ChtXrehLUKQwnkNlBnTrTdPBbrUygkkp3PZzH6VZrqsCHVQ==";
              };
              "canvas@npm:2.10.1" = {
                __noChroot = true; # HACK escape hatch, do not use if possible, but it's an option if needed
                buildInputs = with channels.nixpkgs; ([
                  autoconf zlib gcc automake pkg-config libtool file
                  python3
                  pixman cairo pango libpng libjpeg giflib librsvg libwebp libuuid
                ] ++ (if channels.nixpkgs.stdenv.isDarwin then [ darwin.apple_sdk.frameworks.CoreText ] else []));
              };
              "sharp@npm:0.31.1" = {
                outputHashByPlatform."x86_64-linux" = "sha512-jirTC3XTIyBYEe1l9IgSr8S4zkkl6YvRNaqeQk1itXmbibRfk0KxziApSAmNByf+y0Z9vmMPmnJpr6OE3PODOg==";
              };
              "testa@workspace:packages/testa" = {
                # manually filter dependencies in the final runtime closure (useful for filtering out dependencies not needed at runtime)
                filterDependencies = dep: dep != "color" && dep != "testf";
                # build script to build the package before packaging up
                build = ''
                  echo $PATH
                  tsc --version
                  tsc
                '';
              };
              "testb@workspace:packages/testb" = {
                build = ''
                  node build
                  webpack --version
                '';
              };
            };
          in
          {
            pkgs = channels.nixpkgs;
            yarn-plugin = yarnpnp2nix.packages."${channels.nixpkgs.stdenv.system}".yarn-plugin;
            react = yarnPackages."react@npm:18.2.0";
            knex = yarnPackages."knex@npm:2.3.0";
            open = yarnPackages."open@patch:open@npm%3A8.4.0#.yarn/patches/open-npm-8.4.0-df63cfe537::version=8.4.0&hash=e6ee73&locator=root-workspace-0b6124%40workspace%3A.";
            fsevents = yarnPackages."fsevents@patch:fsevents@npm%3A2.3.2#optional!builtin<compat/fsevents>::version=2.3.2&hash=18f3a7";
            typescript = yarnPackages."typescript@patch:typescript@npm%3A4.8.4#optional!builtin<compat/typescript>::version=4.8.4&hash=701156";
            esbuild = yarnPackages."esbuild@npm:0.15.10";
            testa = yarnPackages."testa@workspace:packages/testa";
            testb = yarnPackages."testb@workspace:packages/testb";
            teste = yarnPackages."teste@workspace:packages/teste";
          };
        images = {
          testa = channels.nixpkgs.dockerTools.streamLayeredImage {
            name = "testa";
            maxLayers = 1000;
            config.Cmd = "${packages.testa}/bin/testa-test";
          };
          testb = channels.nixpkgs.dockerTools.streamLayeredImage {
            name = "testb";
            maxLayers = 1000;
            config.Cmd = "${packages.testb}/bin/testb";
          };
        };
        devShell = import ./shell.nix {
          pkgs = channels.nixpkgs;
        };
        yarnLock = yarnpnp2nix.lib."${channels.nixpkgs.stdenv.system}".parseYarnLock { yarnLockPath = ./workspace/yarn.lock; yarnLockJSON = (yarnpnp2nix.lib."${channels.nixpkgs.stdenv.system}".fromYAML.parse (builtins.readFile ./workspace/yarn.lock)); };
      };
    };
}
