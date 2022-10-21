{
  description = "yarnpnp2nix";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs/nixos-22.05;
    utils.url = github:gytis-ivaskevicius/flake-utils-plus;
  };

  outputs = inputs@{ self, nixpkgs, utils, ... }:
    let
      nixpkgsLib = nixpkgs.lib;
      flake = utils.lib.mkFlake {
        inherit self inputs;

        channels.nixpkgs.overlaysBuilder = channels: [
          (final: prev: {
            yarnBerry = prev.callPackage ./yarn.nix {};
          })
        ];

        outputsBuilder = channels: {
          packages = {
            yarn-plugin = channels.nixpkgs.callPackage ./yarnPlugin.nix {};
          };
          lib = {
            mkYarnPackageFromManifest = (import ./lib/mkYarnPackage.nix { pkgs = channels.nixpkgs; lib = channels.nixpkgs.lib; }).mkYarnPackageFromManifest;
          };
          devShell = import ./shell.nix {
            pkgs = channels.nixpkgs;
          };
        };
      };
    in
    flake;
}
