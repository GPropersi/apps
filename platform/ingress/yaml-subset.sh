#!/usr/bin/env bash
# yaml-subset.sh: a tiny reader for the YAML subset that compose.yaml and dynamic.yml are written in. Source it
# from a test; do not run it.
#
#   . "$here/yaml-subset.sh"
#   ys_flatten < compose.yaml > flat.tsv   # rc 3 (reason on stderr) when the file leaves the subset
#   ys_get flat.tsv services/traefik/image
#   ys_list flat.tsv services/traefik/networks      # the values of services/traefik/networks[]
#   ys_has flat.tsv services/traefik/read_only
#   ys_children flat.tsv services/traefik/environment   # direct child keys
#
# Paths join keys with "/" (not ".") so that a path in a test never looks like a hostname to the secrets scan.
# The subset (anything else is refused, so a file that drifts out of it fails the tests instead of being
# misread):
#   - 2-space indentation, spaces only, "key: value" maps, "- value" lists indented two under their key;
#   - "- key: value" list items (maps in lists), whose further keys sit two deeper than the dash;
#   - scalars are plain or fully quoted ("..." or '...', no backslash and no inner quote of the same kind);
#   - whole-line "#" comments only (an unquoted value may not contain " #");
#   - no flow collections ([..] or {..}) as values, anchors, aliases, tags, block scalars, "---", merge keys.
#
# Output lines are "path<TAB>value": maps give "a/b<TAB>" for the key itself and "a/b/c<TAB>v" for scalars, lists
# give "a/b[]<TAB>v" per scalar item, list-of-map items give "a/b[0]/url<TAB>v". Duplicate paths are refused.

ys_flatten() {
  awk '
    function fail(msg) { printf("yaml-subset: line %d: %s\n", NR, msg) > "/dev/stderr"; bad = 1; exit 3 }
    function trim(s) { sub(/^ +/, "", s); sub(/ +$/, "", s); return s }
    function scalar(v,   q) {
      if (v ~ /^["\047]/) {
        q = substr(v, 1, 1)
        if (length(v) < 2 || substr(v, length(v), 1) != q) fail("unterminated quoted scalar")
        v = substr(v, 2, length(v) - 2)
        if (index(v, q) > 0) fail("inner quote of the same kind in a quoted scalar")
        if (index(v, "\\") > 0) fail("backslash in a quoted scalar")
        return v
      }
      if (v ~ /^[\[{&*!|>%@`]/) fail("flow collection, anchor, alias, tag or block scalar: " substr(v, 1, 1))
      if (v ~ /^<</) fail("merge key")
      if (v ~ / #/) fail("trailing comment in an unquoted value")
      if (v ~ /:$/ || v ~ /: /) fail("colon inside an unquoted value (inline map)")
      return v
    }
    function pathof(depth,   i, p) {
      p = ""
      for (i = 0; i <= depth; i++) {
        if (part[i] == "") continue
        if (substr(part[i], 1, 1) == "[") p = p part[i]
        else p = (p == "" ? "" : p "/") part[i]
      }
      return p
    }
    function emit(p, v) {
      if (p !~ /\[\]$/) {
        if (p in seen) fail("duplicate path " p)
        seen[p] = 1
      }
      printf("%s\t%s\n", p, v)
    }
    function setkey(depth, indent, rest,   key, val, m) {
      if (!match(rest, /^[A-Za-z0-9_.-]+:( |$)/)) fail("not a plain key: value line")
      key = substr(rest, 1, RLENGTH - 1)
      sub(/:$/, "", key)
      sub(/: $/, "", key)
      val = trim(substr(rest, RLENGTH + 1))
      if (index(key, ":") > 0) fail("colon in key")
      part[depth] = key
      for (m = depth + 1; m < 64; m++) { part[m] = ""; nlist[m] = 0 }
      lastdepth = depth
      if (val == "") { emit(pathof(depth), ""); kind[depth] = "k" }
      else { emit(pathof(depth), scalar(val)); kind[depth] = "s" }
    }
    /\t/ { fail("tab character") }
    /\r/ { fail("carriage return") }
    /^[ ]*$/ { next }
    /^[ ]*#/ { next }
    /^---/ || /^\.\.\./ { fail("document marker") }
    {
      line = $0
      match(line, /^ */); indent = RLENGTH
      if (indent % 2 != 0) fail("odd indentation")
      rest = substr(line, indent + 1)
      depth = indent / 2
      if (depth > 0 && kind[depth - 1] == "s") fail("indented under a scalar value")
      if (depth > lastdepth + 1) fail("indentation jumps more than one level")
      if (rest == "-" || rest ~ /^- /) {
        if (depth == 0) fail("list at top level")
        item = trim(substr(rest, 2))
        if (item == "") fail("empty list item")
        if (kind[depth - 1] != "k") fail("list item not under a key")
        if (item ~ /^[A-Za-z0-9_.-]+: / || item ~ /^[A-Za-z0-9_.-]+:$/) {
          nlist[depth]++
          part[depth] = "[" (nlist[depth] - 1) "]"
          for (m = depth + 1; m < 64; m++) { part[m] = ""; nlist[m] = 0 }
          kind[depth] = "m"
          lastdepth = depth
          setkey(depth + 1, indent + 2, item)
        } else {
          emit(pathof(depth - 1) "[]", scalar(item))
          part[depth] = ""
          kind[depth] = "i"
          lastdepth = depth
        }
        next
      }
      if (depth > 0 && kind[depth - 1] == "i") fail("key after a list item")
      setkey(depth, indent, rest)
    }
    BEGIN { lastdepth = -1 }
  '
}

# The file is passed on stdin to ys_flatten; these helpers take the flattened file.
ys_flatten_file() { ys_flatten < "$1"; }

ys_get() { awk -F '\t' -v p="$2" '$1 == p { print substr($0, length(p) + 2); exit }' "$1"; }
ys_has() { awk -F '\t' -v p="$2" '$1 == p { f = 1 } END { exit f ? 0 : 1 }' "$1"; }
ys_list() { awk -F '\t' -v p="$2[]" '$1 == p { print substr($0, length(p) + 2) }' "$1"; }
ys_children() {
  awk -F '\t' -v p="$2/" 'index($1, p) == 1 { rest = substr($1, length(p) + 1); sub(/[\/\[].*/, "", rest); if (rest != "" && !(rest in s)) { s[rest] = 1; print rest } }' "$1"
}
