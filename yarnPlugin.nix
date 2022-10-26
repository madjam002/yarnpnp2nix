{ stdenv, lib, yarnBerry, nodejs, jq }:

stdenv.mkDerivation {
  name = "yarn-plugin-yarnpnp2nix";
  phases = [ "build" ];

  build = ''
    mkdir -p $out
    cp ${./plugin/dist/plugin-yarnpnp2nix.js} $out/plugin.js
  '';
}
