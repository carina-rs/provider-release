#!/usr/bin/env bash

set -uo pipefail

export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
RELEASE_ASSETS="$REPO_ROOT/scripts/release-assets.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/release-assets-test.XXXXXX")
STUB_BIN="$TEST_ROOT/bin"
PROVIDER=carina-provider-test
WASM_ASSET="$PROVIDER-v1.2.3.wasm"
DOCS_ASSET="$PROVIDER-v1.2.3-docs.tar.gz"
CASE_NUMBER=0
FAILURES=0
RUN_STATUS=0
RUN_OUTPUT=

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash

set -euo pipefail

state_dir=${RELEASE_ASSETS_STUB_STATE_DIR:?}
printf '%s\n' "$*" >> "$state_dir/commands"
if [ "${1-}" != release ] || [ "$#" -lt 3 ]; then
  printf 'Unexpected gh command\n' >&2
  exit 2
fi
operation=$2
tag=$3
shift 3
repo=
json=
query=
pattern=
output=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --json) json=$2; shift 2 ;;
    --jq) query=$2; shift 2 ;;
    --pattern) pattern=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *)
      printf 'Unexpected gh argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ "$tag" != v1.2.3 ] || [ "$repo" != example/provider ]; then
  printf 'Expected the explicit tag and repository from the environment\n' >&2
  exit 2
fi

case "$operation" in
  view)
    if [ "$json" != assets ] || [ "$query" != '.assets[].name' ]; then
      printf 'Expected an asset name query\n' >&2
      exit 2
    fi
    if [ -s "$state_dir/view-error" ]; then
      cat "$state_dir/view-error" >&2
      exit 1
    fi
    cat "$state_dir/assets"
    ;;
  download)
    printf '%s\n' "$pattern" >> "$state_dir/downloads"
    if [ -s "$state_dir/download-error" ]; then
      cat "$state_dir/download-error" >&2
      exit 1
    fi
    cp -- "$state_dir/remote/$pattern" "$output"
    ;;
  *)
    printf 'Unexpected gh operation: %s\n' "$operation" >&2
    exit 2
    ;;
esac
STUB

chmod +x "$STUB_BIN/gh"

prepare_case() {
  CASE_NUMBER=$((CASE_NUMBER + 1))
  CASE_DIR="$TEST_ROOT/case-$CASE_NUMBER"
  mkdir -p "$CASE_DIR/local" "$CASE_DIR/remote"
  printf 'local wasm\n' > "$CASE_DIR/local/$WASM_ASSET"
  printf 'local docs\n' > "$CASE_DIR/local/$DOCS_ASSET"
  : > "$CASE_DIR/assets"
  : > "$CASE_DIR/commands"
  : > "$CASE_DIR/downloads"
  : > "$CASE_DIR/view-error"
  : > "$CASE_DIR/download-error"
}

run_release_assets() {
  RUN_OUTPUT=$(
    cd -- "$CASE_DIR/local" || exit 1
    shopt -s nullglob
    env \
      PATH="$STUB_BIN:$PATH" \
      RELEASE_ASSETS_STUB_STATE_DIR="$CASE_DIR" \
      GH_TOKEN=test-token \
      GITHUB_REF_NAME=v1.2.3 \
      GITHUB_REPOSITORY=example/provider \
      bash "$RELEASE_ASSETS" "${PROVIDER}-"*.wasm "${PROVIDER}-"*-docs.tar.gz 2>&1
  )
  RUN_STATUS=$?
}

assert_equal() {
  local expected=$1
  local actual=$2
  local message=$3

  if [ "$expected" != "$actual" ]; then
    printf '  assertion failed: %s\n  expected: %q\n  actual:   %q\n' \
      "$message" "$expected" "$actual" >&2
    return 1
  fi
}

assert_contains() {
  local value=$1
  local expected=$2
  local message=$3

  if [[ $value != *"$expected"* ]]; then
    printf '  assertion failed: %s\n  missing: %q\n  output:\n%s\n' \
      "$message" "$expected" "$value" >&2
    return 1
  fi
}

assert_not_contains() {
  local value=$1
  local unexpected=$2
  local message=$3

  if [[ $value == *"$unexpected"* ]]; then
    printf '  assertion failed: %s\n  unexpected: %q\n  output:\n%s\n' \
      "$message" "$unexpected" "$value" >&2
    return 1
  fi
}

test_no_release() {
  prepare_case
  printf 'release not found\n' > "$CASE_DIR/view-error"
  run_release_assets

  assert_equal 0 "$RUN_STATUS" 'a new release is allowed' || return 1
  assert_equal '' "$(< "$CASE_DIR/downloads")" 'no assets are downloaded' || return 1
  assert_equal "release view v1.2.3 --repo example/provider --json assets --jq .assets[].name" \
    "$(< "$CASE_DIR/commands")" 'the check only looks up the release' || return 1
}

test_missing_assets() {
  local assets

  for assets in '' unrelated.wasm; do
    prepare_case
    printf '%s\n' "$assets" > "$CASE_DIR/assets"
    run_release_assets

    assert_equal 0 "$RUN_STATUS" 'missing assets may be uploaded' || return 1
    assert_equal '' "$(< "$CASE_DIR/downloads")" 'missing assets are not downloaded' || return 1
    assert_equal 1 "$(wc -l < "$CASE_DIR/commands" | tr -d '[:space:]')" \
      'the check does not upload missing assets itself' || return 1
  done
}

test_identical_assets() {
  local asset

  prepare_case
  printf '%s\n' "$WASM_ASSET" "$DOCS_ASSET" > "$CASE_DIR/assets"
  for asset in "$WASM_ASSET" "$DOCS_ASSET"; do
    cp -- "$CASE_DIR/local/$asset" "$CASE_DIR/remote/$asset"
  done
  run_release_assets

  assert_equal 0 "$RUN_STATUS" 'identical assets succeed' || return 1
  assert_equal "$WASM_ASSET"$'\n'"$DOCS_ASSET" "$(< "$CASE_DIR/downloads")" \
    'both WASM and docs are compared' || return 1
  for asset in "$WASM_ASSET" "$DOCS_ASSET"; do
    assert_contains "$RUN_OUTPUT" "Asset $asset has identical SHA-256" \
      'identical assets are recognized' || return 1
  done
  assert_contains "$RUN_OUTPUT" 'leaving the existing asset in place' \
    'identical assets are kept' || return 1
  assert_equal 3 "$(wc -l < "$CASE_DIR/commands" | tr -d '[:space:]')" \
    'only one view and two downloads occur, without uploading' || return 1
}

test_differing_assets() {
  local asset
  local local_digest
  local existing_digest

  prepare_case
  printf '%s\n' "$WASM_ASSET" "$DOCS_ASSET" > "$CASE_DIR/assets"
  printf 'existing wasm\n' > "$CASE_DIR/remote/$WASM_ASSET"
  printf 'existing docs\n' > "$CASE_DIR/remote/$DOCS_ASSET"
  run_release_assets

  assert_equal 1 "$RUN_STATUS" 'differing assets fail the check' || return 1
  assert_equal "$WASM_ASSET"$'\n'"$DOCS_ASSET" "$(< "$CASE_DIR/downloads")" \
    'all assets are checked even after the first mismatch' || return 1
  for asset in "$WASM_ASSET" "$DOCS_ASSET"; do
    local_digest=$(sha256sum < "$CASE_DIR/local/$asset" | cut -d ' ' -f 1)
    existing_digest=$(sha256sum < "$CASE_DIR/remote/$asset" | cut -d ' ' -f 1)
    assert_contains "$RUN_OUTPUT" \
      "::error::Asset $asset differs: local SHA-256 $local_digest; existing SHA-256 $existing_digest." \
      'each mismatch names the asset and both digests' || return 1
  done
  assert_contains "$RUN_OUTPUT" \
    "The tag's assets were uploaded from an earlier build and are never replaced. Do not use 'Re-run all jobs' for a tag. If the registry already has this version, nothing needs to be done; otherwise cut a new version." \
    'the error explains asset immutability and how to recover from a whole-workflow re-run' || return 1
  assert_equal 3 "$(wc -l < "$CASE_DIR/commands" | tr -d '[:space:]')" \
    'no upload occurs when assets differ' || return 1
}

test_wasm_differs_docs_identical() {
  prepare_case
  printf '%s\n' "$WASM_ASSET" "$DOCS_ASSET" > "$CASE_DIR/assets"
  printf 'existing wasm\n' > "$CASE_DIR/remote/$WASM_ASSET"
  cp -- "$CASE_DIR/local/$DOCS_ASSET" "$CASE_DIR/remote/$DOCS_ASSET"
  run_release_assets

  assert_equal 1 "$RUN_STATUS" 'identical docs do not clear an earlier WASM mismatch' || return 1
  assert_equal "$WASM_ASSET"$'\n'"$DOCS_ASSET" "$(< "$CASE_DIR/downloads")" \
    'both assets are downloaded even when only WASM differs' || return 1
  assert_contains "$RUN_OUTPUT" "::error::Asset $WASM_ASSET differs:" \
    'the error identifies the differing WASM asset' || return 1
  assert_not_contains "$RUN_OUTPUT" "::error::Asset $DOCS_ASSET" \
    'identical docs do not produce an error' || return 1
  assert_contains "$RUN_OUTPUT" "Asset $DOCS_ASSET has identical SHA-256" \
    'docs are still compared after the WASM mismatch' || return 1
  assert_equal 3 "$(wc -l < "$CASE_DIR/commands" | tr -d '[:space:]')" \
    'no upload occurs when only WASM differs' || return 1
}

test_view_errors_fail() {
  local error

  for error in \
    'HTTP 403: Resource not accessible by integration' \
    'HTTP 500: Internal Server Error' \
    'could not connect to api.github.com' \
    'HTTP 500: release not found by upstream'; do
    prepare_case
    printf '%s\n' "$error" > "$CASE_DIR/view-error"
    run_release_assets

    assert_equal 1 "$RUN_STATUS" 'other gh errors fail closed' || return 1
    assert_contains "$RUN_OUTPUT" '::error::Failed to inspect release v1.2.3 in example/provider' \
      'lookup failures identify the release' || return 1
    assert_contains "$RUN_OUTPUT" "$error" 'the original gh error is preserved' || return 1
    assert_equal 1 "$(wc -l < "$CASE_DIR/commands" | tr -d '[:space:]')" \
      'lookup failures stop before any download or upload' || return 1
  done
}

test_download_errors_fail() {
  prepare_case
  printf '%s\n' "$WASM_ASSET" > "$CASE_DIR/assets"
  printf 'HTTP 502: Bad Gateway\n' > "$CASE_DIR/download-error"
  run_release_assets

  assert_equal 1 "$RUN_STATUS" 'a failed download fails closed' || return 1
  assert_contains "$RUN_OUTPUT" "::error::Failed to download existing release asset $WASM_ASSET" \
    'the download error identifies the asset' || return 1
  assert_contains "$RUN_OUTPUT" 'HTTP 502: Bad Gateway' 'the original download error is preserved' || return 1
  assert_equal 2 "$(wc -l < "$CASE_DIR/commands" | tr -d '[:space:]')" \
    'download failures stop before any upload' || return 1
}

run_test() {
  local description=$1
  local function_name=$2

  if "$function_name"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description"
    FAILURES=$((FAILURES + 1))
  fi
}

run_test 'no release allows initial uploads' test_no_release
run_test 'a release without matching assets allows uploads' test_missing_assets
run_test 'identical WASM and docs assets are kept' test_identical_assets
run_test 'all differing assets are reported before failing without uploads' test_differing_assets
run_test 'a WASM mismatch still fails when docs are identical' test_wasm_differs_docs_identical
run_test 'gh lookup errors other than release not found fail closed' test_view_errors_fail
run_test 'gh download errors fail closed' test_download_errors_fail

if [ "$FAILURES" -ne 0 ]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'All release asset tests passed\n'
