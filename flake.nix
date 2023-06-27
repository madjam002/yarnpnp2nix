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
    let
      overlay = final: prev: {
        yarnBerry = final.callPackage ./yarn.nix {};
        yarn-plugin-yarnpnp2nix = final.callPackage ./yarnPlugin.nix {};
        yarnpnp2nixLib = import ./lib/mkYarnPackage.nix { defaultPkgs = final; lib = final.lib; };
      };
    in (utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [overlay];
        };
      in
      rec {
        packages = {
          yarn-plugin = pkgs.yarn-plugin-yarnpnp2nix;
          yarnBerry = pkgs.yarnBerry;
          yarnpnp2nix-test = pkgs.writeShellApplication {
            name = "yarnpnp2nix-test";
            runtimeInputs = [ pkgs.jq ];
            text = builtins.readFile ./runTests.sh;
          };
        };
        lib = pkgs.yarnpnp2nixLib;
        devShell = import ./shell.nix {
          inherit pkgs;
        };
      }
    ))
    //
    { overlays.default = overlay; }
  ;
}
