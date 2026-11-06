#!/usr/bin/env bash
# check-workflows.sh: the workflow rules `make lint` enforces on the tracked .github/workflows/*.yml|yaml files.
# Each problem prints `<path>: <reason>` on stdout and the script exits 1 (2 on usage).
#
#   platform/lint/check-workflows.sh [--root DIR]      DIR is a git work tree (default: the git top level)
#
# Per file:
#   1. every `uses:` is pinned to a 40-hex commit SHA (a local `./path` action or workflow is exempt);
#   2. `pull_request_target` appears nowhere outside a comment;
#   3. every job with `environment:` carries a job-level `if:` that tests `github.ref == 'refs/heads/main'` and never
#      mentions `event_name == 'pull_request'` (the "main guard"). That holds for `push` and `workflow_dispatch` alike, so
#      rollback and redeploy-all jobs are not skipped, and it can never be true for a pull request;
#   4. no `run:` block holds any `${{ }}` expression (tokens, inputs.*, matrix.*, needs outputs, github.head_ref,
#      github.event.*, steps outputs, ...): every value reaches a step only through `env:`;
#   4a. a workflow that reads vars.PLATFORM_DEPLOY_HOST also runs `::add-mask::` (a variable is never masked);
#   4b. `on:` triggers: workflow_run, issue_comment and the other outside-input events are forbidden everywhere, and the
#      four deploy-chain files are limited to their exact trigger set (ci.yml pull_request+push; app-deploy.yml
#      workflow_call+workflow_dispatch; app-rollback.yml workflow_dispatch; app-deploy-one.yml workflow_call).
# The deploy chain (ci.yml -> app-deploy.yml -> app-deploy-one.yml, plus app-rollback.yml), checked across files:
#   5. `environment:` appears only in app-deploy-one.yml and app-rollback.yml;
#   6. a job calling app-deploy.yml carries the push+main guard (`event_name == 'push'` and the main guard);
#   7. in app-deploy.yml, app-deploy-one.yml and app-rollback.yml a job with `secrets.` (other than GITHUB_TOKEN), a
#      called workflow or `environment:` carries the main guard and never requires `event_name == 'push'`;
#   8. a job calling app-deploy-one.yml sets `fail-fast: false` and a `matrix`; in app-deploy-one.yml `deploy` needs
#      `test` and `build`, `build` needs `arch` and `test`, and `deploy` declares `packages: read`;
#   9. no workflow nests deeper than three levels;
#  10. a job reaching a secret or an environment, directly or through a called workflow, is guarded by the main guard on
#      itself or on every caller; in a workflow with a `pull_request` trigger a job reaching either must carry it itself;
#  11. every job has `permissions` (own or workflow-level), a job calling a workflow sets them on the job, and a
#      caller's grants cover the grants of every job it reaches, recursively;
#  12. every `environment:` job in app-deploy-one.yml and app-rollback.yml has a `deploy-` concurrency group with
#      `queue: max` and `cancel-in-progress: false`.
#  13. no step uses the combined `actions/cache` action, and every `actions/cache/save` step carries exactly
#      `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` (only main writes the cache, never a PR).
# Comment lines are ignored. The parse is line-based and assumes the repo's 2-space YAML (jobs at 2 spaces, job keys
# at 4); a job with `environment:` it cannot pair with a guard fails closed.
set -uo pipefail

root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "missing value for --root" >&2; exit 2; }; root="$2"; shift 2 ;;
    -h | --help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] || root="$(git rev-parse --show-toplevel)" || exit 2

files="$(git -C "$root" ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' | tr '\0' '\n')" || exit 2

facts="$(mktemp)" || exit 2
trap 'rm -f "$facts"' EXIT

# Pass 1, per file: the file-local rules print problems; the facts (one W line per workflow, one J line per job) go to
# $facts for the cross-file pass.
problems=0
while IFS= read -r wf; do
  [ -n "$wf" ] || continue
  out="$(awk -v path="$wf" -v base="${wf##*/}" -v facts="$facts" '
    function indent(s,   t) { t = s; sub(/[^ ].*$/, "", t); return length(t) }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function value(s, key,   v) { v = s; sub("^[ ]*" key ":[ ]*", "", v); sub(/[ \t]+#.*$/, "", v); return trim(v) }
    function unq(s) { gsub(/["\047]/, "", s); return s }
    # parseperm: "{contents: read, packages: write}" or "read-all" -> "contents=read;packages=write;" / "*=read;"
    function parseperm(v,   n, a, i, kv, r) {
      gsub(/[{}]/, "", v); v = trim(v)
      if (v ~ /^(read|write)-all$/) return "*=" substr(v, 1, index(v, "-") - 1) ";"
      r = ""
      n = split(v, a, ",")
      for (i = 1; i <= n; i++) {
        if (split(a[i], kv, ":") == 2) r = r trim(kv[1]) "=" trim(kv[2]) ";"
      }
      return r
    }
    function addneeds(v,   n, a, i) {
      sub(/^[ ]*-[ ]+/, "", v); gsub(/[][]/, " ", v); gsub(/,/, " ", v)
      n = split(v, a, /[ ]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") needs = needs " " a[i]
    }
    function checkrun(text, n) {
      if (text ~ /\$\{\{[^}]*(github\.token|secrets\.GITHUB_TOKEN|env\.[A-Za-z0-9_]*TOKEN)/)
        print path ": a run: block interpolates a token expression (line " n "); pass it through env: and pipe it"
      if (text ~ /\$\{\{[^}]*(inputs\.|matrix\.|needs\.[A-Za-z0-9_-]+\.outputs)/)
        print path ": a run: block interpolates an inputs, matrix or needs output expression (line " n "); pass it through env:"
      # Everything else (github.head_ref, github.event.*, steps.*.outputs, github.actor, vars.*, a non-GITHUB_TOKEN secret)
      # is attacker- or admin-controlled text that becomes shell source: no expression at all belongs in a run: block.
      if (text ~ /\$\{\{/)
        print path ": a run: block holds a ${{ }} expression (line " n "); pass every value through env: and read it as a shell variable"
    }
    # evalsave: a pending actions/cache/save step runs only on a push to main (no pull-request code ever writes the cache).
    function evalsave() {
      if (savepending && stepif != "github.event_name == push && github.ref == refs/heads/main")
        print path ": the actions/cache/save step (line " saveline ") needs exactly if: github.event_name == \047push\047 && github.ref == \047refs/heads/main\047"
      savepending = 0
    }
    function addtrig(t) { trig = trig " " t " " }
    function checktrig(   n, a, i, bad, allowed, t) {
      bad = " workflow_run issue_comment issues pull_request_review pull_request_review_comment discussion discussion_comment repository_dispatch fork watch "
      allowed = ""
      if (base == "ci.yml") allowed = " pull_request push "
      else if (base == "app-deploy.yml") allowed = " workflow_call workflow_dispatch "
      else if (base == "app-rollback.yml") allowed = " workflow_dispatch "
      else if (base == "app-deploy-one.yml") allowed = " workflow_call "
      n = split(trig, a, " ")
      for (i = 1; i <= n; i++) {
        t = a[i]
        if (t == "") continue
        if (index(bad, " " t " ") > 0) print path ": trigger " t " is forbidden (it runs with base-repo secrets for outside input)"
        else if (allowed != "" && index(allowed, " " t " ") == 0) print path ": trigger " t " is not in the allow-list for " base
      }
    }
    function reset() {
      job = ""; env = 0; guard = ""; inif = 0; juses = ""; needs = ""; perm = ""; hasperm = 0
      grp = ""; queue = ""; cancel = ""; ff = ""; matrix = 0; sec = 0
      inneeds = 0; inperm = 0; inconc = 0; instrat = 0; inmatrix = 0
    }
    function flush() {
      # Accepted: a main-ref test, no pull_request test, and no || or ! that could widen or invert it.
      if (env && !(guard ~ /github\.ref[ ]*==[ ]*[\047"]refs\/heads\/main[\047"]/ && guard !~ /event_name[ ]*==[ ]*[\047"]pull_request/ && guard !~ /\|\||!/)) {
        print path ": job " (job == "" ? "(unnamed)" : job) " has environment: but no if: limiting it to github.ref == refs/heads/main (and not pull_request, no || or !)"
      }
      if (job != "") {
        gsub(/\t/, " ", guard)
        printf "J\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%d\t%d\n", base, job, env, guard, juses, trim(needs), perm, hasperm, grp, queue, cancel, ff, matrix, sec >> facts
      }
      reset()
    }
    BEGIN { reset(); savepending = 0; saveline = 0; stepif = ""; trig = ""; usehost = 0; hasmask = 0; runcol = -1; wpr = 0; wperm = ""; whas = 0; inon = 0; inwperm = 0 }
    /^[ ]*#/ { next }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /pull_request_target/) print path ": pull_request_target is forbidden (line " NR ")"
      if (line ~ /vars\.PLATFORM_DEPLOY_HOST/) usehost = 1
      if (line ~ /::add-mask::/) hasmask = 1
      if (line ~ /^[ ]*-?[ ]*uses:/) {
        v = line; sub(/^[ ]*-?[ ]*uses:[ ]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); gsub(/["\047]/, "", v)
        if (v !~ /^\.\// && v !~ /@[0-9a-f]{40}$/) print path ": uses " v " is not pinned to a 40-hex commit SHA (line " NR ")"
      }
      ind = indent(line)
      # Rule 13: a step boundary evaluates the pending cache/save step; then this line may carry the step if: or uses:.
      if (ind <= 4 || (ind == 6 && line ~ /^[ ]*-[ ]/)) { evalsave(); stepif = "" }
      if (ind >= 6 && line ~ /^[ ]*(-[ ]+)?if:[ ]/) { stepif = unq(value(line, "if")); sub(/^[ ]*-[ ]+/, "", stepif); sub(/^if:[ ]*/, "", stepif); stepif = trim(stepif) }
      if (line ~ /^[ ]*-?[ ]*uses:[ ]*["\047]?actions\/cache@/) print path ": the combined actions/cache action is forbidden (line " NR "); use actions/cache/restore and actions/cache/save"
      if (line ~ /^[ ]*-?[ ]*uses:[ ]*["\047]?actions\/cache\/save@/) { savepending = 1; saveline = NR }
      # run: blocks (any depth): content lines are indented past the key.
      if (runcol >= 0) {
        if (line ~ /^[ ]*$/) { }
        else if (ind > runcol) checkrun(line, NR)
        else runcol = -1
      }
      if (runcol < 0 && line ~ /^[ ]*(-[ ]+)?run:/) {
        p = line; sub(/run:.*$/, "", p); runcol = length(p)
        rest = line; sub(/^[ ]*(-[ ]+)?run:[ ]*/, "", rest)
        if (rest != "" && rest !~ /^[|>]/) { checkrun(rest, NR); runcol = -1 }
      }
      if (line ~ /^[ ]*$/) next
      if (ind == 0) {
        flush(); injobs = (line ~ /^jobs:/)
        inon = 0; inwperm = 0
        if (line ~ /^on:/) {
          inon = 1; rest = line; sub(/^on:[ ]*/, "", rest); sub(/[ \t]+#.*$/, "", rest)
          if (rest ~ /(^|[^_a-z])pull_request([^_a-z]|$)/) wpr = 1
          nt = split(rest, ta, /[^a-z_]+/); for (ti = 1; ti <= nt; ti++) if (ta[ti] != "") addtrig(ta[ti])
        }
        if (line ~ /^permissions:/) {
          whas = 1; rest = value(line, "permissions")
          if (rest == "") inwperm = 1; else wperm = parseperm(rest)
        }
        if (injobs) {
          sawjobs = 1
          if (line !~ /^jobs:[ ]*(#.*)?$/) print path ": jobs: must be a block mapping, not inline (line " NR ")"
        }
        next
      }
      if (!injobs) {
        if (inon && line ~ /(^|[^_a-z])pull_request([^_a-z]|:|$)/) wpr = 1
        if (inon && ind == 2 && line ~ /^  [a-z_]+:/) { tt = line; sub(/^  /, "", tt); sub(/:.*$/, "", tt); addtrig(tt) }
        if (inwperm && ind == 2 && line ~ /^  [a-z-]+:/) wperm = wperm parseperm(line)
        next
      }
      t = line; gsub(/secrets\.GITHUB_TOKEN/, "", t); gsub(/secrets\[[ ]*[\047"]GITHUB_TOKEN[\047"][ ]*\]/, "", t)
      if (t ~ /secrets(\.|\[)/ || t ~ /toJSON\(secrets\)/ || t ~ /^[ ]*secrets:[ ]*inherit/) sec = 1
      if (ind == 2 && line !~ /^  [A-Za-z0-9_-]+:/) print path ": a job id on line " NR " is not a plain name (the parser needs unquoted [A-Za-z0-9_-] ids)"
      if (ind == 2 && line ~ /^  [A-Za-z0-9_-]+:/) { flush(); njobs++; job = line; sub(/^  /, "", job); sub(/:.*$/, "", job); next }
      if (ind == 4) {
        inif = 0; inneeds = 0; inperm = 0; inconc = 0; instrat = 0; inmatrix = 0
        if (line ~ /^    environment:/) env = 1
        if (line ~ /^    if:/) { inif = 1; v = line; sub(/[ ]+#.*$/, "", v); guard = v }
        if (line ~ /^    uses:/) juses = unq(value(line, "uses"))
        if (line ~ /^    needs:/) { v = value(line, "needs"); if (v == "") inneeds = 1; else addneeds(v) }
        if (line ~ /^    permissions:/) { hasperm = 1; v = value(line, "permissions"); if (v == "") inperm = 1; else perm = parseperm(v) }
        if (line ~ /^    concurrency:/) { v = unq(value(line, "concurrency")); if (v == "") inconc = 1; else grp = v }
        if (line ~ /^    strategy:/) instrat = 1
        next
      }
      if (ind > 4 && inif) { v = line; sub(/[ ]+#.*$/, "", v); guard = guard " " v }
      if (inneeds && line ~ /^[ ]*-[ ]/) addneeds(line)
      if (inperm && ind == 6 && line ~ /^[ ]*[a-z-]+:/) perm = perm parseperm(line)
      if (inconc && ind == 6) {
        if (line ~ /^[ ]*group:/) grp = unq(value(line, "group"))
        if (line ~ /^[ ]*queue:/) queue = unq(value(line, "queue"))
        if (line ~ /^[ ]*cancel-in-progress:/) cancel = unq(value(line, "cancel-in-progress"))
      }
      if (instrat && ind == 6) {
        inmatrix = (line ~ /^[ ]*matrix:/)
        if (line ~ /^[ ]*fail-fast:/) ff = unq(value(line, "fail-fast"))
      }
      # a matrix counts only when it has an app: axis
      if (instrat && inmatrix && ind == 8 && line ~ /^[ ]*app:/) matrix = 1
    }
    END {
      evalsave()
      flush()
      checktrig()
      if (usehost && !hasmask) print path ": uses vars.PLATFORM_DEPLOY_HOST but never masks it (echo \"::add-mask::$DEPLOY_HOST\"); a variable is not masked in public logs"
      if (sawjobs && njobs == 0) print path ": jobs: has no job at 2-space indent (the parser needs 2-space YAML)"
      printf "W\t%s\t%d\t%s\t%d\n", base, wpr, wperm, whas >> facts
    }
  ' "$root/$wf")" || exit 2
  if [ -n "$out" ]; then
    echo "$out"
    problems=$((problems + $(printf '%s\n' "$out" | wc -l)))
  fi
done <<< "$files"

# Pass 2: the cross-file rules over the collected facts.
out="$(awk -F'\t' '
  function lvl(v) { return v == "write" ? 2 : (v == "read" ? 1 : 0) }
  function plvl(p, scope,   n, a, i, kv, got, star) {
    n = split(p, a, ";"); got = -1; star = 0
    for (i = 1; i <= n; i++) {
      if (a[i] == "") continue
      split(a[i], kv, "=")
      if (kv[1] == scope) got = lvl(kv[2]); else if (kv[1] == "*") star = lvl(kv[2])
    }
    return got >= 0 ? got : star
  }
  function mainguard(g) { return g ~ /github\.ref[ ]*==[ ]*[\047"]refs\/heads\/main[\047"]/ && g !~ /event_name[ ]*==[ ]*[\047"]pull_request/ && g !~ /\|\||!/ }
  function needspush(g) { return g ~ /event_name[ ]*==[ ]*[\047"]push[\047"]/ }
  function target(u) { if (u ~ /^\.\/\.github\/workflows\//) { sub(/^.*\//, "", u); return u } return "" }
  function effperm(f, j) { return Jhas[f, j] ? Jperm[f, j] : (Whas[f] ? Wperm[f] : "") }
  function effdef(f, j) { return Jhas[f, j] || Whas[f] }
  function hasneed(f, j, n) { return index(" " Jneeds[f, j] " ", " " n " ") > 0 }
  function sens(f, d,   i, j, t) {
    if (d > 6) return 0
    for (i = 1; i <= Nj[f]; i++) {
      j = Jn[f, i]
      if (Jenv[f, j] || Jsec[f, j]) return 1
      t = target(Juses[f, j])
      if (t != "" && (t in Nj) && sens(t, d + 1)) return 1
    }
    return 0
  }
  function depth(f, d,   i, j, t, m, x) {
    if (d > 6) return d
    m = 1
    for (i = 1; i <= Nj[f]; i++) {
      j = Jn[f, i]; t = target(Juses[f, j])
      if (t != "" && (t in Nj)) { x = 1 + depth(t, d + 1); if (x > m) m = x }
    }
    return m
  }
  function collect(f, d,   i, j, t, n, a, k, kv, p) {
    if (d > 6) return
    for (i = 1; i <= Nj[f]; i++) {
      j = Jn[f, i]; p = effperm(f, j)
      n = split(p, a, ";")
      for (k = 1; k <= n; k++) {
        if (a[k] == "") continue
        split(a[k], kv, "=")
        if (lvl(kv[2]) > REQ[kv[1]]) REQ[kv[1]] = lvl(kv[2])
      }
      t = target(Juses[f, j])
      if (t != "" && (t in Nj)) collect(t, d + 1)
    }
  }
  function allcallers_guarded(f,   g, i, j, any, ok) {
    ok = 1; any = 0
    for (g in Nj) for (i = 1; i <= Nj[g]; i++) {
      j = Jn[g, i]
      if (target(Juses[g, j]) == f) { any = 1; if (!mainguard(Jguard[g, j])) ok = 0 }
    }
    return any && ok
  }
  $1 == "W" { Whas_seen[$2] = 1; Wpr[$2] = $3; Wperm[$2] = $4; Whas[$2] = $5; if (!($2 in Nj)) Nj[$2] = 0; next }
  $1 == "J" {
    f = $2; j = $3
    Nj[f]++; Jn[f, Nj[f]] = j
    Jenv[f, j] = $4; Jguard[f, j] = $5; Juses[f, j] = $6; Jneeds[f, j] = $7; Jperm[f, j] = $8; Jhas[f, j] = $9
    Jgrp[f, j] = $10; Jqueue[f, j] = $11; Jcancel[f, j] = $12; Jff[f, j] = $13; Jmatrix[f, j] = $14; Jsec[f, j] = $15
  }
  END {
    for (f in Nj) {
      p = ".github/workflows/" f
      chain = (f == "app-deploy.yml" || f == "app-deploy-one.yml" || f == "app-rollback.yml")
      d = depth(f, 1)
      if (d > 3) print p ": workflow nests " d " levels deep (the limit is ci.yml -> app-deploy.yml -> app-deploy-one.yml)"
      for (i = 1; i <= Nj[f]; i++) {
        j = Jn[f, i]; g = Jguard[f, j]; t = target(Juses[f, j]); callsloc = (t != "" && (t in Nj))
        if (t != "" && !(t in Nj)) print p ": job " j " calls " t ", which is not a tracked workflow"
        if (Jenv[f, j] && f != "app-deploy-one.yml" && f != "app-rollback.yml")
          print p ": job " j " has environment:, which is allowed only in app-deploy-one.yml and app-rollback.yml"
        if (t == "app-deploy.yml" && !(mainguard(g) && needspush(g)))
          print p ": job " j " calls app-deploy.yml without the push+main if: (github.event_name == \047push\047 and github.ref == \047refs/heads/main\047)"
        if (chain && (Jenv[f, j] || Jsec[f, j] || Juses[f, j] != "")) {
          if (mainguard(g)) {
            if (needspush(g)) print p ": job " j " must not require github.event_name == \047push\047 (workflow_dispatch has to reach it); use the main guard alone"
          } else if (!Jenv[f, j]) {
            print p ": job " j " reaches secrets, an environment or a called workflow and needs the main guard if: github.ref == refs/heads/main (not event_name == \047push\047)"
          }
        }
        if (t == "app-deploy-one.yml" && !(Jff[f, j] == "false" && Jmatrix[f, j]))
          print p ": job " j " calls app-deploy-one.yml and must set strategy fail-fast: false and a matrix over the app"
        if (!effdef(f, j)) print p ": job " j " has no permissions (set them on the job or at the workflow level)"
        else if (Juses[f, j] != "" && !Jhas[f, j]) print p ": job " j " calls a reusable workflow and must set permissions on the job"
        if (callsloc) {
          delete REQ
          collect(t, 1)
          decl = effperm(f, j)
          for (s in REQ) if (REQ[s] > plvl(decl, s))
            print p ": job " j " grants " s " below what the workflow it calls (" t ") needs"
        }
        if (Jsec[f, j] || (callsloc && sens(t, 1))) {
          if (Wpr[f] && !Jenv[f, j] && !mainguard(g))
            print p ": job " j " reaches a secret or environment in a workflow with a pull_request trigger without the main guard if:"
          else if (!Wpr[f] && !Jenv[f, j] && !mainguard(g) && !allcallers_guarded(f))
            print p ": job " j " reaches a secret or environment but neither it nor every caller has the main guard if:"
        }
        if (f == "app-deploy-one.yml" || f == "app-rollback.yml") {
          if (Jenv[f, j] && !(Jgrp[f, j] ~ /^deploy-/ && Jqueue[f, j] == "max" && Jcancel[f, j] == "false"))
            print p ": job " j " needs a deploy-<app> concurrency group with queue: max and cancel-in-progress: false"
        }
      }
      if (f == "app-deploy-one.yml") {
        if (!((f, "deploy") in Jenv)) print p ": no deploy job"
        else {
          if (!hasneed(f, "deploy", "test") || !hasneed(f, "deploy", "build")) print p ": job deploy must need test and build"
          if (plvl(effperm(f, "deploy"), "packages") != 1) print p ": job deploy must declare packages: read"
        }
        if (!((f, "build") in Jenv)) print p ": no build job"
        else if (!hasneed(f, "build", "arch") || !hasneed(f, "build", "test")) print p ": job build must need arch and test"
      }
    }
  }
' "$facts")" || exit 2
if [ -n "$out" ]; then
  echo "$out"
  problems=$((problems + $(printf '%s\n' "$out" | wc -l)))
fi

if [ "$problems" -ne 0 ]; then
  exit 1
fi
echo "check-workflows: OK"
