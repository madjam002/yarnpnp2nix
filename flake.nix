{
  description = "yarnpnp2nix";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs/nixos-22.05;
    utils.url = github:numtide/flake-utils;
  };

  outputs = inputs@{ self, nixpkgs, utils, ... }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              yarnBerry = prev.callPackage ./yarn.nix {};
            })
          ];
        };
      in
      rec {
        packages = {
          yarn-plugin = pkgs.callPackage ./yarnPlugin.nix {};
        };
        lib = {
          mkYarnPackagesFromLockFile = (import ./lib/mkYarnPackage.nix { defaultPkgs = pkgs; lib = pkgs.lib; }).mkYarnPackagesFromLockFile;
          fromYAML = (import ./lib/fromYAML.nix { lib = pkgs.lib; });
          parseYarnLock = (import ./lib/parseYarnLock.nix { lib = pkgs.lib; });
        };
        devShell = import ./shell.nix {
          inherit pkgs;
        };
      }
    );
}
