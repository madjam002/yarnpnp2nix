{ stdenv, rsync, yarn, fetchzip, nodejs }:

stdenv.mkDerivation {
  name = "yarn-berry";
  src = fetchzip {
    url = "https://github.com/yarnpkg/berry/archive/b7f42424f6a13ffdb0bd1e7e03693ba03b8e1eda.zip";
    sha256 = "sha256-sflVB/kj3KYQSfGEVr+cCCRQPcLCTbeAABDHF/qfbVI=";
  };

  phases = [ "getSource" "patchPhase" "build" ];

  patches = [
    ./yarnPatches/pack-specific-project.patch
    ./yarnPatches/pnp-nix-store-support.patch
  ];

  buildInputs = [
    yarn
    rsync
    nodejs
  ];

  getSource = ''
    tmpDir=$PWD
    mkdir -p $tmpDir/yarn
    shopt -s dotglob
    cp --no-preserve=mode -r $src/* $tmpDir/yarn/
    cd $tmpDir/yarn
  '';

  build = ''
    yarn build:cli
    yarn build:compile packages/yarnpkg-pnp
    (cd packages/yarnpkg-pnp && yarn pack -o package.tgz)
    mkdir -p $out/bin $out/packages
    mv packages/yarnpkg-cli/bundles/yarn.js $out/bin/yarn
    mv packages/yarnpkg-pnp/package.tgz $out/packages/yarnpkg-pnp.tgz
    chmod +x $out/bin/yarn
    patchShebangs $out/bin/yarn
  '';
}
