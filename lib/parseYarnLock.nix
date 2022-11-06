{ lib }:

with lib;

let
  structUtils = import ./structUtils.nix { inherit lib; };

  inherit (structUtils)
    notNull
    startsWith
    encodeUri
    parseQueryString
    stringifyIdent
    parseDescriptor
    stringifyDescriptor
    parseLocator
    stringifyLocator
    parseRange
    removeBindingFromRange
    removeBindingFromReference
    extractPatchSource
    isPatchSourceBuiltIn;

  # Yarn has a reduceDependency hook that can replace package descriptors with a new one.
  # When this happens, both the original package and the augmented package are stored in the lock file.
  # The findRelatedPackages function here is used to find the augmented packages from the original.
  #
  # In Yarn, the reduceDependency hook is pluggable so it's possible that the implementation here will
  # need to differ on a per-project basis (this is the downside of implementing this logic in Nix instead
  # of using codegen), but in reality most people will just be using Yarn out of the box which uses
  # plugin-compat, so we can hopefully use this naive implementation.
  # (e.g https://github.com/yarnpkg/berry/blob/599df9dc2c00fb5c39113b24e99a611d2a532ab4/packages/plugin-compat/sources/index.ts#L34)
  findRelatedPackagesDefault = package: allPackages:
    pipe (mapAttrsToList (n: v: v) allPackages) [
      (filter (_package:
        _package.range.protocol == "patch:" &&
        _package.range.source == package.locatorString
      ))
      (map (_package: _package.locatorString))
    ];

  # transform conditions string into a lambda function that returns whether the package should be installed
  # on the given platform
  # e.g os=android & cpu=arm
  mkInstallCondition = conditions:
    let
      cond = parseQueryString conditions;
    in
    if conditions == null then null
    else (stdenv:
      let
        osMatches =
          if !(hasAttr "os" cond) then true
          else if cond.os == "linux" then stdenv.isLinux
          else if cond.os == "darwin" then stdenv.isDarwin
          else false;

        cpuMatches =
          if !(hasAttr "cpu" cond) then true
          else if cond.cpu == "ia32" then stdenv.isi686
          else if cond.cpu == "x64" then stdenv.isx86_64
          else if cond.cpu == "arm" then stdenv.isAarch32
          else if cond.cpu == "arm64" then stdenv.isAarch64
          else false;

        libcMatches =
          if !(hasAttr "libc" cond) then true
          else if cond.libc == "glibc" then true # only glibc is supported on Nix, other implementations like musl are not supported
          else false;
      in
      osMatches && cpuMatches && libcMatches
    );

  # get relative source from workspace root for given portal spec
  mkSourceForLocalPackage = range:
    let
      path = range.selector;
      parentLocator = range.bindings.locator;
      parentLocatorPath = (parseRange (parseLocator parentLocator).reference).selector;
    in
    parentLocatorPath + "/" + path;
in

{
  yarnLockJSON,
  yarnLockPath,
  findRelatedPackages ? findRelatedPackagesDefault,
  getManifestDataForPackage ? (locatorString: {}),
}:
let
  yarnLockRootDirectory =
    let
      parts = splitString "/" (toString yarnLockPath);
      dirParts = sublist 0 ((length parts) - 1) parts;
    in
    concatStringsSep "/" dirParts;

  byDescriptorList =
    mapAttrsToList (descriptorsString: package:
      package // {
        # yarn.lock file is keyed by package descriptors e.g
        # @babel/code-frame@npm:^7.0.0, @babel/code-frame@npm:^7.12.13, @babel/code-frame@npm:^7.18.6
        # so we should split them into an array
        descriptors = pipe descriptorsString [
          (splitString ", ")
          (map parseDescriptor)
          (filter notNull)
        ];
      }
    ) yarnLockJSON;

  byDescriptorAttrs =
    pipe byDescriptorList [
      (concatMap (package:
        map (descriptor':
        let
          descriptor = descriptor' // {
            range = removeBindingFromRange descriptor'.range;
          };
        in
        {
          name = stringifyDescriptor descriptor;
          value = filterAttrs (key: value: key != "descriptors") package;
        }) package.descriptors
      ))
      listToAttrs
    ];

  rewriteDependenciesToResolvedLocators = locatorString: dependencies:
    pipe dependencies [
      (mapAttrs (dependencyName: dependencyRangeOrLocatorString:
        let
          locatorBinding = "::locator=${encodeUri locatorString}";
          descriptorRaw = null;
        in
        byDescriptorAttrs."${dependencyName}@${dependencyRangeOrLocatorString}".resolution or
        byDescriptorAttrs."${dependencyName}@${dependencyRangeOrLocatorString}${locatorBinding}".resolution or
        dependencyRangeOrLocatorString
      ))
      (filterAttrs (key: value: value != null))
    ];

  packagesByLocatorWithoutRelatedPackages =
    mapAttrs' (descriptorString: package:
      let
        locatorString = package.resolution;
        locator = parseLocator locatorString;
        range = parseRange locator.reference;
        src =
          if range.protocol == "workspace:" then /. + (yarnLockRootDirectory + "/" + range.selector)
          else if range.protocol == "portal:" || range.protocol == "file:" then /. + (yarnLockRootDirectory + "/" + (mkSourceForLocalPackage range))
          else null;
        isSourceArchive = src != null && (last (splitString "." (builtins.toString src))) == "tgz";

        # read package.json if the package has a local source so we can determine devDependencies
        # (this is fine, as remote packages published to NPM have their devDependencies stripped already)
        packageJSON = if src != null && !isSourceArchive then builtins.fromJSON (builtins.readFile "${src}/package.json") else null;

        packageInManifest = getManifestDataForPackage locatorString;

        devDependenciesKeys = attrNames (packageJSON.devDependencies or {});

        _packageDependencies = (package.dependencies or {}) // (packageInManifest.dependencies or {});

        packageDependencies = filterAttrs (key: __: !(elem key devDependenciesKeys)) _packageDependencies;
        packageDevDependencies = filterAttrs (key: __: (elem key devDependenciesKeys)) _packageDependencies;

        packageByLocator = (filterAttrs (key: value: key != "resolution" && key != "checksum" && key != "conditions") package) // {
          inherit locator;
          inherit locatorString;
          outputHash = if range.protocol == "patch:" || range.protocol == "file:" then null else (package.checksum or (if src != null then null else (
            warn "Missing required outputHash for package \"${locatorString}\", add it to your packageOverrides to mkYarnPackagesFromLockFile" ""
          )));
          inherit range;
          inherit src;
          installCondition = mkInstallCondition (package.conditions or null);
          identString = stringifyIdent locator;
          dependencies = rewriteDependenciesToResolvedLocators locatorString (packageDependencies);
          devDependencies = rewriteDependenciesToResolvedLocators locatorString (packageDevDependencies);
          # Yarn uses 0.0.0-use.local as a hardcoded version in the lockfile for local dependencies,
          # we just replace it with 0.0.0 so it's a bit cleaner in nix store paths
          version = if package.version == "0.0.0-use.local" then "0.0.0" else package.version;
        } //
        (if range.protocol == "patch:" then {
          patch = {
            parentPackage = range.source;
            source =
              let
                source = extractPatchSource range.selector;
              in
              if isPatchSourceBuiltIn source then null
              else /. + (yarnLockRootDirectory + "/" + source);
          };
        } else {});
      in
      nameValuePair (locatorString) (packageByLocator)
    ) byDescriptorAttrs;

  packagesByLocator =
    mapAttrs (descriptorString: package:
      let
        relatedPackages = findRelatedPackages package packagesByLocatorWithoutRelatedPackages;
      in
      package // { inherit relatedPackages; }
    ) packagesByLocatorWithoutRelatedPackages;
in
{
  inherit packagesByLocator;
}
