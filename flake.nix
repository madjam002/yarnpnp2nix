{
  description = "yarnpnp2nix";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs/nixos-22.05;
    utils.url = github:numtide/flake-utils;
    flake-compat ={
      url = "github:edolstra/flake-compat";
      flake = false;
    };
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
          mkYarnPackagesFromManifest = (import ./lib/mkYarnPackage.nix { defaultPkgs = pkgs; lib = pkgs.lib; }).mkYarnPackagesFromManifest;
        };
        devShell = import ./shell.nix {
          inherit pkgs;
        };
      }
    );
}
