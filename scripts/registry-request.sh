#!/usr/bin/env bash

set -euo pipefail

readonly PUBLISH_CERTIFICATE_MARGIN_SECONDS=120
readonly YANK_RETRY_WINDOW_SECONDS=600
readonly RETRY_BACKOFF_START_SECONDS=10
readonly RETRY_BACKOFF_STEP_SECONDS=10
readonly RETRY_BACKOFF_MAX_SECONDS=30

now() {
  date +%s
}

can_start_by() {
  local deadline=$1
  local candidate_time=$2

  [ "$candidate_time" -le "$deadline" ]
}

certificate_date_to_epoch() {
  local certificate_date=$1
  local timestamp

  if timestamp=$(LC_ALL=C date -u -d "$certificate_date" +%s 2>/dev/null); then
    printf '%s\n' "$timestamp"
    return
  fi

  # BSD date fallback keeps local development and tests portable; Ubuntu uses
  # the GNU date branch above.
  LC_ALL=C date -j -u -f '%b %e %T %Y %Z' "$certificate_date" +%s 2>/dev/null
}

epoch_to_iso8601() {
  local timestamp=$1
  local formatted

  if formatted=$(LC_ALL=C date -u -d "@$timestamp" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
    printf '%s\n' "$formatted"
    return
  fi

  LC_ALL=C date -u -r "$timestamp" '+%Y-%m-%dT%H:%M:%SZ'
}

bundle_certificate_not_after_epoch() {
  local bundle=$1
  local raw_certificates
  local raw_certificate
  local not_after
  local not_after_epoch

  if ! raw_certificates=$(jq -r '
    [
      .verificationMaterial.certificate.rawBytes?,
      .verificationMaterial.x509CertificateChain.certificates[0].rawBytes?
    ]
    | .[]
    | select(type == "string" and length > 0)
  ' <<< "$bundle" 2>/dev/null) || [ -z "$raw_certificates" ]; then
    return 1
  fi

  while IFS= read -r raw_certificate; do
    if ! not_after=$(printf '%s' "$raw_certificate" \
      | base64 -d 2>/dev/null \
      | openssl x509 -inform DER -noout -enddate 2>/dev/null); then
      continue
    fi
    case "$not_after" in
      notAfter=*)
        not_after=${not_after#notAfter=}
        ;;
      *)
        continue
        ;;
    esac
    if not_after_epoch=$(certificate_date_to_epoch "$not_after"); then
      printf '%s\n' "$not_after_epoch"
      return
    fi
  done <<< "$raw_certificates"

  return 1
}

wait_then_advance_backoff() {
  local deadline=$1
  local requested_sleep=$2
  local backoff_variable=$3
  local current_time
  local remaining_time
  local sleep_time
  local next_backoff

  current_time=$(now) || return 1
  remaining_time=$((deadline - current_time))
  if [ "$remaining_time" -le 0 ]; then
    return 1
  fi

  sleep_time=$requested_sleep
  if [ "$sleep_time" -gt "$remaining_time" ]; then
    sleep_time=$remaining_time
  fi
  if [ "$sleep_time" -le 0 ] \
    || ! can_start_by "$deadline" "$((current_time + sleep_time))"; then
    return 1
  fi
  sleep "$sleep_time" || return 1

  next_backoff=$((requested_sleep + RETRY_BACKOFF_STEP_SECONDS))
  if [ "$next_backoff" -gt "$RETRY_BACKOFF_MAX_SECONDS" ]; then
    next_backoff=$RETRY_BACKOFF_MAX_SECONDS
  fi
  printf -v "$backoff_variable" '%s' "$next_backoff"
}

print_deadline_failure() {
  local operation=$1
  local attempts=$2
  local last_status=$3
  local deadline=$4
  local deadline_reason=$5
  local deadline_iso

  deadline_iso=$(epoch_to_iso8601 "$deadline")
  if [ "$attempts" -eq 0 ]; then
    printf '%s failed after 0 attempts (last status: %s): retry deadline %s has already passed before the first attempt; it is %s\n' \
      "$operation" "$last_status" "$deadline_iso" "$deadline_reason" >&2
    return
  fi
  printf '%s failed after %s attempts (last status: %s); retry deadline %s exists because it is %s\n' \
    "$operation" "$attempts" "$last_status" "$deadline_iso" "$deadline_reason" >&2
  if [ "$last_status" = 000 ]; then
    printf 'The last attempt may have committed on the registry; check whether the version is listed before re-running, since a rerun needs a fresh signature.\n' >&2
  fi
}

validate_release_tag() {
  local version
  version="${GITHUB_REF_NAME#v}"
  if [ -z "$version" ] || [ "$GITHUB_REF" != "refs/tags/v${version}" ]; then
    printf 'Expected GITHUB_REF to be exactly refs/tags/v{version} with a non-empty version; got GITHUB_REF=%s and GITHUB_REF_NAME=%s\n' "$GITHUB_REF" "$GITHUB_REF_NAME" >&2
    exit 1
  fi
  printf 'version=%s\n' "$version" >> "$GITHUB_OUTPUT"
}

registry_request() {
  local operation=$1
  local payload=$2
  local request_url
  local response_file
  local operation_started_at
  local deadline
  local deadline_reason
  local current_time
  local bundle
  local bundle_path
  local bundle_paths=('.sigstore_bundle')
  local certificate_epoch
  local earliest_not_after_epoch
  local earliest_not_after_iso
  local attempt=0
  local retry_delay=$RETRY_BACKOFF_START_SECONDS
  local last_status='not attempted'
  local token
  local status

  operation_started_at=$(now)

  case "$operation" in
    Publish)
      request_url=$REGISTRY_PUBLISH_URL

      if jq -e '(.docs? | type) == "object" and (.docs | has("sigstore_bundle"))' \
        <<< "$payload" >/dev/null 2>&1; then
        bundle_paths+=('.docs.sigstore_bundle')
      fi

      for bundle_path in "${bundle_paths[@]}"; do
        if ! bundle=$(jq -ce "$bundle_path | select(type == \"object\")" \
          <<< "$payload" 2>/dev/null) \
          || ! certificate_epoch=$(bundle_certificate_not_after_epoch "$bundle"); then
          printf 'Publish bundle %s has no readable leaf certificate at verificationMaterial.certificate.rawBytes or verificationMaterial.x509CertificateChain.certificates[0].rawBytes\n' \
            "$bundle_path" >&2
          exit 1
        fi
        if [ -z "${earliest_not_after_epoch:-}" ] \
          || [ "$certificate_epoch" -lt "$earliest_not_after_epoch" ]; then
          earliest_not_after_epoch=$certificate_epoch
        fi
      done

      deadline=$((earliest_not_after_epoch - PUBLISH_CERTIFICATE_MARGIN_SECONDS))
      earliest_not_after_iso=$(epoch_to_iso8601 "$earliest_not_after_epoch")
      deadline_reason="the earliest bundle certificate notAfter ${earliest_not_after_iso} minus the ${PUBLISH_CERTIFICATE_MARGIN_SECONDS}s registry verification margin"
      ;;
    Yank)
      request_url=$REGISTRY_YANK_URL
      deadline=$((operation_started_at + YANK_RETRY_WINDOW_SECONDS))
      deadline_reason="the ${YANK_RETRY_WINDOW_SECONDS}s Yank retry window from operation start"
      ;;
    *)
      printf 'Unsupported registry operation: %s\n' "$operation" >&2
      exit 2
      ;;
  esac

  response_file=$(mktemp)
  trap 'rm -f "$response_file"' EXIT

  # Retry only while an attempt can start by the operation-specific deadline.
  while :; do
    current_time=$(now)
    if ! can_start_by "$deadline" "$current_time"; then
      print_deadline_failure "$operation" "$attempt" "$last_status" "$deadline" "$deadline_reason"
      exit 1
    fi
    attempt=$((attempt + 1))

    if ! token=$(curl -sS \
      --connect-timeout 10 \
      --max-time 60 \
      -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${REGISTRY_AUDIENCE}" \
      | jq -er .value) || [ -z "$token" ]; then
      printf 'Failed to obtain OIDC token on attempt %s\n' "$attempt" >&2
      last_status='OIDC token failure'
      if wait_then_advance_backoff "$deadline" "$retry_delay" retry_delay; then
        continue
      fi
      print_deadline_failure "$operation" "$attempt" "$last_status" "$deadline" "$deadline_reason"
      exit 1
    fi

    current_time=$(now)
    if ! can_start_by "$deadline" "$current_time"; then
      last_status='deadline reached after OIDC token fetch'
      print_deadline_failure "$operation" "$attempt" "$last_status" "$deadline" "$deadline_reason"
      exit 1
    fi

    : > "$response_file"
    if ! status=$(curl -sS \
      --connect-timeout 10 \
      --max-time 130 \
      -o "$response_file" \
      -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' \
      --data "$payload" \
      "$request_url"); then
      status=000
    fi

    printf '%s attempt %s returned HTTP %s\n' "$operation" "$attempt" "$status"
    sed 's/^/  /' "$response_file"
    printf '\n'
    last_status=$status

    case "$status" in
      200|201)
        exit 0
        ;;
      000|429|5??)
        if wait_then_advance_backoff "$deadline" "$retry_delay" retry_delay; then
          continue
        fi
        print_deadline_failure "$operation" "$attempt" "$last_status" "$deadline" "$deadline_reason"
        exit 1
        ;;
      4??)
        printf '%s failed with non-retryable status %s\n' "$operation" "$status" >&2
        exit 1
        ;;
      *)
        printf '%s failed with unexpected status %s\n' "$operation" "$status" >&2
        exit 1
        ;;
    esac
  done
}

case "${1-}" in
  validate)
    validate_release_tag
    ;;
  request)
    if [ "$#" -ne 3 ]; then
      printf 'Usage: %s request {Publish|Yank} PAYLOAD\n' "$0" >&2
      exit 2
    fi
    registry_request "$2" "$3"
    ;;
  *)
    printf 'Usage: %s {validate|request {Publish|Yank} PAYLOAD}\n' "$0" >&2
    exit 2
    ;;
esac
