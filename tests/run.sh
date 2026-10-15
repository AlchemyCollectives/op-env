#!/usr/bin/env bash
# Runs op-env against the stub op CLI in a throwaway workspace. No network,
# no real 1Password access. Exits non-zero on the first failed assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OP_ENV="$ROOT/bin/op-env"
STUB="$ROOT/tests/stub/op"
chmod +x "$OP_ENV" "$STUB"

passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok   %s\n' "$*"; }

# A fresh workspace per test keeps the cases independent.
new_workspace() {
    WS="$(mktemp -d)"
    export OP_ENV_STUB_DIR="$WS/stub"
    export TMPDIR="$WS/tmp"
    mkdir -p "$OP_ENV_STUB_DIR/env" "$TMPDIR" "$WS/repo/traefik" "$WS/repo/metabase"
    cd "$WS/repo"
}

# Writes a NUL-separated fixture for one Environment ID.
fixture() {
    local id="$1"; shift
    : > "$OP_ENV_STUB_DIR/env/$id.env0"
    local pair
    for pair in "$@"; do printf '%s\0' "$pair" >> "$OP_ENV_STUB_DIR/env/$id.env0"; done
}

run_op_env() { OP_ENV_OP="$STUB" "$OP_ENV" "$@"; }

write_map() { printf '%s\n' "$1" > environments.json; }

assert_no_leftovers() {
    [ -z "$(ls -A "$TMPDIR")" ] || fail "$1: scratch files left in TMPDIR: $(ls -A "$TMPDIR")"
    [ -z "$(find . -name '.op-env.*')" ] || fail "$1: temporary output file left behind"
}

# --- pull from an Environment --------------------------------------------
new_workspace
# shellcheck disable=SC2016  # the literal $ is the point of this fixture
fixture envtraefik0001 "CF_DNS_API_TOKEN=abc123" "SPACED=two words" 'DOLLAR=pa$$word#1'
fixture envshared00001 "TZ=Europe/London" "DOMAIN=example.co.uk"
write_map '{"environments":{"production":{"_shared":{"environment":"envshared00001"},"traefik":{"environment":"envtraefik0001"}}}}'
export LEAK_ME=should-not-appear
run_op_env pull production 2>/dev/null
unset LEAK_ME
[ "$(stat -c %a traefik/.env)" = "600" ] || fail "traefik/.env is not mode 600"
[ "$(stat -c %a .env)" = "600" ] || fail ".env is not mode 600"
grep -qx 'CF_DNS_API_TOKEN=abc123' traefik/.env || fail "plain value not written raw"
grep -qx "SPACED='two words'" traefik/.env || fail "value with a space not single-quoted"
grep -qx "DOLLAR='pa\$\$word#1'" traefik/.env || fail "value with \$ and # not single-quoted literally"
grep -qx 'TZ=Europe/London' .env || fail "_shared did not write ./.env"
! grep -qE '^(STUB_INJECTED|LEAK_ME|PATH|HOME|OP_SERVICE_ACCOUNT_TOKEN)=' traefik/.env .env \
    || fail "baseline or caller variables leaked into a .env"
[ "$(wc -l < traefik/.env)" -eq 3 ] || fail "traefik/.env should hold exactly 3 variables"
assert_no_leftovers "pull"
pass "pull writes mode-600 files with only the Environment's variables, quoted safely"

# --- pull a single named stack -------------------------------------------
rm -f .env traefik/.env
run_op_env pull production traefik 2>/dev/null
if [ ! -f traefik/.env ] || [ -f .env ]; then fail "pull <env> <stack> wrote the wrong files"; fi
pass "pull <env> <stack> writes only that stack"

# --- several Environments merge, the last one wins -------------------------
new_workspace
fixture envshared00001 "TZ=Europe/London" "DOMAIN=example.co.uk" "LOG_LEVEL=info"
fixture envstack000001 "RABBITMQ_PASSWORD=s3cret" "LOG_LEVEL=debug"
write_map '{"environments":{"production":{"traefik":{"environment":["envshared00001","envstack000001"]}}}}'
run_op_env check 2>/dev/null || fail "check rejected a list of Environment IDs"
run_op_env pull production 2>/dev/null
grep -qx 'DOMAIN=example.co.uk' traefik/.env || fail "shared value missing from a merged .env"
grep -qx 'RABBITMQ_PASSWORD=s3cret' traefik/.env || fail "stack value missing from a merged .env"
grep -qx 'LOG_LEVEL=debug' traefik/.env || fail "the later Environment did not win on a clash"
[ "$(grep -c '^LOG_LEVEL=' traefik/.env)" -eq 1 ] || fail "a clashing variable was written twice"
write_map '{"environments":{"production":{"traefik":{"environment":[]}}}}'
if run_op_env check 2>/dev/null; then fail "check accepted an empty Environment list"; fi
write_map '{"environments":{"production":{"traefik":{"environment":["envshared00001", 7]}}}}'
if run_op_env check 2>/dev/null; then fail "check accepted a non-string in the Environment list"; fi
pass "a list of Environments merges into one .env, the last winning on a clash"

# --- refusals leave nothing behind ---------------------------------------
new_workspace
fixture envquote000001 "BAD=it's spaced"
write_map '{"environments":{"production":{"traefik":{"environment":"envquote000001"}}}}'
if run_op_env pull production 2>err.txt; then fail "a single quote plus a space was accepted"; fi
grep -q "BAD contains a single quote" err.txt || fail "refusal did not name the key"
! grep -q "it's spaced" err.txt || fail "refusal printed the secret value"
[ ! -f traefik/.env ] || fail "a refused pull still wrote traefik/.env"
assert_no_leftovers "single-quote refusal"
pass "a value env_file cannot hold is refused by key name, with no file or scratch left"

new_workspace
fixture envnewline0001 $'MULTI=line one\nline two'
write_map '{"environments":{"production":{"traefik":{"environment":"envnewline0001"}}}}'
if run_op_env pull production 2>err.txt; then fail "a multi-line value was accepted"; fi
grep -q "MULTI contains a newline" err.txt || fail "newline refusal did not name the key"
assert_no_leftovers "newline refusal"
pass "a multi-line value is refused"

new_workspace
write_map '{"environments":{"production":{"traefik":{"environment":"envmissing0001"}}}}'
if run_op_env pull production 2>err.txt; then fail "an unknown Environment ID was accepted"; fi
grep -qF "could not load 1Password Environment(s) envmissing0001" err.txt || fail "unknown ID error unclear"
assert_no_leftovers "unknown Environment"
pass "an Environment the token cannot read fails the pull"

new_workspace
fixture envempty000001
write_map '{"environments":{"production":{"traefik":{"environment":"envempty000001"}}}}'
if run_op_env pull production 2>/dev/null; then fail "an empty Environment was accepted"; fi
pass "an empty Environment fails the pull"

# --- templates ------------------------------------------------------------
new_workspace
printf 'op://docker-compose/metabase/MB_DB_PASS=s3cret\n' > "$OP_ENV_STUB_DIR/refs"
printf '# comment\nMB_DB_PASS={{ op://docker-compose/metabase/MB_DB_PASS }}\n' > metabase/.env.tpl
write_map '{"environments":{"production":{"metabase":{"template":"metabase/.env.tpl"}}}}'
run_op_env pull production 2>/dev/null
grep -qx 'MB_DB_PASS=s3cret' metabase/.env || fail "template was not injected"
[ "$(stat -c %a metabase/.env)" = "600" ] || fail "template output is not mode 600"
pass "template entries resolve with op inject"

printf 'MB_DB_PASS=plaintext-secret\n' > metabase/.env.tpl
if run_op_env check 2>/dev/null; then fail "check accepted a template with a plaintext value"; fi
pass "check rejects a template line that is not an op:// reference"

# --- check ----------------------------------------------------------------
new_workspace
write_map '{"environments":{"production":{"traefik":{"environment":"envtraefik0001","template":"x"}}}}'
if run_op_env check 2>/dev/null; then fail "check accepted an entry with both sources"; fi
write_map '{"environments":{"production":{"traefik":{"environment":"not an id!"}}}}'
if run_op_env check 2>/dev/null; then fail "check accepted a malformed Environment ID"; fi
write_map '{"environments":{"production":{"traefik":{}}}}'
if run_op_env check 2>/dev/null; then fail "check accepted an entry with no source"; fi
write_map '{"environments":{"production":{"traefik":{"environment":"envtraefik0001"}},"development":{"traefik":{"environment":"envtraefikdev1"}}}}'
run_op_env check 2>/dev/null || fail "check rejected a valid map"
pass "check validates entries without contacting 1Password"

# --- list, clean, output override ----------------------------------------
new_workspace
fixture envtraefik0001 "CF_DNS_API_TOKEN=abc123"
write_map '{"environments":{"production":{"traefik":{"environment":"envtraefik0001","output":"traefik/prod.env"}}}}'
run_op_env pull production 2>/dev/null
[ -f traefik/prod.env ] || fail "output override ignored"
run_op_env list production | grep -q 'traefik *environment *traefik/prod.env' || fail "list output wrong"
! run_op_env list production | grep -q abc123 || fail "list printed a secret"
run_op_env clean production 2>/dev/null
[ ! -f traefik/prod.env ] || fail "clean did not remove the file"
pass "output override, list (no secrets) and clean"

# --- secrets never appear in any process's arguments ----------------------
# Wrappers for every external command op-env could hand a value to log their
# argv; ps and /proc/*/cmdline expose argv to every user on the host.
new_workspace
SHIM="$WS/shim"; mkdir -p "$SHIM"
for tool in env grep jq; do
    real="$(command -v "$tool")"
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/argv.log"\nexec "%s" "$@"\n' \
        "$tool" "$OP_ENV_STUB_DIR" "$real" > "$SHIM/$tool"
    chmod +x "$SHIM/$tool"
done
fixture envtraefik0001 "CF_DNS_API_TOKEN=val-SENTINEL-456"
write_map '{"environments":{"production":{"traefik":{"environment":"envtraefik0001"}}}}'
OP_SERVICE_ACCOUNT_TOKEN=tok-SENTINEL-123 PATH="$SHIM:$PATH" run_op_env pull production 2>/dev/null
grep -qx 'CF_DNS_API_TOKEN=val-SENTINEL-456' traefik/.env || fail "argv test: pull did not write the value"
[ -s "$OP_ENV_STUB_DIR/argv.log" ] || fail "argv test: no commands were logged"
if grep -q SENTINEL "$OP_ENV_STUB_DIR/argv.log"; then fail "a secret or the token appeared in a process argument"; fi
pass "neither the token nor any secret value is passed as a process argument"

printf '\n%d passed\n' "$passed"
