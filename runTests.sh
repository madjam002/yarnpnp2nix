#!/usr/bin/env bash

set -e

system="$(nix eval --impure --json --expr builtins.currentSystem | jq -r)"

pushd test

nix eval --json .#packages.aarch64-darwin.testa.transitiveRuntimePackages

nix build -L .#packages.$system.testb --option sandbox relaxed
./result/bin/testb

nix build -L .#packages.$system.testa
./result/bin/testa-peer-test

# The generated .pnp.cjs has to name the top level package, and has to point at
# packages that opted out of the node_modules layout via packageDirectory. Both
# also run during testa's own build, against the .pnp.cjs that generate-pnp-file
# writes there; this run covers the separate one finalDerivation generates for
# the runtime (dependencies only, no devDependencies).
./result/bin/testa-pnp-test

nix build -L .#packages.$system.testb.package
# via passthru rather than a hardcoded node_modules path, which packageDirectory
# makes wrong for any package that opts out of it
testbPackage=$(nix eval --raw .#packages.$system.testb.packageLocation)

nix build -L .#packages.$system.testb.shellRuntimeEnvironment
runShellEnvironmentTest=$(realpath ./result)

pushd $testbPackage
$runShellEnvironmentTest/bin/testa-test
popd

nix develop .#packages.$system.testb -c bash <<EOF
cd $testbPackage
testa-test
EOF

echo "All tests passed successfully"
