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
            mkYarnPackageFromManifest = yarnpnp2nix.lib."${channels.nixpkgs.stdenv.system}".mkYarnPackageFromManifest;
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
              "testa@workspace:packages/testa" = {
                build = ''
                  echo $PATH
                  tsc --version
                '';
              };
              "testb@workspace:packages/testb" = {
                build = ''
                  node index
                '';
              };
            };
          in
          {
            pkgs = channels.nixpkgs;
            yarn-plugin = yarnpnp2nix.packages."${channels.nixpkgs.stdenv.system}".yarn-plugin;
            react = mkYarnPackageFromManifest {
              yarnManifest = import ./workspace/yarn-manifest.nix;
              package = "react@npm:18.2.0";
              inherit packageOverrides;
            };
            esbuild = mkYarnPackageFromManifest {
              yarnManifest = import ./workspace/yarn-manifest.nix;
              package = "esbuild@npm:0.15.10";
              inherit packageOverrides;
            };
            testa = mkYarnPackageFromManifest {
              yarnManifest = import ./workspace/yarn-manifest.nix;
              package = "testa@workspace:packages/testa";
              inherit packageOverrides;
            };
            testb = mkYarnPackageFromManifest {
              yarnManifest = import ./workspace/yarn-manifest.nix;
              package = "testb@workspace:packages/testb";
              inherit packageOverrides;
            };
          };
        images = {
          testb = channels.nixpkgs.dockerTools.streamLayeredImage {
            name = "testb";
            config.Cmd = "${packages.testb}/bin/testb";
          };
        };
        devShell = import ./shell.nix {
          pkgs = channels.nixpkgs;
        };
      };
    };
}
