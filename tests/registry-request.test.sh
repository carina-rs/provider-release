#!/usr/bin/env bash

set -uo pipefail

export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
REGISTRY_REQUEST="$REPO_ROOT/scripts/registry-request.sh"
REAL_DATE=$(command -v date)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/registry-request-test.XXXXXX")
STUB_BIN="$TEST_ROOT/bin"
CASE_NUMBER=0
FAILURES=0
RUN_STATUS=0
RUN_OUTPUT=
PUBLISH_DEADLINE_HINT_PREFIX='Re-run only the failed publish job;'

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash

set -uo pipefail

state_dir=${REGISTRY_REQUEST_STUB_STATE_DIR:?}
clock_file=${REGISTRY_REQUEST_FAKE_CLOCK_FILE:?}
is_post=false
response_file=
max_time=
connect_timeout=
authorization=
request_url=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -X)
      if [ "${2-}" = POST ]; then
        is_post=true
      fi
      shift 2
      ;;
    -o)
      response_file=${2-}
      shift 2
      ;;
    --max-time)
      max_time=${2-}
      shift 2
      ;;
    --connect-timeout)
      connect_timeout=${2-}
      shift 2
      ;;
    -H)
      if [[ ${2-} == Authorization:* ]]; then
        authorization=${2-}
      fi
      shift 2
      ;;
    http://*|https://*)
      request_url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

next_count() {
  local name=$1
  local count=0

  if [ -s "$state_dir/$name-count" ]; then
    read -r count < "$state_dir/$name-count"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$state_dir/$name-count"
  printf '%s\n' "$count"
}

sequence_value() {
  local file=$1
  local index=$2
  local values=()

  mapfile -t values < "$file"
  if [ "${#values[@]}" -eq 0 ]; then
    printf 'stub sequence %s is empty\n' "$file" >&2
    exit 2
  fi
  if [ "$index" -le "${#values[@]}" ]; then
    printf '%s\n' "${values[index - 1]}"
  else
    printf '%s\n' "${values[${#values[@]} - 1]}"
  fi
}

if $is_post; then
  count=$(next_count post)
  read -r started_at < "$clock_file"
  printf '%s\n' "$started_at" >> "$state_dir/post-starts"
  printf '%s\n' "$max_time" >> "$state_dir/post-max-times"
  printf '%s\n' "$connect_timeout" >> "$state_dir/post-connect-timeouts"
  printf '%s\n' "$authorization" >> "$state_dir/post-authorizations"
  printf '%s\n' "$request_url" >> "$state_dir/post-urls"
  result=$(sequence_value "$state_dir/post-results" "$count")
  if [ -f "$state_dir/post-response-body" ]; then
    response_body=$(< "$state_dir/post-response-body")
    printf '%s\n' "$response_body" > "$response_file"
  else
    printf 'response-%s-attempt-%s\n' "$result" "$count" > "$response_file"
  fi
  case "$result" in
    000)
      printf '000'
      exit 7
      ;;
    *-exit28)
      printf '%s' "${result%-exit28}"
      exit 28
      ;;
  esac
  printf '%s' "$result"
  exit 0
fi

count=$(next_count token)
read -r started_at < "$clock_file"
printf '%s\n' "$started_at" >> "$state_dir/token-starts"
printf '%s\n' "$max_time" >> "$state_dir/token-max-times"
printf '%s\n' "$connect_timeout" >> "$state_dir/token-connect-timeouts"
result=$(sequence_value "$state_dir/token-results" "$count")
case "$result" in
  ok|ok+*)
    if [ "$result" != ok ]; then
      advance_seconds=${result#ok+}
      if [[ ! $advance_seconds =~ ^[0-9]+$ ]]; then
        printf 'unsupported token clock advance: %s\n' "$advance_seconds" >&2
        exit 2
      fi
      printf '%s\n' "$((started_at + advance_seconds))" > "$clock_file"
    fi
    printf '{"value":"token-%s"}\n' "$count"
    ;;
  fail)
    exit 7
    ;;
  empty)
    printf '{"value":""}\n'
    ;;
  *)
    printf 'unsupported token stub result: %s\n' "$result" >&2
    exit 2
    ;;
esac
STUB

cat > "$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash

set -uo pipefail

state_dir=${REGISTRY_REQUEST_STUB_STATE_DIR:?}
clock_file=${REGISTRY_REQUEST_FAKE_CLOCK_FILE:?}
duration=${1:?}
read -r started_at < "$clock_file"
printf '%s\n' "$duration" >> "$state_dir/sleeps"
printf '%s\n' "$started_at" >> "$state_dir/sleep-starts"
printf '%s\n' "$((started_at + duration))" > "$clock_file"
STUB

cat > "$STUB_BIN/date" <<'STUB'
#!/usr/bin/env bash

set -uo pipefail

if [ "$#" -eq 1 ] && [ "$1" = +%s ]; then
  IFS= read -r timestamp < "${REGISTRY_REQUEST_FAKE_CLOCK_FILE:?}"
  printf '%s\n' "$timestamp"
  exit 0
fi

exec "${REGISTRY_REQUEST_REAL_DATE:?}" "$@"
STUB

chmod +x "$STUB_BIN/curl" "$STUB_BIN/date" "$STUB_BIN/sleep"

date_to_epoch() {
  local value=$1
  local epoch

  if epoch=$(date -u -d "$value" +%s 2>/dev/null); then
    printf '%s\n' "$epoch"
    return
  fi
  date -j -u -f '%b %e %T %Y %Z' "$value" +%s
}

epoch_to_iso8601() {
  local epoch=$1
  local value

  if value=$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
    printf '%s\n' "$value"
    return
  fi
  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

make_certificate() {
  local name=$1
  local days=$2
  local prefix=$3
  local not_after
  local raw_bytes

  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -subj "/CN=$name" \
    -days "$days" \
    -keyout "$TEST_ROOT/$name.key" \
    -out "$TEST_ROOT/$name.pem" >/dev/null 2>&1 || return 1
  openssl x509 \
    -in "$TEST_ROOT/$name.pem" \
    -outform DER \
    -out "$TEST_ROOT/$name.der" || return 1
  raw_bytes=$(base64 < "$TEST_ROOT/$name.der" | tr -d '\r\n')
  not_after=$(openssl x509 -in "$TEST_ROOT/$name.pem" -noout -enddate)
  not_after=${not_after#notAfter=}

  printf -v "${prefix}_RAW" '%s' "$raw_bytes"
  printf -v "${prefix}_NOT_AFTER" '%s' "$not_after"
  printf -v "${prefix}_EPOCH" '%s' "$(date_to_epoch "$not_after")"
}

if ! make_certificate early 1 EARLY_CERT || ! make_certificate late 2 LATE_CERT; then
  printf 'Failed to generate test certificates\n' >&2
  exit 1
fi

main_bundle_payload() {
  jq -cn --arg raw "$1" '{
    sigstore_bundle: {
      verificationMaterial: {
        certificate: {rawBytes: $raw}
      }
    }
  }'
}

payload_with_docs_chain() {
  jq -cn --arg main "$1" --arg docs "$2" '{
    sigstore_bundle: {
      verificationMaterial: {
        certificate: {rawBytes: $main}
      }
    },
    docs: {
      sigstore_bundle: {
        verificationMaterial: {
          x509CertificateChain: {
            certificates: [{rawBytes: $docs}]
          }
        }
      }
    }
  }'
}

prepare_case() {
  local initial_time=$1
  shift

  CASE_NUMBER=$((CASE_NUMBER + 1))
  CASE_DIR="$TEST_ROOT/case-$CASE_NUMBER"
  CLOCK_FILE="$CASE_DIR/clock"
  mkdir -p "$CASE_DIR"
  printf '%s\n' "$initial_time" > "$CLOCK_FILE"
  printf '%s\n' "$@" > "$CASE_DIR/post-results"
  printf 'ok\n' > "$CASE_DIR/token-results"
  : > "$CASE_DIR/post-starts"
  : > "$CASE_DIR/post-max-times"
  : > "$CASE_DIR/post-connect-timeouts"
  : > "$CASE_DIR/post-authorizations"
  : > "$CASE_DIR/post-urls"
  : > "$CASE_DIR/token-starts"
  : > "$CASE_DIR/token-max-times"
  : > "$CASE_DIR/token-connect-timeouts"
  : > "$CASE_DIR/sleeps"
  : > "$CASE_DIR/sleep-starts"
}

set_token_results() {
  printf '%s\n' "$@" > "$CASE_DIR/token-results"
}

set_post_response_body() {
  printf '%s\n' "$1" > "$CASE_DIR/post-response-body"
}

run_registry_request() {
  local operation=$1
  local payload=$2

  RUN_OUTPUT=$(env \
    LC_ALL=C \
    PATH="$STUB_BIN:$PATH" \
    REGISTRY_REQUEST_FAKE_CLOCK_FILE="$CLOCK_FILE" \
    REGISTRY_REQUEST_REAL_DATE="$REAL_DATE" \
    REGISTRY_REQUEST_STUB_STATE_DIR="$CASE_DIR" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token \
    ACTIONS_ID_TOKEN_REQUEST_URL='https://token.example.test?id=1' \
    REGISTRY_AUDIENCE=registry.example.test \
    REGISTRY_PUBLISH_URL=https://registry.example.test/publish \
    REGISTRY_YANK_URL=https://registry.example.test/yank \
    bash "$REGISTRY_REQUEST" request "$operation" "$payload" 2>&1)
  RUN_STATUS=$?
}

run_publish_error_response() {
  local status=$1
  local response_body=$2
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" "$status"
  set_post_response_body "$response_body"
  run_registry_request Publish "$payload"
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

assert_post_starts_at_or_before() {
  local deadline=$1
  local started_at

  while IFS= read -r started_at; do
    if [ "$started_at" -gt "$deadline" ]; then
      printf '  assertion failed: POST started at %s after deadline %s\n' \
        "$started_at" "$deadline" >&2
      return 1
    fi
  done < "$CASE_DIR/post-starts"
}

test_429_backoff_then_201() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 429 429 429 201
  run_registry_request Publish "$payload"

  assert_equal 0 "$RUN_STATUS" '429 retries eventually succeed' || return 1
  assert_equal 4 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'four POSTs were made' || return 1
  assert_equal 4 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" 'each attempt fetched a token' || return 1
  assert_equal $'10\n20\n30' "$(< "$CASE_DIR/sleeps")" 'retry backoff is capped progression' || return 1
  assert_equal 130 "$(sort -u "$CASE_DIR/post-max-times")" 'every POST uses a 130s max time' || return 1
  assert_equal 60 "$(sort -u "$CASE_DIR/token-max-times")" 'every token request uses a 60s max time' || return 1
  assert_equal 10 "$(sort -u "$CASE_DIR/post-connect-timeouts")" 'every POST uses a 10s connect timeout' || return 1
  assert_equal 10 "$(sort -u "$CASE_DIR/token-connect-timeouts")" 'every token request uses a 10s connect timeout' || return 1
  assert_equal $'Authorization: Bearer token-1\nAuthorization: Bearer token-2\nAuthorization: Bearer token-3\nAuthorization: Bearer token-4' \
    "$(< "$CASE_DIR/post-authorizations")" 'every POST uses a fresh token' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 1 returned HTTP 429' 'attempt status is printed' || return 1
  assert_contains "$RUN_OUTPUT" '  response-429-attempt-1' 'response body is indented' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 4 returned HTTP 201' 'successful status is printed' || return 1
}

test_deadline_stops_429_retries() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 15))
  local deadline_iso

  deadline_iso=$(epoch_to_iso8601 "$deadline") || return 1
  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 429
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'deadline exhaustion fails' || return 1
  assert_equal 3 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'attempt at the deadline is the last attempt' || return 1
  assert_equal $'10\n5' "$(< "$CASE_DIR/sleeps")" 'sleep is capped at the deadline' || return 1
  assert_post_starts_at_or_before "$deadline" || return 1
  assert_contains "$RUN_OUTPUT" 'Publish failed after 3 attempts' 'failure states attempt count' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: 429' 'failure states last status' || return 1
  assert_contains "$RUN_OUTPUT" "$deadline_iso" 'failure states UTC deadline' || return 1
  assert_contains "$RUN_OUTPUT" 'notAfter' 'failure explains certificate deadline' || return 1
  assert_contains "$RUN_OUTPUT" '120s registry verification margin' \
    'failure explains verification margin' || return 1
  assert_contains "$RUN_OUTPUT" "$PUBLISH_DEADLINE_HINT_PREFIX" \
    'publish deadline failure explains how to retry safely' || return 1
  assert_not_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    '429 does not imply an ambiguous registry commit' || return 1
}

test_5xx_and_transport_errors_retry() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 500 000 503 201
  run_registry_request Publish "$payload"

  assert_equal 0 "$RUN_STATUS" '5xx and transport errors eventually succeed' || return 1
  assert_equal 4 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'all retryable statuses were retried' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 1 returned HTTP 500' '500 is reported' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 2 returned HTTP 000' 'transport error is reported as 000' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 3 returned HTTP 503' '503 is reported' || return 1
}

test_http_code_from_timed_out_post_is_transport_error() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 10))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 503-exit28 200-exit28
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'a timeout after HTTP response headers fails at the deadline' || return 1
  assert_equal 2 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'the timed-out 503 is retried' || return 1
  assert_equal 10 "$(< "$CASE_DIR/sleeps")" 'the timed-out 503 uses retry backoff' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 1 returned HTTP 000' \
    'a 503 followed by curl exit 28 is reported as a transport error' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 2 returned HTTP 000' \
    'a 200 followed by curl exit 28 is not treated as success' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: 000' \
    'the deadline failure retains the transport status' || return 1
  assert_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    'the deadline failure warns about an ambiguous commit' || return 1
}

test_400_fails_immediately() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 400 201
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" '400 fails' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" '400 is not retried' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/sleeps" | tr -d '[:space:]')" '400 does not sleep' || return 1
}

test_unexpected_statuses_fail_immediately() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))
  local status

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  for status in 302 204; do
    prepare_case "$initial_time" "$status" 201
    run_registry_request Publish "$payload"

    assert_equal 1 "$RUN_STATUS" "unexpected HTTP $status fails" || return 1
    assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" \
      "unexpected HTTP $status makes one POST" || return 1
    assert_equal 0 "$(wc -l < "$CASE_DIR/sleeps" | tr -d '[:space:]')" \
      "unexpected HTTP $status is not retried" || return 1
    assert_contains "$RUN_OUTPUT" "Publish failed with unexpected status $status" \
      "HTTP $status reaches the unexpected-status branch" || return 1
  done
}

assert_publish_error_hint() {
  local expected_hint_prefix=$1
  local context=$2

  assert_equal 1 "$RUN_STATUS" "$context fails" || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" "$context is not retried" || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/sleeps" | tr -d '[:space:]')" "$context does not sleep" || return 1
  assert_contains "$RUN_OUTPUT" "$expected_hint_prefix" "$context prints the expected hint" || return 1
  assert_equal 1 "$(grep -c '^Hint:' <<< "$RUN_OUTPUT")" "$context prints one hint line"
}

test_publish_error_hints() {
  local cases=(
    '403|{"error":"provider_frozen","detail":"provider_tombstoned","message":"version_forbidden"}|Hint: not a config problem:|provider_frozen 403|Hint: check release-tag-environment mode|'
    '403|{"error":"provider_tombstoned","detail":"provider_frozen"}|Hint: the name is permanently closed.|provider_tombstoned 403|Hint: not a config problem:|'
    '403|{"error":"version_forbidden","detail":"provider_frozen"}|Hint: the tag must be exactly v<version>.|version_forbidden 403|Hint: not a config problem:|'
    '403|{"error":"claim_mismatch","detail":"provider_frozen"}|Hint: check release-tag-environment mode|claim_mismatch 403|Hint: not a config problem:|'
    '403|{"error":"future_registry_error","detail":"provider_frozen","message":"provider_tombstoned"}|Hint: check release-tag-environment mode|unknown-code 403|Hint: not a config problem:|'
    '403|{"detail":"provider_frozen","message":"provider_tombstoned"}|Hint: check release-tag-environment mode|missing-error 403|Hint: not a config problem:|'
    '403|provider_frozen: response was not JSON|Hint: check release-tag-environment mode|non-JSON 403|Hint: not a config problem:|'
    '409|{"error":"version_conflict","detail":"docs_signer_mismatch_recorded"}|Hint: the version exists with different bytes (often because|version_conflict 409|Hint: a previous attempt was interrupted|'
    '409|{"error":"docs_signer_mismatch_recorded","detail":"version_conflict"}|Hint: a previous attempt was interrupted|docs_signer_mismatch_recorded 409|Hint: the version exists with different bytes (often because|'
    '409|{"error":"future_registry_error","detail":"version_conflict","message":"docs_signer_mismatch_recorded"}|Hint: the version exists with different bytes;|unknown-code 409|Hint: the version exists with different bytes (often because|Hint: a previous attempt was interrupted'
    '409|{"detail":"version_conflict","message":"docs_signer_mismatch_recorded"}|Hint: the version exists with different bytes;|missing-error 409|Hint: the version exists with different bytes (often because|Hint: a previous attempt was interrupted'
    '409|version_conflict docs_signer_mismatch_recorded: response was not JSON|Hint: the version exists with different bytes;|non-JSON 409|Hint: the version exists with different bytes (often because|Hint: a previous attempt was interrupted'
  )
  local test_case
  local status
  local response_body
  local expected_hint_prefix
  local context
  local unexpected_hint_prefix
  local second_unexpected_hint_prefix

  for test_case in "${cases[@]}"; do
    IFS='|' read -r status response_body expected_hint_prefix context \
      unexpected_hint_prefix second_unexpected_hint_prefix <<< "$test_case"
    run_publish_error_response "$status" "$response_body" || return 1
    assert_publish_error_hint "$expected_hint_prefix" "$context" || return 1
    if [ -n "$unexpected_hint_prefix" ]; then
      assert_not_contains "$RUN_OUTPUT" "$unexpected_hint_prefix" \
        "$context ignores non-.error fields" || return 1
    fi
    if [ -n "$second_unexpected_hint_prefix" ]; then
      assert_not_contains "$RUN_OUTPUT" "$second_unexpected_hint_prefix" \
        "$context ignores non-.error fields" || return 1
    fi
  done
}

test_yank_409_omits_publish_content_conflict_hint() {
  local initial_time=2000000000

  prepare_case "$initial_time" 409
  run_registry_request Yank '{}'

  assert_equal 1 "$RUN_STATUS" 'yank 409 fails' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'yank 409 is not retried' || return 1
  assert_not_contains "$RUN_OUTPUT" 'Hint:' \
    'yank 409 does not print a publish-only hint' || return 1
}

test_200_succeeds() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 200
  run_registry_request Publish "$payload"

  assert_equal 0 "$RUN_STATUS" 'idempotent 200 succeeds' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" '200 needs one POST' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 1 returned HTTP 200' '200 is reported' || return 1
}

test_token_failure_retries() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 201
  set_token_results fail ok
  run_registry_request Publish "$payload"

  assert_equal 0 "$RUN_STATUS" 'token failure is retried' || return 1
  assert_equal 2 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" 'token was fetched again' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'failed token attempt did not POST' || return 1
  assert_equal 10 "$(< "$CASE_DIR/sleeps")" 'token failure uses retry backoff' || return 1
  assert_contains "$RUN_OUTPUT" 'Failed to obtain OIDC token on attempt 1' 'token failure is reported' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 2 returned HTTP 201' 'next overall attempt succeeds' || return 1
}

test_empty_token_retries_without_post() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 201
  set_token_results empty ok
  run_registry_request Publish "$payload"

  assert_equal 0 "$RUN_STATUS" 'an empty token value is retried' || return 1
  assert_equal 2 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" \
    'an empty token value triggers a fresh token request' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" \
    'an empty token value does not trigger a POST' || return 1
  assert_equal 'Authorization: Bearer token-2' "$(< "$CASE_DIR/post-authorizations")" \
    'the only POST uses the replacement token' || return 1
  assert_equal 10 "$(< "$CASE_DIR/sleeps")" 'an empty token value uses retry backoff' || return 1
  assert_contains "$RUN_OUTPUT" 'Failed to obtain OIDC token on attempt 1' \
    'an empty token value is reported as a token failure' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 2 returned HTTP 201' \
    'the retry after an empty token succeeds' || return 1
}

test_token_fetch_past_deadline_prevents_post() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 1))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 201
  set_token_results ok+60
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'token fetch that crosses the deadline fails' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" 'pre-loop deadline check allowed the token request' || return 1
  assert_equal "$initial_time" "$(< "$CASE_DIR/token-starts")" 'token request started one second before the deadline' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'post-token deadline check prevents POST' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/sleeps" | tr -d '[:space:]')" 'post-token deadline failure does not retry' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: deadline reached after OIDC token fetch' \
    'failure identifies the post-token deadline check' || return 1
}

test_5xx_then_token_failure_warns_about_ambiguous_commit() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 10))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 503
  set_token_results ok fail
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'token failure at the deadline fails' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'only the earlier 503 POST was made' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: OIDC token failure' \
    'failure summary reports the token failure' || return 1
  assert_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    'failure retains the warning from the earlier 503 POST' || return 1
}

test_5xx_then_slow_token_fetch_warns_about_ambiguous_commit() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 10))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 503
  set_token_results ok ok+60
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'slow token fetch crossing the deadline fails' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'only the earlier 503 POST was made' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: deadline reached after OIDC token fetch' \
    'failure summary reports the post-token deadline' || return 1
  assert_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    'failure retains the warning from the earlier 503 POST' || return 1
}

test_retry_attempt_can_start_at_deadline() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 10))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 429 201
  run_registry_request Publish "$payload"

  assert_equal 0 "$RUN_STATUS" 'retry landing exactly on the deadline succeeds' || return 1
  assert_equal "$initial_time" "$(head -n 1 "$CASE_DIR/post-starts")" 'first attempt starts before the deadline' || return 1
  assert_equal "$deadline" "$(tail -n 1 "$CASE_DIR/post-starts")" 'second attempt starts exactly at the deadline' || return 1
  assert_equal 2 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'exact-deadline retry makes the second POST' || return 1
  assert_equal 10 "$(< "$CASE_DIR/sleeps")" 'retry sleep may end exactly at the deadline' || return 1
  assert_contains "$RUN_OUTPUT" 'Publish attempt 2 returned HTTP 201' 'exact-deadline attempt succeeds' || return 1
}

test_transport_deadline_warns_before_rerun() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$deadline" 000
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'transport error at the deadline fails' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'transport error at the deadline is not retried' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/sleeps" | tr -d '[:space:]')" 'transport error at the deadline does not sleep' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: 000' 'deadline failure reports the transport status' || return 1
  assert_contains "$RUN_OUTPUT" "$PUBLISH_DEADLINE_HINT_PREFIX" \
    'transport deadline failure explains how to retry the publish' || return 1
  assert_contains "$RUN_OUTPUT" \
    'The last attempt may have committed on the registry.' \
    'transport deadline failure warns about an ambiguous commit' || return 1
}

test_publish_5xx_deadline_warns_about_ambiguous_commit() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$deadline" 503
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'publish 5xx at the deadline fails' || return 1
  assert_equal 1 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'publish 5xx at the deadline is not retried' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: 503' 'deadline failure reports the 5xx status' || return 1
  assert_contains "$RUN_OUTPUT" "$PUBLISH_DEADLINE_HINT_PREFIX" \
    '5xx deadline failure explains how to retry the publish' || return 1
  assert_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    'publish 5xx deadline failure warns about an ambiguous commit' || return 1
}

test_docs_earlier_not_after_sets_deadline() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 15))
  local deadline_iso

  deadline_iso=$(epoch_to_iso8601 "$deadline") || return 1
  payload=$(payload_with_docs_chain "$LATE_CERT_RAW" "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 429
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'docs certificate deadline is enforced' || return 1
  assert_equal 3 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'earlier docs deadline limits attempts' || return 1
  assert_post_starts_at_or_before "$deadline" || return 1
  assert_contains "$RUN_OUTPUT" "$deadline_iso" 'docs notAfter determines the deadline' || return 1
}

test_missing_certificate_fails_before_post() {
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  prepare_case "$initial_time" 201
  run_registry_request Publish '{"sigstore_bundle":{}}'

  assert_equal 1 "$RUN_STATUS" 'missing certificate fails' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'missing certificate prevents POST' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" 'missing certificate prevents token request' || return 1
  assert_contains "$RUN_OUTPUT" '.sigstore_bundle' 'error names the invalid bundle' || return 1
  assert_contains "$RUN_OUTPUT" 'readable leaf certificate' 'error explains certificate failure' || return 1
  assert_contains "$RUN_OUTPUT" \
    "Re-running won't help; the bundle format may have changed. Report it to carina-rs/provider-release." \
    'certificate error explains that rerunning cannot fix a format change' || return 1
}

test_unparseable_certificate_fails_before_post() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload 'bm90LWEtdmFsaWQtZGVy') || return 1
  prepare_case "$initial_time" 201
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'unparseable certificate fails' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'unparseable certificate prevents POST' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" 'unparseable certificate prevents token request' || return 1
  assert_contains "$RUN_OUTPUT" '.sigstore_bundle' 'error names the unparseable bundle' || return 1
  assert_contains "$RUN_OUTPUT" 'readable leaf certificate' 'error explains parse failure' || return 1
  assert_contains "$RUN_OUTPUT" \
    "Re-running won't help; the bundle format may have changed. Report it to carina-rs/provider-release." \
    'parse error explains that rerunning cannot fix a format change' || return 1
}

test_missing_docs_certificate_fails_before_post() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(jq -cn --arg main "$EARLY_CERT_RAW" '{
    sigstore_bundle: {
      verificationMaterial: {
        certificate: {rawBytes: $main}
      }
    },
    docs: {sigstore_bundle: {}}
  }') || return 1
  prepare_case "$initial_time" 201
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'missing docs certificate fails' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'missing docs certificate prevents POST' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" 'missing docs certificate prevents token request' || return 1
  assert_contains "$RUN_OUTPUT" '.docs.sigstore_bundle' 'error names the invalid docs bundle' || return 1
  assert_contains "$RUN_OUTPUT" 'readable leaf certificate' 'docs error explains certificate failure' || return 1
  assert_contains "$RUN_OUTPUT" \
    "Re-running won't help; the bundle format may have changed. Report it to carina-rs/provider-release." \
    'docs certificate error explains that rerunning cannot fix a format change' || return 1
}

test_expired_publish_deadline_fails_before_attempt() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline + 1))
  local deadline_iso
  local not_after_iso

  deadline_iso=$(epoch_to_iso8601 "$deadline") || return 1
  not_after_iso=$(epoch_to_iso8601 "$EARLY_CERT_EPOCH") || return 1
  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 201
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'past publish deadline fails' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'past deadline prevents POST' || return 1
  assert_equal 0 "$(wc -l < "$CASE_DIR/token-starts" | tr -d '[:space:]')" 'past deadline prevents token request' || return 1
  assert_contains "$RUN_OUTPUT" \
    "Publish failed after 0 attempts (last status: not attempted): retry deadline $deadline_iso has already passed before the first attempt; it is the earliest bundle certificate notAfter $not_after_iso minus the 120s registry verification margin" \
    'past-deadline failure uses the zero-attempt wording' || return 1
  assert_contains "$RUN_OUTPUT" 'notAfter' 'past-deadline error names notAfter' || return 1
  assert_contains "$RUN_OUTPUT" "$not_after_iso" 'past-deadline error names certificate expiry' || return 1
  assert_contains "$RUN_OUTPUT" "$PUBLISH_DEADLINE_HINT_PREFIX" \
    'zero-attempt publish deadline failure still explains what to do' || return 1
  assert_not_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    'zero-attempt publish failure does not imply an ambiguous commit' || return 1
}

test_yank_uses_ten_minute_deadline() {
  local initial_time=2000000000
  local deadline=$((initial_time + 600))
  local deadline_iso

  deadline_iso=$(epoch_to_iso8601 "$deadline") || return 1
  prepare_case "$initial_time" 429
  run_registry_request Yank '{}'

  assert_equal 1 "$RUN_STATUS" 'yank deadline exhaustion fails' || return 1
  assert_equal 22 "$(wc -l < "$CASE_DIR/post-starts" | tr -d '[:space:]')" 'yank retries through its ten-minute deadline' || return 1
  assert_equal "$deadline" "$(tail -n 1 "$CASE_DIR/post-starts")" 'last yank attempt starts at deadline' || return 1
  assert_post_starts_at_or_before "$deadline" || return 1
  assert_contains "$RUN_OUTPUT" 'Yank failed after 22 attempts' 'yank summary states attempt count' || return 1
  assert_contains "$RUN_OUTPUT" "$deadline_iso" 'yank summary states UTC deadline' || return 1
  assert_contains "$RUN_OUTPUT" '600s Yank retry window' \
    'yank summary explains its retry window' || return 1
  assert_contains "$RUN_OUTPUT" \
    'Re-run the failed yank job; yanking an already-yanked version succeeds.' \
    'yank deadline failure explains how to retry safely' || return 1
  assert_not_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    '429 does not imply an ambiguous registry commit' || return 1
}

test_yank_transport_deadline_warns_about_ambiguous_commit() {
  local initial_time=2000000000

  prepare_case "$initial_time" 000
  run_registry_request Yank '{}'

  assert_equal 1 "$RUN_STATUS" 'yank transport retries stop at the deadline' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: 000' 'yank deadline failure reports the transport status' || return 1
  assert_contains "$RUN_OUTPUT" \
    'Re-run the failed yank job; yanking an already-yanked version succeeds.' \
    'yank transport deadline failure explains how to retry' || return 1
  assert_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    'yank transport deadline failure warns about an ambiguous commit' || return 1
}

test_yank_5xx_deadline_warns_about_ambiguous_commit() {
  local initial_time=2000000000

  prepare_case "$initial_time" 503
  run_registry_request Yank '{}'

  assert_equal 1 "$RUN_STATUS" 'yank 5xx retries stop at the deadline' || return 1
  assert_contains "$RUN_OUTPUT" 'last status: 503' 'yank deadline failure reports the 5xx status' || return 1
  assert_contains "$RUN_OUTPUT" \
    'Re-run the failed yank job; yanking an already-yanked version succeeds.' \
    'yank 5xx deadline failure explains how to retry' || return 1
  assert_contains "$RUN_OUTPUT" 'The last attempt may have committed on the registry.' \
    'yank 5xx deadline failure warns about an ambiguous commit' || return 1
}

test_operations_post_to_their_configured_urls() {
  local payload
  local initial_time=$((EARLY_CERT_EPOCH - 120 - 300))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 201
  run_registry_request Publish "$payload"

  assert_equal 0 "$RUN_STATUS" 'publish URL routing request succeeds' || return 1
  assert_equal 'https://registry.example.test/publish' "$(< "$CASE_DIR/post-urls")" \
    'Publish posts to REGISTRY_PUBLISH_URL' || return 1

  prepare_case "$initial_time" 200
  run_registry_request Yank '{}'

  assert_equal 0 "$RUN_STATUS" 'yank URL routing request succeeds' || return 1
  assert_equal 'https://registry.example.test/yank' "$(< "$CASE_DIR/post-urls")" \
    'Yank posts to REGISTRY_YANK_URL' || return 1
}

test_sleep_never_exceeds_remaining_time() {
  local payload
  local deadline=$((EARLY_CERT_EPOCH - 120))
  local initial_time=$((deadline - 25))

  payload=$(main_bundle_payload "$EARLY_CERT_RAW") || return 1
  prepare_case "$initial_time" 429
  run_registry_request Publish "$payload"

  assert_equal 1 "$RUN_STATUS" 'short remaining window eventually fails' || return 1
  assert_equal $'10\n15' "$(< "$CASE_DIR/sleeps")" 'second sleep is capped to remaining 15 seconds' || return 1
  assert_equal "$deadline" "$(tail -n 1 "$CASE_DIR/post-starts")" 'capped sleep lands on deadline' || return 1
  assert_post_starts_at_or_before "$deadline" || return 1
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

run_test '429 uses capped backoff and can reach 201' test_429_backoff_then_201
run_test '429 retries stop at the certificate deadline' test_deadline_stops_429_retries
run_test '5xx and transport errors are retried' test_5xx_and_transport_errors_retry
run_test 'HTTP output followed by curl exit 28 remains a transport error' test_http_code_from_timed_out_post_is_transport_error
run_test '400 fails after one POST' test_400_fails_immediately
run_test '302 and 204 fail through the unexpected-status branch' test_unexpected_statuses_fail_immediately
run_test 'Publish 403/409 responses select hints from .error' test_publish_error_hints
run_test 'Yank 409 omits the publish content-conflict hint' test_yank_409_omits_publish_content_conflict_hint
run_test '200 is successful' test_200_succeeds
run_test 'OIDC token failures are retried with a fresh token' test_token_failure_retries
run_test 'an empty OIDC token is retried without an empty-bearer POST' test_empty_token_retries_without_post
run_test 'a token fetch crossing the deadline prevents POST' test_token_fetch_past_deadline_prevents_post
run_test 'a token failure after HTTP 5xx retains the ambiguous-commit warning' test_5xx_then_token_failure_warns_about_ambiguous_commit
run_test 'a slow token fetch after HTTP 5xx retains the ambiguous-commit warning' test_5xx_then_slow_token_fetch_warns_about_ambiguous_commit
run_test 'a retry attempt may start exactly at the deadline' test_retry_attempt_can_start_at_deadline
run_test 'a deadline after HTTP 000 warns before re-running' test_transport_deadline_warns_before_rerun
run_test 'a Publish deadline after HTTP 5xx warns about an ambiguous commit' test_publish_5xx_deadline_warns_about_ambiguous_commit
run_test 'the earlier docs certificate controls the deadline' test_docs_earlier_not_after_sets_deadline
run_test 'a missing leaf certificate fails before any request' test_missing_certificate_fails_before_post
run_test 'an unparseable leaf certificate fails before any request' test_unparseable_certificate_fails_before_post
run_test 'a present docs bundle must contain a readable certificate' test_missing_docs_certificate_fails_before_post
run_test 'an already-past publish deadline fails before any request' test_expired_publish_deadline_fails_before_attempt
run_test 'yank retries for ten minutes' test_yank_uses_ten_minute_deadline
run_test 'a Yank deadline after HTTP 000 warns about an ambiguous commit' test_yank_transport_deadline_warns_about_ambiguous_commit
run_test 'a Yank deadline after HTTP 5xx warns about an ambiguous commit' test_yank_5xx_deadline_warns_about_ambiguous_commit
run_test 'Publish and Yank post to their operation-specific URLs' test_operations_post_to_their_configured_urls
run_test 'sleep is capped by the remaining deadline' test_sleep_never_exceeds_remaining_time

if [ "$FAILURES" -ne 0 ]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'All registry request tests passed\n'
