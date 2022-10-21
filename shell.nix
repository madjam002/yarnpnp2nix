{ pkgs, ... }:

with pkgs;

mkShell {
  buildInputs = [
    nodejs
    yarn
  ];

  shellHook = ''
    ln -sf ${yarnBerry}/packages/yarnpkg-pnp.tgz plugin/yarnpkg-pnp.tgz
  '';
}
