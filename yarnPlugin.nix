{ stdenv, lib, yarnBerry, nodejs, jq }:

stdenv.mkDerivation {
  name = "yarn-plugin-yarnpnp2nix";
  phases = [ "build" ];

  build = ''
    mkdir -p $out
    cp ${./plugin/dist/index.js} $out/plugin.js
  '';
}
