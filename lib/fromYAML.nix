# Many thanks to https://github.com/nix-community/dream2nix/blob/5252794e58eedb02d607fa3187ffead7becc81b0/src/subsystems/nodejs/translators/yarn-lock/parser.nix
# who have solved the problem of parsing the Yarn lock file YAML in absence of a Nix builtin for parsing YAML

# MIT License

# Copyright (c) 2021 DavHau

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

/*
This is a yarn.lock v1 & v2 to attrs parser.
It regexes the yarn file line by line and replaces characters in order to
make it a valid json, then parses the json.
*/
{lib, ...}: let
  l = lib // builtins;

  parse = text: let
    lines = l.splitString "\n" text;

    # Find the line number at which the actual data begins.
    # Jump comments and meta fields at the beginning of the file.
    findStartLineNum = num: let
      line = l.elemAt lines num;
    in
      if
        ! l.hasPrefix "#" line
        && ! l.hasPrefix " " line
        && ! l.hasPrefix "_" line
      then num
      else findStartLineNum (num + 1);

    # all relevant lines which contain the actual data
    contentLines =
      l.sublist
      (findStartLineNum 0)
      ((l.length lines) - 1)
      lines;

    # Match each line to get: indent, key, value.
    # If a key value expression spans multiple lines,
    # the value of the current line will be defined null
    matchLine = line: let
      # yarn v2 single line
      m1 = l.match ''( *)(.*): (.*)'' line;
      # multi line v1 & v2
      m2 = l.match ''( *)(.*):$'' line;

      # yarn v1 single line with quoted key
      m3 = l.match ''( *)(.*) "(.*)"'' line;
      # yarn v1 single line with unquoted key
      m4 = l.match ''( *)(.*) (.*)'' line;
    in
      if m1 != null
      then {
        indent = (l.stringLength (l.elemAt m1 0)) / 2;
        key = l.elemAt m1 1;
        value = l.elemAt m1 2;
      }
      else if m2 != null
      then {
        indent = (l.stringLength (l.elemAt m2 0)) / 2;
        # transform yarn 1 to yarn 2 style
        key =
          l.replaceStrings ['', "''] ['', '']
          (l.replaceStrings [''", ''] ['', ''] (l.elemAt m2 1));
        value = null;
      }
      else if m3 != null
      then {
        indent = (l.stringLength (l.elemAt m3 0)) / 2;
        key = l.elemAt m3 1;
        value = l.elemAt m3 2;
      }
      else if m4 != null
      then {
        indent = (l.stringLength (l.elemAt m4 0)) / 2;
        key = l.elemAt m4 1;
        value = l.elemAt m4 2;
      }
      else null;

    # generate string with `num` closing braces
    closingBraces = num:
      if num == 1
      then "}"
      else "}" + (closingBraces (num - 1));

    # convert yarn lock lines to json lines
    jsonLines = lines: let
      filtered = l.filter (line: l.match ''[[:space:]]*'' line == null) lines;
      matched = l.map (line: matchLine line) filtered;
    in
      l.imap0
      (i: line: let
        mNext = l.elemAt matched (i + 1);
        m = l.elemAt matched i;
        # ensure key is quoted
        keyInQuotes = let
          beginOK = l.hasPrefix ''"'' m.key;
          endOK = l.hasSuffix ''"'' m.key;
          begin = l.optionalString (! beginOK) ''"'';
          end = l.optionalString (! endOK) ''"'';
        in ''${begin}${m.key}${end}'';
        # ensure value is quoted
        valInQuotes =
          if l.hasPrefix ''"'' m.value
          then m.value
          else ''"${m.value}"'';
      in
        # reached the end, put closing braces
        if l.length filtered == i + 1
        then let
          end = closingBraces m.indent;
        in ''${keyInQuotes}: ${valInQuotes}${end}}''
        # handle lines with only a key (beginning of multi line statement)
        else if m.value == null
        then ''${keyInQuotes}: {''
        # if indent of next line is smaller, close the object
        else if mNext.indent < m.indent
        then let
          end = closingBraces (m.indent - mNext.indent);
        in ''${keyInQuotes}: ${valInQuotes}${end},''
        # line with key value statement
        else ''${keyInQuotes}: ${valInQuotes},'')
      filtered;

    # concatenate json lines to json string
    json = "{${l.concatStringsSep "\n" (jsonLines contentLines)}";

    # parse the json to an attrset
    dataRaw = l.fromJSON json;
  in
    dataRaw;
in {
  inherit parse;
}
