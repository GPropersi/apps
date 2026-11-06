#!/usr/bin/env bash
# Tests for check-workflows.sh against scratch git repos: action pinning, pull_request_target, and the main-only guard
# on environment jobs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-workflows.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha="$(printf 'a%.0s' $(seq 40))"
passed=0
failed=0

# new_root: an empty git repo in $root.
new_root() {
  root="$tmp/root-$RANDOM"
  mkdir -p "$root/.github/workflows"
  git -C "$root" init -q
}

# add_wf <file name> <text>  (text is printf %b)
add_wf() {
  printf '%b' "$2" > "$root/.github/workflows/$1"
  git -C "$root" add -A
}

run_check() {
  rc=0
  out="$("$check" --root "$root" 2>&1)" || rc=$?
}

expect_pass() {
  if [ "$rc" -eq 0 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc)"; echo "$out"; fi
}

# expect_fail <label> <regex the output must match>
expect_fail() {
  if [ "$rc" -eq 1 ] && grep -qE -- "$2" <<< "$out"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc, wanted /$2/)"; echo "$out"
  fi
}

head_txt="name: t\non:\n  push:\n    branches: [main]\npermissions:\n  contents: read\n"
dispatch_head="name: t\non:\n  workflow_dispatch:\npermissions:\n  contents: read\n"

new_root; run_check
expect_pass "no workflows passes"

new_root; add_wf a.yml "${head_txt}jobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@$sha # v7\n      - uses: ./.github/actions/local\n"; run_check
expect_pass "pinned and local uses"

new_root; add_wf a.yml "${head_txt}jobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n"; run_check
expect_fail "floating tag" "^\\.github/workflows/a\\.yml: uses actions/checkout@v4 is not pinned"

new_root; add_wf a.yml "${head_txt}jobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@abc123\n"; run_check
expect_fail "short sha" "is not pinned to a 40-hex"

new_root; add_wf a.yml "${head_txt}jobs:\n  call:\n    uses: org/repo/.github/workflows/x.yml@main\n"; run_check
expect_fail "floating reusable workflow" "x\\.yml@main is not pinned"

new_root; add_wf a.yml "name: t\non:\n  pull_request_target:\njobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_fail "pull_request_target" "pull_request_target is forbidden"

new_root; add_wf a.yml "# never use pull_request_target here\n${head_txt}jobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_pass "pull_request_target in a comment"

new_root; add_wf a.yml "${head_txt}jobs:\n  d:\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n"; run_check
expect_fail "environment job with no guard" "job d has environment: but no if:"

new_root; add_wf a.yml "${head_txt}jobs:\n  d:\n    if: github.event_name == 'pull_request' || github.ref == 'refs/heads/main'\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n"; run_check
expect_fail "guard that allows pull_request" "job d has environment: but no if:"

new_root; add_wf a.yml "${head_txt}jobs:\n  d:\n    if: github.event_name == 'push'\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n"; run_check
expect_fail "guard without the main ref" "job d has environment: but no if:"

new_root; add_wf app-rollback.yml "${dispatch_head}jobs:\n  d:\n    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-latest\n    environment: production\n    concurrency:\n      group: deploy-x\n      cancel-in-progress: false\n      queue: max\n    steps:\n      - run: true\n"; run_check
expect_pass "main ref guard (push and workflow_dispatch)"

new_root; add_wf app-rollback.yml "${dispatch_head}jobs:\n  d:\n    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-latest\n    environment: production\n    concurrency:\n      group: deploy-x\n      cancel-in-progress: false\n      queue: max\n    steps:\n      - run: true\n"; run_check
expect_pass "workflow_dispatch job with a main ref guard"

new_root; add_wf a.yaml "${head_txt}jobs:\n  d:\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n"; run_check
expect_fail ".yaml extension is checked" "job d has environment:"

for g in "github.ref == 'refs/heads/main' || true" "github.ref == 'refs/heads/main' || github.event_name == 'workflow_run'" "github.ref == 'refs/heads/main-evil'" "!(github.ref == 'refs/heads/main')" "false # github.ref == 'refs/heads/main'"; do
  new_root; add_wf a.yml "${head_txt}jobs:\n  d:\n    if: $g\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n"; run_check
  expect_fail "weak guard: $g" "job d has environment:"
done

new_root; add_wf a.yml "name: t\non: push\njobs:\n    d:\n        runs-on: ubuntu-latest\n        environment: production\n"; run_check
expect_fail "4-space indented jobs are refused, not skipped" "no job at 2-space indent"

new_root; add_wf a.yml "name: t\non: push\njobs: {d: {environment: production}}\n"; run_check
expect_fail "inline jobs mapping" "must be a block mapping"

new_root; add_wf app-rollback.yml "${dispatch_head}jobs:\n  d:\n    if: github.ref == 'refs/heads/main'\r\n    runs-on: ubuntu-latest\n    environment: production\n    concurrency:\n      group: deploy-x\n      cancel-in-progress: false\n      queue: max\n    steps:\n      - uses: actions/checkout@$sha  \r\n"; run_check
expect_pass "CRLF and trailing whitespace"

new_root; add_wf app-rollback.yml "${dispatch_head}jobs:\n  d:\n    if: >-\n      github.actor == 'x' &&\n      github.ref == 'refs/heads/main'\n    runs-on: ubuntu-latest\n    environment:\n      name: production\n    concurrency:\n      group: deploy-x\n      cancel-in-progress: false\n      queue: max\n    steps:\n      - run: true\n"; run_check
expect_pass "multi-line guard with a mapping environment"

new_root; add_wf a.yml "${head_txt}jobs:\n  ok:\n    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n  bad:\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n"; run_check
expect_fail "second job unguarded" "job bad has environment:"

new_root; add_wf a.yml "${head_txt}jobs:\n  plain:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo environment: x\n"; run_check
expect_pass "job without environment needs no guard"

# --- run: block expressions -------------------------------------------------------------------------------------------
new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ssh \${{ secrets.GITHUB_TOKEN }}\n"; run_check
expect_fail "token expression in a one-line run" "interpolates a token expression"

new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - name: x\n        run: |\n          echo hi\n          echo \${{ github.token }}\n"; run_check
expect_fail "token expression in a multi-line run" "interpolates a token expression"

new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo \${{ env.PULL_TOKEN }}\n"; run_check
expect_fail "token env expression in a run" "interpolates a token expression"

for e in "inputs.app" "matrix.app" "needs.resolve.outputs.apps"; do
  new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          make test-app APP=\${{ $e }}\n"; run_check
  expect_fail "expression in a run: $e" "interpolates an inputs, matrix or needs output"
done

new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - name: x\n        env:\n          APP: \${{ inputs.app }}\n          T: \${{ secrets.GITHUB_TOKEN }}\n        run: |\n          printf '%%s' \"\$T\" | make test-app APP=\"\$APP\"\n      - run: echo done\n"; run_check
expect_pass "the same values through env:"

for e in "github.head_ref" "github.event.pull_request.title" "github.ref_name" "steps.x.outputs.y" "github.sha" "vars.HOST" "secrets.TS_OAUTH_SECRET"; do
  new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo \${{ $e }}\n"; run_check
  expect_fail "any expression in a one-line run: $e" "holds a [$][{][{] [}][}] expression"
done

# --- deploy host mask -------------------------------------------------------------------------------------------------
new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - env:\n          H: \${{ vars.PLATFORM_DEPLOY_HOST }}\n        run: ssh \"\$H\" x\n"; run_check
expect_fail "deploy host used without a mask" "never masks it"
new_root; add_wf a.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - env:\n          H: \${{ vars.PLATFORM_DEPLOY_HOST }}\n        run: |\n          echo \"::add-mask::\$H\"\n          ssh \"\$H\" x\n"; run_check
expect_pass "deploy host used with a mask"

# --- triggers ---------------------------------------------------------------------------------------------------------
for tr in workflow_run issue_comment pull_request_review repository_dispatch; do
  new_root; add_wf a.yml "name: t\non:\n  $tr:\n    types: [completed]\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
  expect_fail "forbidden trigger $tr" "trigger $tr is forbidden"
done
new_root; add_wf a.yml "name: t\non: [push, workflow_run]\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_fail "forbidden trigger in the inline form" "trigger workflow_run is forbidden"
new_root; add_wf app-rollback.yml "name: t\non:\n  workflow_dispatch:\n  push:\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_fail "a chain file with an extra trigger" "trigger push is not in the allow-list for app-rollback.yml"
new_root; add_wf app-rollback.yml "name: t\non:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_pass "a chain file with its exact trigger"

# --- permissions ------------------------------------------------------------------------------------------------------
new_root; add_wf a.yml "name: t\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_fail "a job with no permissions anywhere" "job j has no permissions"

new_root; add_wf a.yml "name: t\non: push\njobs:\n  j:\n    permissions:\n      contents: read\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_pass "job-level permissions without a workflow block"

new_root; add_wf b.yml "${head_txt}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; add_wf a.yml "${head_txt}jobs:\n  c:\n    uses: ./.github/workflows/b.yml\n"; run_check
expect_fail "a calling job without job-level permissions" "job c calls a reusable workflow and must set permissions on the job"

# --- secrets in a workflow with a pull_request trigger ----------------------------------------------------------------
pr_head="name: t\non:\n  pull_request:\n  push:\n    branches: [main]\npermissions:\n  contents: read\n"
new_root; add_wf a.yml "${pr_head}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n        env:\n          X: \${{ secrets.DEPLOY_KEY }}\n"; run_check
expect_fail "an unguarded secret job in a pull_request workflow" "job j reaches a secret or environment in a workflow with a pull_request trigger"

new_root; add_wf a.yml "${pr_head}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n        env:\n          X: \${{ secrets.GITHUB_TOKEN }}\n"; run_check
expect_pass "secrets.GITHUB_TOKEN alone needs no guard"

new_root; add_wf a.yml "${pr_head}jobs:\n  j:\n    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n        env:\n          X: \${{ secrets.DEPLOY_KEY }}\n"; run_check
expect_pass "a guarded secret job in a pull_request workflow"

for s in "secrets['FOO']" 'secrets["FOO"]' "toJSON(secrets)"; do
  new_root; add_wf a.yml "${pr_head}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n        env:\n          X: \${{ $s }}\n"; run_check
  expect_fail "unguarded secret in the form $s" "job j reaches a secret or environment in a workflow with a pull_request trigger"
done

new_root; add_wf a.yml "${pr_head}jobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n        env:\n          X: \${{ secrets['GITHUB_TOKEN'] }}\n"; run_check
expect_pass "secrets['GITHUB_TOKEN'] alone needs no guard"

new_root; add_wf a.yml "${head_txt}jobs:\n  \"j\":\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n"; run_check
expect_fail "a quoted job id is refused, not misattributed" "is not a plain name"

new_root; add_wf a.yml "${head_txt}jobs:\n  c:\n    permissions:\n      contents: read\n    uses: ./.github/workflows/missing.yml\n"; run_check
expect_fail "a call to a workflow that is not tracked" "calls missing.yml, which is not a tracked workflow"

# --- the deploy chain, from the real workflow files -------------------------------------------------------------------
real_wf="$(cd "$here/../.." && pwd)/.github/workflows"

# real_root: a scratch repo holding copies of the real chain workflows.
real_root() {
  new_root
  cp "$real_wf/ci.yml" "$real_wf/app-deploy.yml" "$real_wf/app-deploy-one.yml" "$real_wf/app-rollback.yml" "$root/.github/workflows/"
  git -C "$root" add -A
}

# mut <file> <sed -E expression>: edit a copied workflow; a mutation that changes nothing is a test bug.
mut() {
  local f="$root/.github/workflows/$1"
  cp "$f" "$tmp/before.yml"
  sed -i -E "$2" "$f"
  if cmp -s "$f" "$tmp/before.yml"; then failed=$((failed + 1)); echo "FAIL: mutation changed nothing: $1 $2"; fi
  git -C "$root" add -A
}

real_root; run_check
expect_pass "the real chain passes"

real_root; mut app-deploy.yml "s#if: github.ref == 'refs/heads/main' && needs#if: github.event_name == 'push' \\&\\& github.ref == 'refs/heads/main' \\&\\& needs#"; run_check
expect_fail "fan-out requiring event_name == push" "job fan-out must not require github.event_name == 'push'"

real_root; mut app-deploy.yml "s#if: github.ref == 'refs/heads/main' && needs.*#if: github.event_name == 'push'#"; run_check
expect_fail "fan-out guarded by event_name == push alone" "job fan-out .*needs the main guard"

real_root; mut app-deploy.yml "/^    if: github.ref == 'refs\\/heads\\/main'/d"; run_check
expect_fail "fan-out with no guard" "job fan-out .*needs the main guard"

real_root; mut ci.yml "s#if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs#if: github.ref == 'refs/heads/main' \\&\\& needs#"; run_check
expect_fail "caller without the push guard" "job app-deploy calls app-deploy.yml without the push\\+main if:"

real_root; mut ci.yml "/^    if: .*needs\\.detect\\.outputs/d"; run_check
expect_fail "unguarded caller of app-deploy.yml" "job app-deploy calls app-deploy.yml without the push\\+main if:"
expect_fail "unguarded caller in a pull_request workflow" "job app-deploy reaches a secret or environment in a workflow with a pull_request trigger"

real_root; mut app-deploy.yml "s#fail-fast: false#fail-fast: true#"; run_check
expect_fail "fail-fast true on the fan-out" "job fan-out calls app-deploy-one.yml and must set strategy fail-fast: false"

real_root; mut app-deploy.yml "s#^        app: .*#        other: x#"; run_check
expect_fail "a matrix without an app axis" "job fan-out calls app-deploy-one.yml and must set strategy fail-fast: false and a matrix"

real_root; mut app-deploy-one.yml "s#needs: \\[test, build\\]#needs: [build]#"; run_check
expect_fail "deploy not needing test" "job deploy must need test and build"

real_root; mut app-deploy-one.yml "s#needs: \\[arch, test\\]#needs: [arch]#"; run_check
expect_fail "build not needing test" "job build must need arch and test"

real_root; mut app-deploy-one.yml "s#packages: read#packages: write#"; run_check
expect_fail "deploy declaring packages: write" "job deploy must declare packages: read"

real_root; printf '  extra:\n    if: github.ref == '"'"'refs/heads/main'"'"'\n    runs-on: ubuntu-latest\n    environment: production\n    steps:\n      - run: true\n' >> "$root/.github/workflows/ci.yml"; git -C "$root" add -A; run_check
expect_fail "environment outside the deploy workflows" "job extra has environment:, which is allowed only in app-deploy-one.yml and app-rollback.yml"

real_root; printf '  again:\n    permissions:\n      contents: read\n      packages: write\n    uses: ./.github/workflows/app-deploy.yml\n    with:\n      apps: x\n' >> "$root/.github/workflows/app-deploy-one.yml"; git -C "$root" add -A; run_check
expect_fail "nesting past three levels" "workflow nests [0-9]+ levels deep"

real_root; mut ci.yml "s#packages: write#packages: read#"; run_check
expect_fail "caller grants below what the chain needs" "job app-deploy grants packages below what the workflow it calls"

real_root; mut app-deploy.yml "s#packages: write#packages: read#"; run_check
expect_fail "fan-out grants below what the build needs" "job fan-out grants packages below what the workflow it calls \\(app-deploy-one.yml\\)"

real_root; mut app-deploy-one.yml "s#cancel-in-progress: false#cancel-in-progress: true#"; run_check
expect_fail "deploy cancelling in progress" "job deploy needs a deploy-<app> concurrency group with queue: max and cancel-in-progress: false"

real_root; mut app-rollback.yml "/queue: max/d"; run_check
expect_fail "rollback without queue: max" "job rollback needs a deploy-<app> concurrency group"

real_root; mut app-rollback.yml "s#group: deploy-#group: other-#"; run_check
expect_fail "rollback in a different group" "job rollback needs a deploy-<app> concurrency group"

real_root; mut app-deploy-one.yml "s#^    if: github.ref == 'refs/heads/main'#    if: github.event_name == 'push'#"; run_check
expect_fail "deploy without the main guard" "job deploy has environment: but no if:"

real_root; mut app-deploy-one.yml "s#run: make test-app APP=\"[\$]APP\"#run: make test-app APP=\${{ inputs.app }}#"; run_check
expect_fail "the real test step interpolating the app" "interpolates an inputs, matrix or needs output"

# Rule 13: the Go cache. The real ci.yml passes (the first real_root case above); each violation fails.
save_cond_pat="needs exactly if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
real_root; mut ci.yml "s#^(        if: )github.event_name == 'push' && github.ref == 'refs/heads/main'\$#\1github.ref == 'refs/heads/main'#"; run_check
expect_fail "cache/save without the push condition" "$save_cond_pat"

real_root; mut ci.yml "s#^(        if: )github.event_name == 'push' && github.ref == 'refs/heads/main'\$#\1github.event_name != 'pull_request'#"; run_check
expect_fail "cache/save on any non-PR event" "$save_cond_pat"

real_root; mut ci.yml "/^        if: github.event_name == 'push' && github.ref == 'refs\\/heads\\/main'\$/d"; run_check
expect_fail "cache/save with no condition at all" "$save_cond_pat"

real_root; mut ci.yml "s#^(        if: github.event_name == 'push' && github.ref == 'refs/heads/main')\$#\1 || true#"; run_check
expect_fail "cache/save widened with || true" "$save_cond_pat"

real_root; mut ci.yml "s#actions/cache/save@#actions/cache@#"; run_check
expect_fail "the combined actions/cache action" "the combined actions/cache action is forbidden"

real_root; mut ci.yml "s#actions/cache/restore@#actions/cache@#"; run_check
expect_fail "the combined actions/cache action as the restore" "the combined actions/cache action is forbidden"

real_root; run_check
if grep -q 'actions/cache/save@' "$root/.github/workflows/ci.yml" && [ "$rc" -eq 0 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: the real ci.yml has the guarded cache/save step and passes (rc=$rc)"; echo "$out"; fi

# CLI behaviour.
rc=0; out="$("$check" --bogus 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: unknown argument exits 2 (rc=$rc)"; fi
rc=0; out="$("$check" --root 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: missing --root value exits 2 (rc=$rc)"; fi

echo "check-workflows tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
