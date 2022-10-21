{ pkgs, lib }:

with lib;

let
  mkYarnPackage =
    {
      name,
      outputName ? name,
      src ? null,
      packageManifest,
      packageOverrides ? {},
      nodejsPackage ? pkgs.nodejs,
      buildScripts ? "",
    }:
    let
      shouldBeUnplugged = if builtins.hasAttr "shouldBeUnplugged" packageManifest then packageManifest.shouldBeUnplugged else false;
      locatorHash = packageManifest.locatorHash;
      reference = packageManifest.reference;
      bin = if builtins.hasAttr "bin" packageManifest && packageManifest.bin != null then packageManifest.bin else null;

      _outputHash = if builtins.hasAttr "outputHash" packageManifest && packageManifest.outputHash != null then packageManifest.outputHash else null;
      _platformOutputHash = if builtins.hasAttr "outputHashByPlatform" packageManifest && packageManifest.outputHashByPlatform != null then (
        if builtins.hasAttr pkgs.stdenv.system packageManifest.outputHashByPlatform then packageManifest.outputHashByPlatform."${pkgs.stdenv.system}" else null
      ) else null;
      outputHash = if _platformOutputHash != null then _platformOutputHash else _outputHash;

      willFetch = if src == null then true else false;
      willBuild = !willFetch;

      packageRegistry = buildPackageRegistry {
        inherit packageOverrides;
        topLevel = packageManifest;
      };

      packageDependencies = builtins.toJSON packageRegistry; # TODO what about dependencies vs devDependencies

      # unsafeDiscardStringContext is undocumented
      # https://github.com/NixOS/nix/blob/ac0fb38e8a5a25a84fa17704bd31b453211263eb/src/libexpr/primops/context.cc#L8
      # it basically lets us remove any "dependencies" of a string so we can use the store paths without causing them to be built,
      # which is helpful as we want to build a .pnp.cjs file with the store paths but we only want the paths to be realised
      # if necessary (e.g devDependencies if building ONLY)
      packageRegistryJSON = builtins.unsafeDiscardStringContext (builtins.toJSON (packageRegistry));

      nixPlugin = "${pkgs.callPackage ../yarnPlugin.nix {}}/plugin.js";

      setupYarnBinScript = ''
        export YARN_PLUGINS=${nixPlugin}
      '';

      createLockFileScript = ''
        packageRegistryData="$(echo ${builtins.toJSON packageRegistryJSON} | ${pkgs.jq}/bin/jq -rcM \
          --arg packageLocation "$packageLocation/" \
          --arg package ${builtins.toJSON (builtins.toString name)} \
          --arg reference ${builtins.toJSON (builtins.toString reference)} \
          '.[$package][$reference].packageLocation = $packageLocation')"

        yarn nix create-lockfile "$packageRegistryData"
      '';

      fetchDerivation = pkgs.stdenv.mkDerivation {
        name = outputName;
        phases =
          (if willFetch then [ "fetchPhase" ] else [ "packPhase" ]) ++
          (if shouldBeUnplugged then [ "unplugPhase" "buildPhase" ] else [ "movePhase" ]);

        outputHashMode = if outputHash != null then (if shouldBeUnplugged then "recursive" else "flat") else null;
        outputHashAlgo = if outputHash != null then "sha512" else null;
        outputHash = if outputHash != null then outputHash else null;

        buildInputs = with pkgs; [
          nodejsPackage
          yarnBerry
          unzip
        ];

        fetchPhase =
          if willFetch then ''
            # ${builtins.toJSON packageDependencies}
            tmpDir=$PWD
            ${setupYarnBinScript}

            packageLocation=$out/node_modules/${name}
            ${createLockFileScript}

            yarn nix fetch-by-locator ${locatorHash} $tmpDir
          '' else " ";

        packPhase =
          if !willFetch then ''
            # ${builtins.toJSON packageDependencies}
            tmpDir=$PWD
            ${setupYarnBinScript}

            packageLocation=$out/node_modules/${name}
            ${createLockFileScript}

            export YARNNIX_PACK_DIRECTORY="${src}"
            yarn pack -o $tmpDir/package.tgz
            yarn nix convert-to-zip ${locatorHash} $tmpDir/package.tgz $tmpDir/output.zip
          '' else " ";

        unplugPhase =
          # for debugging:
          # cp ${./pnptemp.cjs} $out/.pnp.cjs
          # sed -i "s!__PACKAGE_PATH_HERE__!$packageLocation/!" $out/.pnp.cjs
          if shouldBeUnplugged then ''
            mkdir -p $out
            unzip -qq -d $out $tmpDir/*.zip

            yarn nix generate-pnp-file $out "$packageRegistryData" "$packageLocation"
          '' else " ";

        movePhase =
          if !shouldBeUnplugged then ''
            # won't be unplugged, so move zip file to output
            mv $tmpDir/output.zip $out
          '' else " ";

        buildPhase =
          if shouldBeUnplugged then ''
            yarn nix run-build-scripts ${locatorHash} $out $packageLocation

            cd $packageLocation
            ${buildScripts}

            rm $out/.pnp.cjs

            ${concatStringsSep "\n" (mapAttrsToList (binKey: binScript: ''
            chmod +x $out/node_modules/${name}/${binScript}
            '') (if bin != null then bin else {}))}
          '' else " ";
      };

      # have a separate derivation that includes the .pnp.cjs and wrapped bins
      # as Nix is unable to shasum the derivation $out if it contains files that contain /nix/store paths
      # to other derivations that are fixed output derivations.
      # works around:
      # https://github.com/NixOS/nix/issues/6660
      # https://github.com/NixOS/nix/issues/7148 (maybe)
      # without this workaround we get error: unexpected end-of-file errors
      finalDerivation = if shouldBeUnplugged == null || shouldBeUnplugged == false then fetchDerivation else pkgs.stdenv.mkDerivation {
        name = outputName;
        phases =
          (if shouldBeUnplugged then [ "unplugPhase" ] else []) ++
          (if shouldBeUnplugged && bin != null then [ "wrapBinPhase" ] else []);

        buildInputs = with pkgs; [
          nodejsPackage
          yarnBerry
        ];

        unplugPhase = ''
          tmpDir=$PWD
          ${setupYarnBinScript}

          packageLocation=${fetchDerivation}/node_modules/${name}
          ${createLockFileScript}

          mkdir -p $out
          yarn nix generate-pnp-file $out "$packageRegistryData" "$packageLocation"
        '';

        wrapBinPhase =
          if shouldBeUnplugged && bin != null then ''
            mkdir -p $out/bin

            ${concatStringsSep "\n" (mapAttrsToList (binKey: binScript: ''
            cat << EOF > $out/bin/${binKey}
            #!${pkgs.bashInteractive}/bin/bash

            export PATH="${nodejsPackage}/bin:\''$PATH"

            nodeOptions="--require $out/.pnp.cjs"
            export NODE_OPTIONS="\''$NODE_OPTIONS \''$nodeOptions"

            ${fetchDerivation}/node_modules/${name}/${binScript}
            EOF
            chmod +x $out/bin/${binKey} # $out/node_modules/${name}/${binScript}
            '') bin)}
          '' else " ";
      };
    in
    finalDerivation // {
      package = fetchDerivation;
      # for debugging with nix eval
      inherit packageRegistryJSON;
    };

  mkYarnPackageFromManifest =
    {
      packageManifest,
      packageOverrides ? {},
      buildScripts ? "",
    }:
    let
      nameAndRef = "${packageManifest.name}@${packageManifest.reference}";
      mergedManifest =
        packageManifest //
        (if hasAttr nameAndRef packageOverrides then packageOverrides."${nameAndRef}" else {});
    in
    mkYarnPackage {
      inherit packageOverrides;
      inherit buildScripts;
      inherit (mergedManifest) name outputName;
      packageManifest = mergedManifest;

      src = if hasAttr "src" mergedManifest then mergedManifest.src else null;
    };

  buildPackageRegistry =
    {
      topLevel,
      packageOverrides,
    }:
    let
      getPackageDataForPackage = pkg:
        if hasAttr "installCondition" pkg && pkg.installCondition != null && (pkg.installCondition pkgs.stdenv) == false then null
        else
        {
          inherit (pkg) name reference linkType;
          manifest = filterAttrs (key: b: !(builtins.elem key [
            "src" "installCondition" "dependencies"
          ])) pkg;
          packageLocation = if pkg != topLevel then (mkYarnPackageFromManifest {
            packageManifest = pkg;
            inherit packageOverrides;
          }).package + "/node_modules/${pkg.name}/" else "/dev/null"; # if package is toplevel package then the location is determined in the buildPhase as it will be $out
          packageDependencies = if (hasAttr "dependencies" pkg && pkg.dependencies != null) then mapAttrs (name: pkg:
            [ pkg.name pkg.reference ]
          ) pkg.dependencies else [];
        };
      getRecursivePackages = curr: flatten (
        [curr] ++
        (if hasAttr "dependencies" curr && curr.dependencies != null then (mapAttrsToList (__: package: package) curr.dependencies) else []) ++
        (if hasAttr "dependencies" curr && curr.dependencies != null then (mapAttrsToList (__: package: getRecursivePackages package) curr.dependencies) else []) ++
        (if hasAttr "otherVisibleDependencies" curr && curr.otherVisibleDependencies != null then (mapAttrsToList (__: package: getRecursivePackages package) curr.otherVisibleDependencies) else [])
      );
      flattenedPackages = getRecursivePackages topLevel;
      packageDatasList =
        filter (pkg: pkg != null) (map getPackageDataForPackage flattenedPackages);
      uniquePackageNames = unique (map (manifest: manifest.name) packageDatasList);
      packageRegistryData = listToAttrs (
        map (packageName: {
          name = packageName;
          value =
            let
              packageDependencyMatches = filter (manifest: manifest.name == packageName) packageDatasList;
            in
            listToAttrs (
              map (manifest: {
                name = manifest.reference;
                value = manifest;
              }) packageDependencyMatches
            );
        }) uniquePackageNames
      );
    in
    packageRegistryData;
in
{
  inherit mkYarnPackage;
  inherit mkYarnPackageFromManifest;
}
