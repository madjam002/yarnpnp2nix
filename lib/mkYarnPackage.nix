{ defaultPkgs, lib }:

with lib;

let
  structUtils = import ./structUtils.nix { inherit lib; };
  parseYarnLock = import ./parseYarnLock.nix { inherit lib; };
  fromYAML = import ./fromYAML.nix { inherit lib; };

  inherit (structUtils)
    encodeUri
    stringifyIdent
    stringifyIdentForNixStore
    parseDescriptor
    stringifyDescriptor
    parseLocator
    stringifyLocator
    removeBindingFromReference;

  nixPlugin = "${defaultPkgs.callPackage ../yarnPlugin.nix {}}/plugin.js";

  setupYarnBinScript = ''
    export YARN_PLUGINS=${nixPlugin}
  '';

  mkYarnPackagesFromLockFile =
    {
      pkgs ? defaultPkgs,
      yarnLock,
      yarnManifest ? {},
      packageOverrides ? {},
    }:
    let
      yarnLockJSON = (fromYAML.parse (builtins.readFile yarnLock));
      lockFile = parseYarnLock {
        inherit yarnLockJSON;
        yarnLockPath = yarnLock;
        getManifestDataForPackage = locatorString: yarnManifest."${locatorString}" or null;
      };
      mergedPackagesByLocator = applyPackageOverrides { packagesByLocator = lockFile.packagesByLocator; inherit yarnManifest; inherit packageOverrides; };
      mergedLockFile = lockFile // {
        packagesByLocator = mergedPackagesByLocator;
      };
      builtPackages = mapAttrs (key: value:
        mkYarnPackageFromLocator_internal {
          locatorString = key;
          inherit pkgs;
          lockFile = mergedLockFile;
          inherit builtPackages;
        }
      ) lockFile.packagesByLocator;
    in
    builtPackages;

  applyPackageOverrides =
    {
      packagesByLocator,
      yarnManifest,
      packageOverrides,
    }:
    let
      merged = mapAttrs (locatorString: package:
        let
          mergedPackage = if hasAttr locatorString yarnManifest
            then recursiveUpdate package yarnManifest."${locatorString}"
            else package;
          mergedPackage' = if hasAttr locatorString packageOverrides
            then recursiveUpdate mergedPackage packageOverrides."${locatorString}"
            else mergedPackage;
        in
        mergedPackage'
      ) packagesByLocator;
    in
    merged;

  mkCreateLockFileScript_internal =
    {
      packageRegistry,
      locatorString,
    }:
    let
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
        cat ${packageRegistryFile} | ${defaultPkgs.jq}/bin/jq -rcM \
          --arg packageLocation "$packageLocation" \
          --arg locatorString ${builtins.toJSON locatorString} \
          '.[$locatorString].packageLocation = $packageLocation' > $tmpDir/packageRegistryData.json

        node --enable-source-maps ${../internal/dist/index.js} createLockFile $tmpDir/packageRegistryData.json "${locatorString}"
      '' packageRegistryContext;
    in
    createLockFileScript;

  mkYarnPackage_internal =
    {
      pkgs,
      package,
      locatorString,
      lockFile,
      name,
      src ? null,
      builtPackages,
      nodejsPackage,
      build ? "",
      buildInputs ? [],
      preInstallScript ? "",
      postInstallScript ? "",
      shouldBeUnplugged ? false,
      __noChroot ? null,
    }:
    let
      locator = package.locator;
      identString = stringifyIdent package.locator;
      bin = package.bin or null;

      _outputHash = if builtins.hasAttr "outputHash" package && package.outputHash != null then package.outputHash else null;
      _platformOutputHash = if builtins.hasAttr "outputHashByPlatform" package && package.outputHashByPlatform != null then (
        if builtins.hasAttr pkgs.stdenv.system package.outputHashByPlatform then package.outputHashByPlatform."${pkgs.stdenv.system}" else ""
      ) else null;
      outputHash = if _platformOutputHash != null then _platformOutputHash else _outputHash;

      isSourceTgz = src != null && (last (splitString "." src)) == "tgz";
      isSourcePatch = (package.patch or null) != null;

      willFetch = src == null || isSourceTgz;
      willOutputBeZip = src == null && shouldBeUnplugged == false;

      locatorJSON = builtins.toJSON (builtins.toJSON {
        inherit (locator) name scope reference;
      });

      locatorToFetchJSON = builtins.toJSON (builtins.toJSON {
        inherit (locator) name scope;
        reference =
          if !isSourcePatch then locator.reference
          # <protocol>:<source>#<selector>
          else (
            let
              # use source from previously fetched package rather than fetching again in the patch: package,
              # that way we can avoid having a fixed output derivation here (unless this is an unplugged package anyway)
              parentPackage = (builtPackages."${package.patch.parentPackage}".unzippedPackage) + "/node_modules/${identString}";
              parentPackageSource = encodeUri "${identString}@file:${parentPackage}::locator=${package.range.source}";
              bindings = if package.range.bindingsRaw != null then "::${package.range.bindingsRaw}" else "";
            in
            if package.patch.source == null
            then "patch:${parentPackageSource}#${package.range.selector}${bindings}"
            else "patch:${parentPackageSource}#${package.patch.source}${bindings}"
          );
      });

      packageRegistry = buildPackageRegistry_internal {
        inherit pkgs;
        topLevelPackage = package;
        topLevelPackageLocatorString = locatorString;
        inherit builtPackages;
        inherit lockFile;
      };

      createLockFileScript = mkCreateLockFileScript_internal {
        inherit packageRegistry;
        inherit locatorString;
      };

      packageRegistryRuntimeOnly = buildPackageRegistry_internal {
        inherit pkgs;
        topLevelPackage = package;
        topLevelPackageLocatorString = locatorString;
        inherit builtPackages;
        inherit lockFile;
        excludeDevDependencies = true;
      };

      createLockFileScriptForRuntime = mkCreateLockFileScript_internal {
        packageRegistry = packageRegistryRuntimeOnly;
        inherit locatorString;
      };

      fetchDerivation = pkgs.stdenv.mkDerivation {
        name = name + (if willOutputBeZip then ".zip" else "");
        phases =
          (if willFetch then [ "fetchPhase" ] else [ "buildPhase" "packPhase" ]) ++
          (if !willOutputBeZip then [ "unplugPhase" ] else [ "movePhase" ]);

        inherit __noChroot;
        outputHashMode = if __noChroot != true && outputHash != null then (if !willOutputBeZip then "recursive" else "flat") else null;
        outputHashAlgo = if __noChroot != true && outputHash != null then "sha512" else null;
        outputHash = if __noChroot != true && outputHash != null then outputHash else null;

        buildInputs = with pkgs; [
          nodejsPackage
          defaultPkgs.yarnBerry
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

            packageLocation=$out/node_modules/${identString}
            touch yarn.lock

            ${if src == null || isSourcePatch then "yarn nix fetch-by-locator ${locatorToFetchJSON} $tmpDir"
            else if isSourceTgz then "yarn nix convert-to-zip ${locatorToFetchJSON} ${src} $tmpDir/output.zip"
            else ""}
          '' else " ";

        buildPhase =
          if !willFetch then ''
            tmpDir=$PWD
            ${setupYarnBinScript}

            packageLocation="$out/node_modules/${identString}"
            packageDrvLocation="$out"
            mkdir -p $packageLocation
            ${createLockFileScript}
            yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"

            ${if build != "" then ''
            cp -rT ${src} $packageLocation
            chmod -R +w $packageLocation

            mkdir -p $tmpDir/wrappedbins
            node --enable-source-maps ${../internal/dist/index.js} makePathWrappers $tmpDir/wrappedbins $out

            cd $packageLocation
            nodeOptions="--require $out/.pnp.cjs"
            oldNodeOptions="$NODE_OPTIONS"
            oldPath="$PATH"
            export NODE_OPTIONS="$NODE_OPTIONS $nodeOptions"
            export PATH="$PATH:$tmpDir/wrappedbins"

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

            packageLocation="$out/node_modules/${identString}"
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
          if !willOutputBeZip then ''
            mkdir -p $out
            unzip -qq -d $out $tmpDir/output.zip

            packageLocation="$out/node_modules/${identString}"
            packageDrvLocation="$out"
            ${if build == "" then createLockFileScript else ""}

            yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"

            # create dummy home directory in case any build scripts need it
            export HOME=$tmpDir/home
            mkdir -p $HOME

            ${preInstallScript}
            yarn nix run-build-scripts "${locatorString}" $out $packageLocation

            cd $packageLocation
            ${postInstallScript}

            # create a .ready file so the output matches what yarn unplugs itself
            # (useful if we want to be able to generate hash for unplugged output automatically)
            chmod +w .
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
            chmod +x $out/node_modules/${identString}/${binScript}
            '') (if bin != null then bin else {}))}
          '' else " ";

        movePhase =
          if willOutputBeZip then ''
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
        name = name;
        phases =
          [ "generateRuntimePhase" ] ++
          (if bin != null then [ "wrapBinPhase" ] else []);

        buildInputs = with pkgs; [
          nodejsPackage
          defaultPkgs.yarnBerry
        ];

        generateRuntimePhase = ''
          tmpDir=$PWD
          ${setupYarnBinScript}

          packageLocation=${fetchDerivation}/node_modules/${identString}
          packageDrvLocation=${fetchDerivation}
          ${createLockFileScriptForRuntime}

          mkdir -p $out
          yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"
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

            ${if !willOutputBeZip then ''${fetchDerivation}/node_modules/${identString}/${binScript} "\$@"''
            else ''node ${fetchDerivation}/node_modules/${identString}/${binScript} "\$@"''}
            EOF
            chmod +x $out/bin/${binKey}
            '') bin)}
          '' else " ";

        shellHook = ''
          tmpDir=$TMPDIR
          ${setupYarnBinScript}

          packageLocation="/"
          packageDrvLocation="/"
          (cd $tmpDir && ${createLockFileScript})
          (cd $tmpDir && yarn nix generate-pnp-file $tmpDir $tmpDir/packageRegistryData.json "${locatorString}")

          nodeOptions="--require $TMPDIR/.pnp.cjs"
          export NODE_OPTIONS="$NODE_OPTIONS $nodeOptions"

          mkdir -p $tmpDir/wrappedbins
          node --enable-source-maps ${../internal/dist/index.js} makePathWrappers $tmpDir/wrappedbins $tmpDir
          export PATH="$PATH:$tmpDir/wrappedbins"
        '';
      };

      dependencyBins = listToAttrs (concatMap (depLocatorString:
        let
          pkg = lockFile.packagesByLocator."${depLocatorString}";
        in
        mapAttrsToList (binKey: binScript: { name = binKey; value = { inherit pkg; inherit binScript; }; }) (pkg.bin or {})
      ) (mapAttrsToList (__: dep: dep) package.dependencies));

      shellRuntimeEnvironment = pkgs.stdenv.mkDerivation {
        name = name + "-shell-environment";
        phases = [ "generateRuntimePhase" ];

        buildInputs = with pkgs; [
          nodejsPackage
          defaultPkgs.yarnBerry
        ];

        generateRuntimePhase = ''
          tmpDir=$TMPDIR
          ${setupYarnBinScript}

          packageLocation="/"
          packageDrvLocation="/"
          ${createLockFileScriptForRuntime}

          mkdir -p $out/bin
          cp $tmpDir/yarn.lock $out
          cp $tmpDir/packageRegistryData.json $out

          ${concatStringsSep "\n" (mapAttrsToList (binKey: { pkg, binScript }: ''
          cat << EOF > $out/bin/${binKey}
          #!${pkgs.bashInteractive}/bin/bash

          pnpDir="\$(mktemp -d)"
          (cd $out && YARN_PLUGINS=${nixPlugin} ${defaultPkgs.yarnBerry}/bin/yarn nix generate-pnp-file \$pnpDir $out/packageRegistryData.json "${locatorString}")
          binPackageLocation="\$(${nodejsPackage}/bin/node -r \$pnpDir/.pnp.cjs -e 'console.log(require("pnpapi").getPackageInformation({ name: process.argv[1], reference: process.argv[2] })?.packageLocation)' "${pkg.identString}" "${pkg.locator.reference}")"

          export PATH="${nodejsPackage}/bin:\''$PATH"

          nodeOptions="--require \$pnpDir/.pnp.cjs"
          export NODE_OPTIONS="\''$NODE_OPTIONS \''$nodeOptions"

          ${nodejsPackage}/bin/node \$binPackageLocation./${binScript} "\$@"
          EOF
          chmod +x $out/bin/${binKey}
          '') dependencyBins)}
        '';
      };

      unzippedDerivation = pkgs.stdenv.mkDerivation {
        name = name;
        phases = [ "unzipPhase" ];

        buildInputs = with pkgs; [
          unzip
        ];

        unzipPhase = ''
          mkdir -p $out
          unzip -qq -d $out ${fetchDerivation}
        '';
      };
    in
    finalDerivation // {
      package = fetchDerivation;
      unzippedPackage = if willOutputBeZip then unzippedDerivation else fetchDerivation;
      transitiveRuntimePackages = filter (pkg: pkg != null) (mapAttrsToList (pkgLocatorString: pkg: if pkg != null then builtPackages."${pkgLocatorString}" else null) packageRegistryRuntimeOnly);
      inherit shellRuntimeEnvironment;
      # for debugging with nix eval
      inherit packageRegistry;
    };

  mkYarnPackageFromLocator_internal =
    {
      locatorString,
      pkgs,
      lockFile,
      builtPackages,
    }:
    let
      package = lockFile.packagesByLocator."${locatorString}";
    in
    mkYarnPackageFromPackage_internal {
      inherit package;
      inherit locatorString;
      inherit pkgs;
      inherit lockFile;
      inherit builtPackages;
    };

  mkYarnPackageFromPackage_internal =
    {
      package,
      locatorString,
      pkgs,
      lockFile,
      builtPackages,
    }:
    let
      name = "${stringifyIdentForNixStore package.locator}-${package.version}";
    in
    (makeOverridable mkYarnPackage_internal {
      inherit pkgs;
      nodejsPackage = if hasAttr "nodejsPackage" package then package.nodejsPackage else pkgs.nodejs;
      inherit package;
      inherit locatorString;
      inherit lockFile;
      inherit name;
      inherit builtPackages;
      src = if hasAttr "src" package then package.src else null;
      build = if hasAttr "build" package then package.build else "";
      buildInputs = if hasAttr "buildInputs" package then package.buildInputs else [];
      preInstallScript = if hasAttr "preInstallScript" package then package.preInstallScript else "";
      postInstallScript = if hasAttr "postInstallScript" package then package.postInstallScript else "";
      shouldBeUnplugged = if hasAttr "shouldBeUnplugged" package then package.shouldBeUnplugged else false;
      __noChroot = if hasAttr "__noChroot" package then package.__noChroot else null;
    });

  buildPackageRegistry_internal =
    {
      pkgs,
      topLevelPackage,
      topLevelPackageLocatorString,
      builtPackages,
      lockFile,
      excludeDevDependencies ? false,
    }:
    let
      getDataForPackageRegistry = locatorString: package:
        let
          shouldInstall = !(hasAttr "installCondition" package && package.installCondition != null && (package.installCondition pkgs.stdenv) == false);
          filterDependencies = if excludeDevDependencies then (package.filterDependencies or (name: true)) else (name: true);
          outDrv = builtPackages."${locatorString}";
        in
        if !shouldInstall then null
        else {
          packageOut = if locatorString == topLevelPackageLocatorString then "/dev/null" else outDrv.package;
          packageDependencies =
            (if ((package.dependencies or null) != null) then mapAttrs (name: depLocatorString:
              depLocatorString
            ) (filterAttrs (name: v: filterDependencies name) package.dependencies) else {}) //
            (if (!excludeDevDependencies && (package.devDependencies or null) != null) then mapAttrs (name: depLocatorString:
              depLocatorString
            ) (filterAttrs (name: v: filterDependencies name) package.devDependencies) else {});
        } // filterAttrs (key: b: (builtins.elem key [
          "bin" "languageName" "linkType" "checksum" "identString" "dependenciesMeta" "peerDependencies" "peerDependenciesMeta"
        ])) package;

      # thanks to https://github.com/NixOS/nix/issues/552#issuecomment-971212372
      # for documentation and a good example on how builtins.genericClosure works
      allTransitiveAndRelatedDependencies = builtins.genericClosure {
        startSet = [ { key = topLevelPackageLocatorString; package = topLevelPackage; } ];
        operator = { key, package }:
          let
            filterDependencies = if excludeDevDependencies then (package.filterDependencies or (name: true)) else (name: true);
            relatedPackages =
              package.relatedPackages ++
              (if package.patch.parentPackage or null != null then [ package.patch.parentPackage ] else []);
          in
          (if (package.dependencies or null) != null then (
            map
              (depName:
                let
                  depLocatorString = package.dependencies.${depName};
                  depPackage = lockFile.packagesByLocator."${depLocatorString}";
                in
                { key = depLocatorString; package = depPackage; }
              )
              (filter filterDependencies (attrNames package.dependencies))
          ) else []) ++
          (
            map
              (depLocatorString:
                let
                  depPackage = lockFile.packagesByLocator."${depLocatorString}";
                in
                { key = depLocatorString; package = depPackage; }
              )
              relatedPackages
          ) ++
          (if !excludeDevDependencies && (package.devDependencies or null) != null then (
            map
              (depName:
                let
                  depLocatorString = package.devDependencies.${depName};
                  depPackage = lockFile.packagesByLocator."${depLocatorString}";
                in
                { key = depLocatorString; package = depPackage; }
              )
              (filter filterDependencies (attrNames package.devDependencies))
          ) else []);
      };
      packageRegistryData = listToAttrs (
        map ({ key, package }:
        let
          registryData = getDataForPackageRegistry key package;
        in
        {
          name = key;
          value = registryData;
        }) allTransitiveAndRelatedDependencies
      );
    in
    packageRegistryData;
in
{
  inherit mkYarnPackagesFromLockFile;
}
