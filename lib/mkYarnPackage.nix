{ pkgs, lib }:

with lib;

let
  nixPlugin = "${pkgs.callPackage ../yarnPlugin.nix {}}/plugin.js";

  setupYarnBinScript = ''
    export YARN_PLUGINS=${nixPlugin}
  '';

  resolvePkg = pkg: if hasAttr "canonicalPackage" pkg then (
    pkg.canonicalPackage //
    (if hasAttr "dependencies" pkg then { inherit (pkg) dependencies; } else {})
   ) else pkg;

  mkYarnPackageFromManifest =
    {
      package,
      yarnManifest,
      packageOverrides ? {},
    }:
    mkYarnPackageFromManifest_internal {
      inherit package;
      inherit yarnManifest;
      inherit packageOverrides;
      allPackageData = buildPackageDataFromYarnManifest { inherit yarnManifest; inherit packageOverrides; };
    };

  mkYarnPackage_internal =
    {
      name,
      outputName ? name,
      src ? null,
      packageManifest,
      allPackageData,
      nodejsPackage ? pkgs.nodejs,
      build ? "",
      buildInputs ? [],
      postInstallScript ? "",
      __noChroot ? null,
    }:
    let
      shouldBeUnplugged = if builtins.hasAttr "shouldBeUnplugged" packageManifest then packageManifest.shouldBeUnplugged else false;
      locatorHash = packageManifest.locatorHash;
      ident = "${name}@${reference}";
      reference = packageManifest.reference;
      bin = if builtins.hasAttr "bin" packageManifest && packageManifest.bin != null then packageManifest.bin else null;

      _outputHash = if builtins.hasAttr "outputHash" packageManifest && packageManifest.outputHash != null then packageManifest.outputHash else null;
      _platformOutputHash = if builtins.hasAttr "outputHashByPlatform" packageManifest && packageManifest.outputHashByPlatform != null then (
        if builtins.hasAttr pkgs.stdenv.system packageManifest.outputHashByPlatform then packageManifest.outputHashByPlatform."${pkgs.stdenv.system}" else ""
      ) else null;
      outputHash = if _platformOutputHash != null then _platformOutputHash else _outputHash;

      willFetch = if src == null || (last (splitString "." src)) == "tgz" then true else false;
      willBuild = !willFetch;
      willOutputBeZip = src == null && shouldBeUnplugged == false;

      locatorJSON = builtins.toJSON (builtins.toJSON {
        name = packageManifest.flatName;
        scope = packageManifest.scope;
        reference = packageManifest.reference;
      });

      packageRegistry = buildPackageRegistry {
        topLevel = packageManifest;
        inherit allPackageData;
      };

      dependencyBinPaths = filter (d: d != null) (mapAttrsToList (dep: pkg:
        let
          pkgData = packageRegistry."${pkg.name}@${pkg.reference}";
        in
        if pkgData != null && pkgData.drvPath != "/dev/null" && hasAttr "bin" pkgData.manifest then pkgData.drvPath.binDrvPath + "/bin" else null
      ) (if hasAttr "dependencies" packageManifest then packageManifest.dependencies else {}));

      packageRegistryJSON = builtins.toJSON packageRegistry;

      # Bit of a HACK, builtins.toFile cannot contain a string with references to /nix/store paths,
      # so we extract the "context" (which is a reference to any /nix/store paths in the JSON), then remove
      # the context from the string and write the resulting string to disk using builtins.toFile.
      # We then manually append the context which contains the references to the /nix/store paths
      # to `createLockFileScript` so when the script is used, any npm dependency /nix/store paths
      # are built and realised.
      packageRegistryContext = builtins.getContext packageRegistryJSON;

      packageRegistryFile = builtins.toFile "yarn-package-registry.json" (
        # unsafeDiscardStringContext is undocumented
        # https://github.com/NixOS/nix/blob/ac0fb38e8a5a25a84fa17704bd31b453211263eb/src/libexpr/primops/context.cc#L8
        builtins.unsafeDiscardStringContext packageRegistryJSON
      );

      createLockFileScript = builtins.appendContext ''
        cat ${packageRegistryFile} | ${pkgs.jq}/bin/jq -rcM \
          --arg drvPath "$packageDrvLocation" \
          --arg ident ${builtins.toJSON ("${ident}")} \
          '.[$ident].drvPath = $drvPath' > $tmpDir/packageRegistryData.json

        yarn nix create-lockfile $tmpDir/packageRegistryData.json
      '' packageRegistryContext;

      fetchDerivation = pkgs.stdenv.mkDerivation {
        name = outputName + (if willOutputBeZip then ".zip" else "");
        phases =
          (if willFetch then [ "fetchPhase" ] else [ "buildPhase" "packPhase" ]) ++
          (if shouldBeUnplugged then [ "unplugPhase" ] else [ "movePhase" ]);

        inherit __noChroot;
        outputHashMode = if __noChroot != true && outputHash != null then (if shouldBeUnplugged then "recursive" else "flat") else null;
        outputHashAlgo = if __noChroot != true && outputHash != null then "sha512" else null;
        outputHash = if __noChroot != true && outputHash != null then outputHash else null;

        buildInputs = with pkgs; [
          nodejsPackage
          yarnBerry
          unzip
        ]
        ++ (if stdenv.isDarwin then [
          xcbuild
        ] else [])
        ++ buildInputs;

        fetchPhase =
          if willFetch then ''
            tmpDir=$PWD
            ${setupYarnBinScript}

            packageLocation=$out/node_modules/${name}
            touch yarn.lock

            ${if src == null then "yarn nix fetch-by-locator ${locatorJSON} $tmpDir" else
            "yarn nix convert-to-zip ${locatorJSON} ${src} $tmpDir/output.zip"}
          '' else " ";

        buildPhase =
          if !willFetch then ''
            tmpDir=$PWD
            ${setupYarnBinScript}

            ${if build != "" then ''
            packageLocation="$out/node_modules/${name}"
            packageDrvLocation="$out"
            mkdir -p $packageLocation
            ${createLockFileScript}
            yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "$packageLocation"

            cp -rT ${src} $packageLocation
            chmod -R +w $packageLocation

            cd $packageLocation
            nodeOptions="--require $out/.pnp.cjs"
            oldNodeOptions="$NODE_OPTIONS"
            oldPath="$PATH"
            export NODE_OPTIONS="$NODE_OPTIONS $nodeOptions"
            export PATH="$PATH:${concatStringsSep ":" dependencyBinPaths}"

            ${build}

            export NODE_OPTIONS="$oldNodeOptions"
            export PATH="$oldPath"
            cd $tmpDir
            '' else ""}

          '' else " ";

        packPhase =
          if !willFetch then ''
            touch yarn.lock

            ${if build != "" then ''
            export YARNNIX_PACK_DIRECTORY="$packageLocation"
            '' else ''
            export YARNNIX_PACK_DIRECTORY="${src}"
            ''}

            packageLocation="$out/node_modules/${name}"
            packageDrvLocation="$out"

            if [ -f "$tmpDir/packageRegistryData.json" ]; then
              export YARNNIX_PACKAGE_REGISTRY_DATA_PATH="$tmpDir/packageRegistryData.json"
            fi
            yarn pack -o $tmpDir/package.tgz
            yarn nix convert-to-zip ${locatorJSON} $tmpDir/package.tgz $tmpDir/output.zip

            ${if build != "" then "rm -rf $out" else ""}
          '' else " ";

        unplugPhase =
          # for debugging:
          # cp ${./pnptemp.cjs} $out/.pnp.cjs
          # sed -i "s!__PACKAGE_PATH_HERE__!$packageLocation/!" $out/.pnp.cjs
          if shouldBeUnplugged then ''
            mkdir -p $out
            unzip -qq -d $out $tmpDir/output.zip

            packageLocation="$out/node_modules/${name}"
            packageDrvLocation="$out"
            ${if build == "" then createLockFileScript else ""}

            yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "$packageLocation"

            # create dummy home directory in case any build scripts need it
            export HOME=$tmpDir/home
            mkdir -p $HOME

            yarn nix run-build-scripts ${locatorHash} $out $packageLocation

            cd $packageLocation
            ${postInstallScript}

            # create a .ready file so the output matches what yarn unplugs itself
            # (useful if we want to be able to generate hash for unplugged output automatically)
            touch .ready

            # if a node_modules folder was created INSIDE an unplugged package, it was probably used for caching
            # purposes, so we can just remove it. In the offchance that this breaks something, the user
            # can just specify an outputHash manually in packageOverrides
            rm -rf node_modules || true

            # remove .pnp.cjs here as it will break Nix (see bug below), it's okay because we recreate it later
            # in finalDerivation
            rm $out/.pnp.cjs

            # set executable bit with chmod for all bin scripts
            ${concatStringsSep "\n" (mapAttrsToList (binKey: binScript: ''
            chmod +x $out/node_modules/${name}/${binScript}
            '') (if bin != null then bin else {}))}
          '' else " ";

        movePhase =
          if !shouldBeUnplugged then ''
            # won't be unplugged, so move zip file to output
            mv $tmpDir/output.zip $out
          '' else " ";
      };

      # have a separate derivation that includes the .pnp.cjs and wrapped bins
      # as Nix is unable to shasum the derivation $out if it contains files that contain /nix/store paths
      # to other derivations that are fixed output derivations.
      # works around:
      # https://github.com/NixOS/nix/issues/6660
      # https://github.com/NixOS/nix/issues/7148 (maybe)
      # without this workaround we get error: unexpected end-of-file errors
      finalDerivation = pkgs.stdenv.mkDerivation {
        name = outputName;
        phases =
          [ "generateRuntimePhase" ] ++
          (if bin != null then [ "wrapBinPhase" ] else []);

        buildInputs = with pkgs; [
          nodejsPackage
          yarnBerry
        ];

        generateRuntimePhase = ''
          tmpDir=$PWD
          ${setupYarnBinScript}

          packageLocation=${fetchDerivation}/node_modules/${name}
          packageDrvLocation=${fetchDerivation}
          ${createLockFileScript}

          mkdir -p $out
          yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "$packageLocation"
        '';

        wrapBinPhase =
          if bin != null then ''
            mkdir -p $out/bin

            ${concatStringsSep "\n" (mapAttrsToList (binKey: binScript: ''
            cat << EOF > $out/bin/${binKey}
            #!${pkgs.bashInteractive}/bin/bash

            export PATH="${nodejsPackage}/bin:\''$PATH"

            nodeOptions="--require $out/.pnp.cjs"
            export NODE_OPTIONS="\''$NODE_OPTIONS \''$nodeOptions"

            ${if shouldBeUnplugged then ''${fetchDerivation}/node_modules/${name}/${binScript} "\$@"''
            else ''node ${fetchDerivation}/node_modules/${name}/${binScript} "\$@"''}
            EOF
            chmod +x $out/bin/${binKey}
            '') bin)}
          '' else " ";
      };
    in
    finalDerivation // {
      package = fetchDerivation;
      # for debugging with nix eval
      inherit packageRegistry;
      inherit packageRegistryJSON;
      inherit dependencyBinPaths;
    };

  mkYarnPackageFromManifest_internal =
    {
      package,
      yarnManifest,
      packageOverrides,
      allPackageData,
    }:
    let
      packageManifest = yarnManifest."${package}";
      nameAndRef = if hasAttr "canonicalPackage" packageManifest then
        throw "mkYarnPackageFromManifest cannot be called with virtual package"
      else "${packageManifest.name}@${packageManifest.reference}";
      mergedManifest =
        packageManifest //
        (if hasAttr nameAndRef packageOverrides then packageOverrides."${nameAndRef}" else {});
    in
    mkYarnPackage_internal {
      inherit (mergedManifest) name outputName;
      packageManifest = mergedManifest;
      inherit allPackageData;
      src = if hasAttr "src" mergedManifest then mergedManifest.src else null;
      build = if hasAttr "build" mergedManifest then mergedManifest.build else "";
      buildInputs = if hasAttr "buildInputs" mergedManifest then mergedManifest.buildInputs else [];
      postInstallScript = if hasAttr "postInstallScript" mergedManifest then mergedManifest.postInstallScript else "";
      __noChroot = if hasAttr "__noChroot" mergedManifest then mergedManifest.__noChroot else null;
    };

  buildPackageDataFromYarnManifest =
    {
      yarnManifest,
      packageOverrides,
    }:
    let
      getPackageDataForPackage = pkg:
        let
          resolvedPkg = resolvePkg pkg;
        in
        if hasAttr "installCondition" resolvedPkg && resolvedPkg.installCondition != null && (resolvedPkg.installCondition pkgs.stdenv) == false then null
        else
        {
          inherit (pkg) name reference;
          inherit (resolvedPkg) linkType;
          manifest = filterAttrs (key: b: !(builtins.elem key [
            "src" "installCondition" "dependencies"
          ])) resolvedPkg;
          drvPath =
            let
              drv = (mkYarnPackageFromManifest_internal {
                inherit yarnManifest;
                package = "${resolvedPkg.name}@${resolvedPkg.reference}";
                inherit packageOverrides;
                inherit allPackageData;
              });
            in
            drv.package // { binDrvPath = drv; };
          packageDependencies = if (hasAttr "dependencies" pkg && pkg.dependencies != null) then mapAttrs (name: depPkg:
            [ depPkg.name depPkg.reference ]
          ) pkg.dependencies else [];
        };

      allPackageData =
        mapAttrs (__: pkg: getPackageDataForPackage pkg) yarnManifest;
    in
    allPackageData;

  buildPackageRegistry =
    {
      topLevel,
      allPackageData,
    }:
    let
      getPackageDataForPackage = pkg:
        if pkg != topLevel then (
          allPackageData."${pkg.name}@${pkg.reference}"
        ) else (
          if hasAttr "installCondition" pkg && pkg.installCondition != null && (pkg.installCondition pkgs.stdenv) == false then null
          else
          {
            inherit (pkg) name reference linkType;
            manifest = filterAttrs (key: b: !(builtins.elem key [
              "src" "installCondition" "dependencies"
            ])) pkg;
            drvPath = "/dev/null"; # if package is toplevel package then the location is determined in the buildPhase as it will be $out
            packageDependencies = if (hasAttr "dependencies" pkg && pkg.dependencies != null) then mapAttrs (name: depPkg:
              [ depPkg.name depPkg.reference ]
            ) pkg.dependencies else [];
          }
        );
      getRecursivePackages = curr: dependencyStack:
        let
          nextDependencyStack = dependencyStack ++ [ "${curr.name}@${curr.reference}" ];
          isInCircularDependency = (length nextDependencyStack) > (length (unique nextDependencyStack));
        in
        flatten (
          [curr] ++
          (if hasAttr "dependencies" curr && curr.dependencies != null then (mapAttrsToList (__: package: package) curr.dependencies) else []) ++
          (if !isInCircularDependency && hasAttr "dependencies" curr && curr.dependencies != null then (mapAttrsToList (__: package: getRecursivePackages package nextDependencyStack) curr.dependencies) else [])
        );
      flattenedPackages = getRecursivePackages topLevel [];
      packageRegistryData = listToAttrs (
        map (pkg: {
          name = "${pkg.name}@${pkg.reference}";
          value = getPackageDataForPackage pkg;
        }) flattenedPackages
      );
    in
    packageRegistryData;
in
{
  inherit mkYarnPackage;
  inherit mkYarnPackageFromManifest;
}
