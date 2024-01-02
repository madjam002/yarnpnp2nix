{ pkgs, ... }:

with pkgs;

mkShell {
  buildInputs = [
    nodejs
    yarn-berry
  ];

  shellHook = ''
  '';
}
