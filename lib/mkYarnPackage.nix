{ defaultPkgs, lib }:

with lib;

let
  nixPlugin = "${defaultPkgs.callPackage ../yarnPlugin.nix {}}/plugin.js";

  setupYarnBinScript = { yarnManifestSettings }: ''
    export YARN_PLUGINS=${nixPlugin}
    export YARN_COMPRESSION_LEVEL="${toString (yarnManifestSettings.compressionLevel or 0)}"
  '';

  resolvePkg = pkg: if hasAttr "canonicalPackage" pkg then (
    pkg.canonicalPackage //
    (if hasAttr "dependencies" pkg then { inherit (pkg) dependencies; } else {}) //
    (if hasAttr "devDependencies" pkg then { inherit (pkg) devDependencies; } else {})
   ) else pkg;

  mkYarnPackagesFromManifest =
    {
      pkgs ? defaultPkgs,
      yarnManifest,
      packageOverrides ? {},
    }:
    let
      yarnManifestSettings = yarnManifest.settings;
      mergedManifest = applyPackageOverrides { yarnManifest = yarnManifest.packages; inherit packageOverrides; };
      allPackageData = buildPackageDataFromYarnManifest { inherit pkgs; yarnManifest = mergedManifest; inherit yarnManifestSettings; };
    in
    mapAttrs (key: value:
      mkYarnPackageFromManifest_internal {
        package = key;
        inherit pkgs;
        yarnManifest = mergedManifest;
        inherit yarnManifestSettings;
        inherit allPackageData;
      }
    ) yarnManifest.packages;

  rewritePackageRef = pkg: allPackages:
    let
      ref = "${pkg.name}@${pkg.reference}";
    in
    allPackages.${ref};

  applyPackageOverrides =
    {
      yarnManifest,
      packageOverrides,
    }:
    let
      merged = mapAttrs (key: packageManifest:
        let
          mergedPackage = if hasAttr key packageOverrides
            then recursiveUpdate packageManifest packageOverrides."${key}"
            else packageManifest;
        in
        mergedPackage //
        (if hasAttr "canonicalPackage" mergedPackage then { canonicalPackage = rewritePackageRef mergedPackage.canonicalPackage merged; } else {}) //
        (if hasAttr "dependencies" mergedPackage then { dependencies = mapAttrs (__: pkg: rewritePackageRef pkg merged) mergedPackage.dependencies; } else {}) //
        (if hasAttr "devDependencies" mergedPackage then { devDependencies = mapAttrs (__: pkg: rewritePackageRef pkg merged) mergedPackage.devDependencies; } else {})
      ) yarnManifest;
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

        yarn nix create-lockfile $tmpDir/packageRegistryData.json
      '' packageRegistryContext;
    in
    createLockFileScript;

  mkYarnPackage_internal =
    {
      pkgs,
      name,
      outputName ? name,
      src ? null,
      packageManifest,
      yarnManifestSettings,
      allPackageData,
      nodejsPackage,
      build ? "",
      buildInputs ? [],
      preInstallScript ? "",
      postInstallScript ? "",
      binSetup ? "",
      __noChroot ? null,
    }:
    let
      shouldBeUnplugged = if builtins.hasAttr "shouldBeUnplugged" packageManifest then packageManifest.shouldBeUnplugged else false;
      locatorString = "${name}@${reference}";
      reference = packageManifest.reference;
      bin = if builtins.hasAttr "bin" packageManifest && packageManifest.bin != null then packageManifest.bin else null;

      _outputHash = if builtins.hasAttr "outputHash" packageManifest && packageManifest.outputHash != null then packageManifest.outputHash else null;
      _platformOutputHash = if builtins.hasAttr "outputHashByPlatform" packageManifest && packageManifest.outputHashByPlatform != null then (
        if builtins.hasAttr pkgs.stdenv.system packageManifest.outputHashByPlatform then packageManifest.outputHashByPlatform."${pkgs.stdenv.system}" else ""
      ) else null;
      outputHash = if _platformOutputHash != null then _platformOutputHash else _outputHash;

      isSourceTgz = src != null && (last (splitString "." src)) == "tgz";
      isSourcePatch = src != null && (substring 0 6 reference) == "patch:";

      willFetch = if src == null || isSourceTgz || isSourcePatch then true else false;
      willBuild = !willFetch;
      willOutputBeZip = src == null && shouldBeUnplugged == false;

      locatorJSON = builtins.toJSON (builtins.toJSON {
        name = packageManifest.flatName;
        scope = packageManifest.scope;
        reference = packageManifest.reference;
      });

      locatorToFetchJSON = builtins.toJSON (builtins.toJSON {
        name = packageManifest.flatName;
        scope = packageManifest.scope;
        reference = if isSourcePatch then (head (splitString "#" reference)) + "#${src}" else packageManifest.reference;
      });

      packageRegistry = buildPackageRegistry {
        inherit pkgs;
        topLevel = packageManifest;
        inherit allPackageData;
      };

      createLockFileScript = mkCreateLockFileScript_internal {
        inherit packageRegistry;
        inherit locatorString;
      };

      createShellRuntimeEnvironment =
        {
          name,
          createLockFileScript,
          dependencyBins,
        }:
        pkgs.stdenv.mkDerivation {
          inherit name;
          phases = [ "generateRuntimePhase" ];

          buildInputs = with pkgs; [
            nodejsPackage
            defaultPkgs.yarn-berry
          ];

          generateRuntimePhase = ''
            tmpDir=$TMPDIR
            ${setupYarnBinScript { inherit yarnManifestSettings; }}

            packageLocation="/"
            packageDrvLocation="/"
            ${createLockFileScript}

            mkdir -p $out/bin
            cp $tmpDir/yarn.lock $out
            cp $tmpDir/packageRegistryData.json $out

            ${concatStringsSep "\n" (mapAttrsToList (binKey: { pkg, binScript }: ''
            cat << EOF > $out/bin/${binKey}
            #!${pkgs.bashInteractive}/bin/bash

            pnpDir="\$(mktemp -d)"
            (cd $out && YARN_PLUGINS=${nixPlugin} ${defaultPkgs.yarn-berry}/bin/yarn nix generate-pnp-file \$pnpDir $out/packageRegistryData.json "${locatorString}")
            cp --no-preserve=mode "${./.pnp.loader.mjs}" \$pnpDir/.pnp.loader.mjs
            binPackageLocation="\$(${nodejsPackage}/bin/node -r \$pnpDir/.pnp.cjs -e 'console.log(require("pnpapi").getPackageInformation({ name: process.argv[1], reference: process.argv[2] })?.packageLocation)' "${pkg.name}" "${pkg.reference}")"

            export PATH="${nodejsPackage}/bin:\''$PATH"

            nodeOptions="--require \$pnpDir/.pnp.cjs --loader \$pnpDir/.pnp.loader.mjs"
            export NODE_OPTIONS="\''$NODE_OPTIONS \''$nodeOptions"

            exec ${nodejsPackage}/bin/node \$binPackageLocation./${binScript} "\$@"
            EOF
            chmod +x $out/bin/${binKey}
            '') dependencyBins)}
          '';
        };

      packageRegistryRuntimeOnly = buildPackageRegistry {
        inherit pkgs;
        topLevel = packageManifest;
        inherit allPackageData;
        excludeDevDependencies = true;
      };

      createLockFileScriptForRuntime = mkCreateLockFileScript_internal {
        packageRegistry = packageRegistryRuntimeOnly;
        inherit locatorString;
      };

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
          cacert
          nodejsPackage
          defaultPkgs.yarn-berry
          unzip
        ]
        ++ (if stdenv.isDarwin then [
          xcbuild
        ] else [])
        ++ buildInputs;

        fetchPhase =
          if willFetch then ''
            tmpDir=$PWD
            ${setupYarnBinScript { inherit yarnManifestSettings; }}

            packageLocation=$out/node_modules/${name}
            touch yarn.lock

            ${if src == null || isSourcePatch then "yarn nix fetch-by-locator ${locatorToFetchJSON} $tmpDir"
            else if isSourceTgz then "yarn nix convert-to-zip ${locatorToFetchJSON} ${src} $tmpDir/output.zip"
            else ""}
          '' else " ";

        buildPhase =
          if !willFetch then ''
            tmpDir=$PWD
            ${setupYarnBinScript { inherit yarnManifestSettings; }}

            packageLocation="$out/node_modules/${name}"
            packageDrvLocation="$out"
            mkdir -p $packageLocation
            ${createLockFileScript}
            yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"
            cp --no-preserve=mode "${./.pnp.loader.mjs}" $out/.pnp.loader.mjs

            ${if build != "" then ''
            cp -rT ${src} $packageLocation
            chmod -R +w $packageLocation

            mkdir -p $tmpDir/wrappedbins
            yarn nix make-path-wrappers $tmpDir/wrappedbins $out $tmpDir/packageRegistryData.json "${locatorString}"

            cd $packageLocation
            nodeOptions="--require $out/.pnp.cjs --loader $out/.pnp.loader.mjs"
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

            packageLocation="$out/node_modules/${name}"
            packageDrvLocation="$out"

            if [ -f "$tmpDir/packageRegistryData.json" ]; then
              export YARNNIX_PACKAGE_REGISTRY_DATA_PATH="$tmpDir/packageRegistryData.json"
            fi
            yarn nix pack -o $tmpDir/package.tgz
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

            yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"
            cp --no-preserve=mode "${./.pnp.loader.mjs}" $out/.pnp.loader.mjs

            # create dummy home directory in case any build scripts need it
            export HOME=$tmpDir/home
            mkdir -p $HOME

            ${preInstallScript}
            yarn nix run-build-scripts ${locatorJSON} $out $packageLocation

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
            rm $out/.pnp.loader.mjs || true

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
          defaultPkgs.yarn-berry
        ];

        generateRuntimePhase = ''
          tmpDir=$PWD
          ${setupYarnBinScript { inherit yarnManifestSettings; }}

          packageLocation=${fetchDerivation}/node_modules/${name}
          packageDrvLocation=${fetchDerivation}
          ${createLockFileScriptForRuntime}

          mkdir -p $out
          yarn nix generate-pnp-file $out $tmpDir/packageRegistryData.json "${locatorString}"
          cp --no-preserve=mode "${./.pnp.loader.mjs}" $out/.pnp.loader.mjs
        '';

        wrapBinPhase =
          if bin != null then ''
            mkdir -p $out/bin

            binSetup=$(cat <<'EOYP'
            ${binSetup}
            EOYP
            )

            ${concatStringsSep "\n" (mapAttrsToList (binKey: binScript: ''
            cat << EOYP > $out/bin/${binKey}
            #!${pkgs.bashInteractive}/bin/bash

            export PATH="${nodejsPackage}/bin:\''$PATH"

            nodeOptions="--require $out/.pnp.cjs --loader $out/.pnp.loader.mjs"
            export NODE_OPTIONS="\''$NODE_OPTIONS \''$nodeOptions"

            $binSetup

            ${if shouldBeUnplugged then ''exec ${fetchDerivation}/node_modules/${name}/${binScript} "\$@"''
            else ''exec node ${fetchDerivation}/node_modules/${name}/${binScript} "\$@"''}
            EOYP
            chmod +x $out/bin/${binKey}
            '') bin)}
          '' else " ";

        shellHook = ''
          tmpDir=$TMPDIR
          ${setupYarnBinScript { inherit yarnManifestSettings; }}

          packageLocation="/"
          packageDrvLocation="/"
          (cd $tmpDir && ${createLockFileScript})
          (cd $tmpDir && yarn nix generate-pnp-file $tmpDir $tmpDir/packageRegistryData.json "${locatorString}")

          nodeOptions="--require $TMPDIR/.pnp.cjs"
          export NODE_OPTIONS="$NODE_OPTIONS $nodeOptions"

          mkdir -p $tmpDir/wrappedbins
          yarn nix make-path-wrappers $tmpDir/wrappedbins $tmpDir $tmpDir/packageRegistryData.json "${locatorString}"
          export PATH="$PATH:$tmpDir/wrappedbins"
        '';
      };

      dependencyBins = listToAttrs (concatMap (pkg:
        let
          pkgRef = "${pkg.name}@${pkg.reference}";
          packageDrv = allPackageData."${pkgRef}".drv.package;
        in
        mapAttrsToList (binKey: binScript: { name = binKey; value = { inherit pkg; inherit binScript; }; }) ((resolvePkg pkg).bin or {})
      ) (mapAttrsToList (__: dep: dep) (packageManifest.dependencies or {})));

      devDependencyBins = listToAttrs (concatMap (pkg:
        let
          pkgRef = "${pkg.name}@${pkg.reference}";
          packageDrv = allPackageData."${pkgRef}".drv.package;
        in
        mapAttrsToList (binKey: binScript: { name = binKey; value = { inherit pkg; inherit binScript; }; }) ((resolvePkg pkg).bin or {})
      ) (mapAttrsToList (__: dep: dep) (packageManifest.devDependencies or {})));

      shellRuntimeEnvironment = createShellRuntimeEnvironment {
        name = outputName + "-shell-environment";
        createLockFileScript = createLockFileScriptForRuntime;
        dependencyBins = dependencyBins;
      };

      shellRuntimeDevEnvironment = createShellRuntimeEnvironment {
        name = outputName + "-shell-dev-environment";
        createLockFileScript = createLockFileScript;
        dependencyBins = devDependencyBins // dependencyBins;
      };
    in
    finalDerivation // {
      package = fetchDerivation;
      manifest = packageManifest;
      transitiveRuntimePackages = filter (pkg: pkg != null) (mapAttrsToList (key: pkg: if pkg != null && !isString pkg.drvPath then pkg.drvPath.binDrvPath else null) packageRegistryRuntimeOnly);
      inherit shellRuntimeEnvironment;
      inherit shellRuntimeDevEnvironment;
      # for debugging with nix eval
      inherit packageRegistry;
    };

  mkYarnPackageFromManifest_internal =
    {
      package,
      pkgs,
      yarnManifest,
      yarnManifestSettings,
      allPackageData,
    }:
    let
      packageManifest = yarnManifest."${package}";
    in
    mkYarnPackageFromPackageManifest_internal {
      inherit packageManifest;
      inherit pkgs;
      inherit yarnManifest;
      inherit yarnManifestSettings;
      inherit allPackageData;
    };

  mkYarnPackageFromPackageManifest_internal =
    {
      packageManifest,
      pkgs,
      yarnManifest,
      yarnManifestSettings,
      allPackageData,
    }:
    (makeOverridable mkYarnPackage_internal {
      inherit pkgs;
      nodejsPackage = if hasAttr "nodejsPackage" packageManifest then packageManifest.nodejsPackage else pkgs.nodejs;
      inherit (packageManifest) name outputName;
      inherit packageManifest;
      inherit allPackageData;
      inherit yarnManifestSettings;
      src = if hasAttr "src" packageManifest then packageManifest.src else null;
      build = if hasAttr "build" packageManifest then packageManifest.build else "";
      buildInputs = if hasAttr "buildInputs" packageManifest then packageManifest.buildInputs else [];
      preInstallScript = if hasAttr "preInstallScript" packageManifest then packageManifest.preInstallScript else "";
      postInstallScript = if hasAttr "postInstallScript" packageManifest then packageManifest.postInstallScript else "";
      binSetup = if hasAttr "binSetup" packageManifest then packageManifest.binSetup else "";
      __noChroot = if hasAttr "__noChroot" packageManifest then packageManifest.__noChroot else null;
    });

  buildPackageDataFromYarnManifest =
    {
      pkgs,
      yarnManifest,
      yarnManifestSettings,
    }:
    let
      getPackageDataForPackage = pkg:
        let
          resolvedPkg = resolvePkg pkg;
        in
        if hasAttr "installCondition" resolvedPkg && resolvedPkg.installCondition != null && (resolvedPkg.installCondition pkgs.stdenv) == false then null
        else
        let
          drv = mkYarnPackageFromPackageManifest_internal {
            inherit pkgs;
            inherit yarnManifest;
            inherit yarnManifestSettings;
            packageManifest = resolvedPkg;
            inherit allPackageData;
          };
          drvForVirtual = mkYarnPackageFromPackageManifest_internal {
            inherit pkgs;
            inherit yarnManifest;
            inherit yarnManifestSettings;
            packageManifest = resolvedPkg // {
              dependencies = pkg.dependencies or {};
              devDependencies = pkg.devDependencies or {};
            };
            inherit allPackageData;
          };
        in
        {
          inherit pkg;
          inherit (pkg) name reference;
          canonicalReference = resolvedPkg.reference;
          inherit (resolvedPkg) linkType;
          filterDependencies = resolvedPkg.filterDependencies or (name: true);
          manifest = filterAttrs (key: b: !(builtins.elem key [
            "src" "installCondition" "dependencies" "devDependencies" "filterDependencies" "name" "reference"
          ])) resolvedPkg;
          inherit drv;
          inherit drvForVirtual;
          packageDependencies =
            (if (hasAttr "dependencies" pkg && pkg.dependencies != null) then mapAttrs (name: depPkg:
              [ depPkg.name depPkg.reference ]
            ) pkg.dependencies else {}) //
            (if (hasAttr "devDependencies" pkg && pkg.devDependencies != null) then mapAttrs (name: depPkg:
              [ depPkg.name depPkg.reference ]
            ) pkg.devDependencies else {});
        };

      allPackageData =
        mapAttrs (__: pkg: getPackageDataForPackage pkg) yarnManifest;
    in
    allPackageData;

  buildPackageRegistry =
    {
      pkgs,
      topLevel,
      allPackageData,
      excludeDevDependencies ? false,
    }:
    let
      topLevelRef = "${topLevel.name}@${topLevel.reference}";
      getPackageDataForPackage = pkgRef:
        let
          data = allPackageData.${pkgRef};
          filterDependencies = if excludeDevDependencies then data.filterDependencies else (name: true);
        in
        if data == null then null
        else
        {
          inherit (data) name reference canonicalReference linkType manifest;
          drvPath = data.drv.package // { binDrvPath = data.drv; };
          packageDependencies = if !excludeDevDependencies then data.packageDependencies else (
            (if (hasAttr "dependencies" data.pkg && data.pkg.dependencies != null) then mapAttrs (name: depPkg:
              [ depPkg.name depPkg.reference ]
            ) (filterAttrs (name: v: filterDependencies name) data.pkg.dependencies) else {})
          );
        };
      topLevelPackageData =
        if hasAttr "installCondition" topLevel && topLevel.installCondition != null && (topLevel.installCondition pkgs.stdenv) == false then null
        else
        let
          filterDependencies = if excludeDevDependencies then (topLevel.filterDependencies or (name: true)) else (name: true);
        in
        {
          inherit (topLevel) name reference linkType;
          canonicalReference = topLevel.reference;
          manifest = filterAttrs (key: b: !(builtins.elem key [
            "src" "installCondition" "dependencies" "devDependencies" "filterDependencies"
          ])) topLevel;
          drvPath = "/dev/null"; # if package is toplevel package then the location is determined in the buildPhase as it will be $out
          packageDependencies =
            (if (hasAttr "dependencies" topLevel && topLevel.dependencies != null) then mapAttrs (name: depPkg:
              [ depPkg.name depPkg.reference ]
            ) (filterAttrs (name: v: filterDependencies name) topLevel.dependencies) else {}) //
            (if (!excludeDevDependencies && hasAttr "devDependencies" topLevel && topLevel.devDependencies != null) then mapAttrs (name: depPkg:
              [ depPkg.name depPkg.reference ]
            ) (filterAttrs (name: v: filterDependencies name) topLevel.devDependencies) else {});
        };
      # thanks to https://github.com/NixOS/nix/issues/552#issuecomment-971212372
      # for documentation and a good example on how builtins.genericClosure works
      allTransitiveDependencies = builtins.genericClosure {
        startSet = [ { key = topLevelRef; pkg = topLevel; } ];
        operator = { key, pkg }:
          let
            filterDependencies = if excludeDevDependencies then ((resolvePkg pkg).filterDependencies or (name: true)) else (name: true);
          in
          (if hasAttr "dependencies" pkg && pkg.dependencies != null then (
            map
              (depName:
                let
                  dep = pkg.dependencies.${depName};
                  depPkgRef = "${dep.name}@${dep.reference}";
                in
                { key = depPkgRef; pkg = dep; }
              )
              (filter filterDependencies (attrNames pkg.dependencies))
          ) else []) ++
          (if !excludeDevDependencies && hasAttr "devDependencies" pkg && pkg.devDependencies != null then (
            map
              (depName:
                let
                  dep = pkg.devDependencies.${depName};
                  depPkgRef = "${dep.name}@${dep.reference}";
                in
                { key = depPkgRef; pkg = dep; }
              )
              (filter filterDependencies (attrNames pkg.devDependencies))
          ) else []);
      };
      packageRegistryData = listToAttrs (
        map ({ key, pkg }:
        let
          package = if key == topLevelRef then topLevelPackageData else getPackageDataForPackage key;
        in
        {
          name = key;
          value = package;
        }) allTransitiveDependencies
      );
    in
    packageRegistryData;
in
{
  inherit mkYarnPackagesFromManifest;
}
