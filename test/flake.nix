{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs/nixos-22.05;
    utils.url = github:gytis-ivaskevicius/flake-utils-plus;
    yarnpnp2nix.url = "../.";
  };

  outputs = inputs@{ self, nixpkgs, utils, yarnpnp2nix }:
    utils.lib.mkFlake {
      inherit self inputs;

      outputsBuilder = channels: rec {
        packages =
          let
            mkYarnPackagesFromManifest = yarnpnp2nix.lib."${channels.nixpkgs.stdenv.system}".mkYarnPackagesFromManifest;
            yarnPackages = mkYarnPackagesFromManifest {
              yarnManifest = import ./workspace/yarn-manifest.nix;
              inherit packageOverrides;
            };
            packageOverrides = {
              "esbuild@npm:0.15.10" = {
                # e.g
                # outputHashByPlatform."x86_64-linux" = "sha512-JLsYDltCSWhFcmTVQGYko9VVmpG1qAdeJFMsN3yvO7sktJ0RghsC+/QDud1CgQ9XilIM6XyqOfmI9YkCg7vtuQ==";
                # outputHashByPlatform."aarch64-darwin" = "sha512-caJxLF7+d8wUQPwiBG7liRlRBWRwfJ8c7ZABOvmRdXHjitoPXBE59S1DCaiyaQI2CwGRy0LW97MPBiS45UeB5w==";
              };
              "esbuild-darwin-arm64@npm:0.15.10" = {
                # e.g
                # outputHash = "sha512-3TVtFilKcMx170rnF8GfVtyqGUT/FnDcrZwlZX3ChtXrehLUKQwnkNlBnTrTdPBbrUygkkp3PZzH6VZrqsCHVQ==";
              };
              "canvas@npm:2.10.1" = {
                __noChroot = true;
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
                filterDependencies = dep: dep != "color" && dep != "testf";
                build = ''
                  echo $PATH
                  tsc --version
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
            esbuild = yarnPackages."esbuild@npm:0.15.10";
            testa = yarnPackages."testa@workspace:packages/testa";
            testb = yarnPackages."testb@workspace:packages/testb";
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
      };
    };
}
