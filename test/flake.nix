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
                outputHashByPlatform."x86_64-linux" = "sha512-JLsYDltCSWhFcmTVQGYko9VVmpG1qAdeJFMsN3yvO7sktJ0RghsC+/QDud1CgQ9XilIM6XyqOfmI9YkCg7vtuQ==";
                outputHashByPlatform."aarch64-darwin" = "sha512-caJxLF7+d8wUQPwiBG7liRlRBWRwfJ8c7ZABOvmRdXHjitoPXBE59S1DCaiyaQI2CwGRy0LW97MPBiS45UeB5w==";
              };
              "esbuild-darwin-arm64@npm:0.15.10" = {
                outputHash = "sha512-3TVtFilKcMx170rnF8GfVtyqGUT/FnDcrZwlZX3ChtXrehLUKQwnkNlBnTrTdPBbrUygkkp3PZzH6VZrqsCHVQ==";
              };
              "esbuild-linux-64@npm:0.15.10" = {
                outputHash = "sha512-NbPc1wvUbnWD7ALYPDF2JS/t2JA9ZtUHUDZj+DO0c8EaZVwHb1lfCrXTIDRC3hXOMUgexnT9akqLeWv8VUxppg==";
              };
              "@next/swc-linux-x64-gnu@npm:12.3.1" = {
                outputHash = "sha512-dH25oxgpuWy4KdoQ0rnm/INsdEKOTGh/l3gT3lpIBmpb/5CT27GlQP0MOItO8XK7AponRDsQiFTPme+ZEIDgmA==";
              };
              "@next/swc-linux-x64-musl@npm:12.3.1" = {
                outputHash = "sha512-TUnXYaR1Zu+0P5/Xt/6rhjlmTVhLwUmppaJStRROiZfWtFdqG8rr5J5mAqzWhscB33+kOeUN589JWTFSGjB9kg==";
              };
              "@next/swc-darwin-arm64@npm:12.3.1" = {
                outputHash = "sha512-b//AHo1j/u36SPNM++IWnil4r379VXBHn9UubfZzhzSL7S1bons2wX0o2YXGN70JHUTIxpD9w7VAANCbHCyKSQ==";
              };
            };
          in
          {
            pkgs = channels.nixpkgs;
            yarn-plugin = yarnpnp2nix.packages."${channels.nixpkgs.stdenv.system}".yarn-plugin;
            react = mkYarnPackageFromManifest {
              packageManifest = (import ./workspace/yarn-manifest.nix)."react@npm:18.2.0";
              inherit packageOverrides;
            };
            esbuild = mkYarnPackageFromManifest {
              packageManifest = (import ./workspace/yarn-manifest.nix)."esbuild@npm:0.15.10";
              inherit packageOverrides;
            };
            testa = mkYarnPackageFromManifest {
              packageManifest = (import ./workspace/yarn-manifest.nix)."testa@workspace:packages/testa";
              inherit packageOverrides;
            };
            testb = mkYarnPackageFromManifest {
              packageManifest = (import ./workspace/yarn-manifest.nix)."testb@workspace:packages/testb";
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
