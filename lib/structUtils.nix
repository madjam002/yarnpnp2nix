{ lib }:

with lib;

rec {
  notNull = v: v != null;

  trim = string: pipe string [
    (removePrefix " ")
    (removeSuffix " ")
  ];

  startsWith = sub: string: (substring 0 (stringLength sub) string) == sub;

  decodeUri = string:
    replaceStrings
      [ "%21" "%23" "%24" "%26" "%27" "%28" "%29" "%2A" "%2B" "%2C" "%2F" "%3A" "%3B" "%3D" "%3F" "%40" "%5B" "%5D" "%20" "%25" "%2E" "%3C" "%3E" "%5C" "%5E" "%5F" "%60" "%7B" "%7C" "%7D" "%7E" ]
      [ "!"  "#" "$" "&" "'" "(" ")" "*" "+" "," "/" ":" ";" "=" "?" "@" "[" "]" " " "%" "." "<" ">" "\\" "^" "_" "`" "{" "|" "}" "~" ]
      string;

  encodeUri = string:
    replaceStrings
      [ "!"  "#" "$" "&" "'" "(" ")" "*" "+" "," "/" ":" ";" "=" "?" "@" "[" "]" " " "%" "." "<" ">" "\\" "^" "_" "`" "{" "|" "}" "~" ]
      [ "%21" "%23" "%24" "%26" "%27" "%28" "%29" "%2A" "%2B" "%2C" "%2F" "%3A" "%3B" "%3D" "%3F" "%40" "%5B" "%5D" "%20" "%25" "%2E" "%3C" "%3E" "%5C" "%5E" "%5F" "%60" "%7B" "%7C" "%7D" "%7E" ]
      string;

  parseQueryString = string:
    let
      parts = splitString "&" string;
    in
    pipe parts [
      (map (part:
        let
          split = splitString "=" part;
          name = trim (decodeUri (elemAt split 0));
          value = trim (decodeUri (elemAt split 1));
        in { inherit name; inherit value; }
      ))
      listToAttrs
    ];

  # https://github.com/yarnpkg/berry/blob/599df9dc2c00fb5c39113b24e99a611d2a532ab4/packages/yarnpkg-core/sources/structUtils.ts#L618
  # stringifyIdent(ident: { scope = string | null; name = string | null; }) -> "@scope/name" | "name"
  stringifyIdent = ident:
    if ident.scope != null then "@${ident.scope}/${ident.name}"
    else "${ident.name}";

  # adapted for /nix/store
  stringifyIdentForNixStore = ident:
    let
      original = stringifyIdent ident;
    in
    builtins.replaceStrings [ "@" "/" ] [ "" "-" ] original;

  # https://yarnpkg.com/advanced/lexicon#descriptor
  # https://github.com/yarnpkg/berry/blob/599df9dc2c00fb5c39113b24e99a611d2a532ab4/packages/yarnpkg-core/sources/structUtils.ts#L361
  parseDescriptor = string:
    let
      split = splitString "/" string;
      scope = if substring 0 1 (elemAt split 0) == "@"
        then substring 1 999 (elemAt split 0)
        else null;
      split' = if scope != null then (sublist 1 999 split) else split;
      matches = builtins.match "^([^@]+)@(.+)$" (concatStringsSep "/" split');
      name = if matches != null then elemAt matches 0 else null;
      range = if matches != null then elemAt matches 1 else null;
    in
    if name == null
    then null
    else { inherit scope; inherit name; inherit range; };

  # https://yarnpkg.com/advanced/lexicon#descriptor
  # https://github.com/yarnpkg/berry/blob/599df9dc2c00fb5c39113b24e99a611d2a532ab4/packages/yarnpkg-core/sources/structUtils.ts#L629
  stringifyDescriptor = descriptor:
    if descriptor.scope != null then "@${descriptor.scope}/${descriptor.name}@${descriptor.range}"
    else "${descriptor.name}@${descriptor.range}";

  # https://yarnpkg.com/advanced/lexicon#locator
  # locators are valid descriptors, so just change the name of the attributes
  parseLocator = string:
    let
      dummyDescriptor = parseDescriptor string;
    in
    if dummyDescriptor == null
    then null
    else { scope = dummyDescriptor.scope; name = dummyDescriptor.name; reference = dummyDescriptor.range; };

  # https://yarnpkg.com/advanced/lexicon#locator
  # https://github.com/yarnpkg/berry/blob/599df9dc2c00fb5c39113b24e99a611d2a532ab4/packages/yarnpkg-core/sources/structUtils.ts#L640
  stringifyLocator = locator:
    if locator.scope != null then "@${locator.scope}/${locator.name}@${locator.reference}"
    else "${locator.name}@${locator.reference}";

  # https://yarnpkg.com/advanced/lexicon#range
  # https://github.com/yarnpkg/berry/blob/345b687be77696d696d6e6a4fd4ea7cf718ba31e/packages/yarnpkg-core/sources/structUtils.ts#L472
  #
  # <protocol>:<selector>::<bindings>
  # <protocol>:<source>#<selector>::<bindings>
  parseRange = string:
    let
      matchProtocolSourceSelectorBindings = builtins.match "^([^#:]*:)(.+)#(.+)::(.+)$" string;
      matchProtocolSelectorBindings = builtins.match "^([^#:]*:)(.+)::(.+)$" string;
      matchProtocolSourceSelector = builtins.match "^([^#:]*:)(.+)#(.+)$" string;
      matchProtocolSelector = builtins.match "^([^#:]*:)(.+)$" string;
      matches = findFirst notNull (builtins.throw "yarnpnp2nix parseRange(): not implemented: ${string}" null) [
        matchProtocolSourceSelectorBindings
        matchProtocolSelectorBindings
        matchProtocolSourceSelector
        matchProtocolSelector
      ];
      protocol = (elemAt matches 0);
      source =
        if length matches == 4 then decodeUri (elemAt matches 1)
        else if length matches == 3 && matchProtocolSourceSelector != null then decodeUri (elemAt matches 1)
        else null;
      selector =
        if length matches == 4 then decodeUri (elemAt matches 2)
        else if length matches == 3 && matchProtocolSourceSelector != null then decodeUri (elemAt matches 2)
        else elemAt matches 1;
      bindingsRaw =
        if length matches == 4 then elemAt matches 3
        else if length matches == 3 && matchProtocolSelectorBindings != null then elemAt matches 2
        else null;
      bindings = if bindingsRaw != null then parseQueryString bindingsRaw else null;
    in { inherit protocol; inherit source; inherit selector; inherit bindings; inherit bindingsRaw; };

  # ranges and references can be "bound" with some internal state.
  # we typically don't need or want this state when nixifying the lockfile, so this function discards it
  # if it is present.
  # see https://github.com/yarnpkg/berry/blob/599df9dc2c00fb5c39113b24e99a611d2a532ab4/packages/yarnpkg-core/sources/structUtils.ts#L252
  # for more info on what binding is
  removeBindingFromReference = range:
    let
      split = splitString "::" range;
    in
    if length split == 0 then split
    else elemAt split 0;
  removeBindingFromRange = removeBindingFromReference;

  # e.g optional!./source
  # e.g ./source
  extractPatchSource = string:
    let
      matchFlagsSource = builtins.match "^([^!]*)!(.+)$" string;
      matchSource = [ null string ];
      matches = findFirst notNull (builtins.throw "yarnpnp2nix extractPatchSource(): not implemented: ${string}" null) [
        matchFlagsSource
        matchSource
      ];
    in elemAt matches 1;

  isPatchSourceBuiltIn = patchSource:
    startsWith "builtin<" patchSource;
}
