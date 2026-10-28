#!/usr/bin/env bash

set -euo pipefail

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
  local token
  local status

  case "$operation" in
    Publish)
      request_url=$REGISTRY_PUBLISH_URL
      ;;
    Yank)
      request_url=$REGISTRY_YANK_URL
      ;;
    *)
      printf 'Unsupported registry operation: %s\n' "$operation" >&2
      exit 2
      ;;
  esac

  response_file=$(mktemp)
  trap 'rm -f "$response_file"' EXIT

  # The Fulcio cert from the sign step lives ~10 minutes and must still be valid
  # when the registry verifies a new version's bundle; this loop's worst case
  # (3 x (60s token + 120s POST) + 2 x 10s sleep) nearly exhausts it, so do not
  # add attempts, sleeps, or timeout headroom here.
  for attempt in 1 2 3; do
    if ! token=$(curl -sS \
      --connect-timeout 10 \
      --max-time 60 \
      -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${REGISTRY_AUDIENCE}" \
      | jq -er .value) || [ -z "$token" ]; then
      printf 'Failed to obtain OIDC token on attempt %s\n' "$attempt" >&2
      if [ "$attempt" -lt 3 ]; then
        sleep 10
        continue
      fi
      printf '%s failed after 3 attempts while obtaining OIDC token\n' "$operation" >&2
      exit 1
    fi

    : > "$response_file"
    if ! status=$(curl -sS \
      --connect-timeout 10 \
      --max-time 120 \
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

    case "$status" in
      200|201)
        exit 0
        ;;
      000|429|5??)
        if [ "$attempt" -lt 3 ]; then
          sleep 10
          continue
        fi
        printf '%s failed after 3 attempts (last status: %s)\n' "$operation" "$status" >&2
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
