#!/usr/bin/env bash

set -e

system="$(nix eval --impure --json --expr builtins.currentSystem | jq -r)"

pushd test

nix build -L .#packages.$system.testb
./result/bin/testb

nix build -L .#packages.$system.testb.package
testbPackage=$(realpath ./result)/node_modules/testb

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
