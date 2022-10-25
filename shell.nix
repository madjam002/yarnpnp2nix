{ pkgs, ... }:

with pkgs;

mkShell {
  buildInputs = [
    nodejs
    yarn
  ];

  shellHook = ''
  '';
}
