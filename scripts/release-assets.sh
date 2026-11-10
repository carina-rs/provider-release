#!/usr/bin/env bash

set -euo pipefail

tag=${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

if gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' \
  > "$temp_dir/assets" 2> "$temp_dir/view-error"; then
  :
else
  status=$?
  # gh uses this specific error for an absent release. Authentication, network,
  # and other API errors must stop the job before any uploads.
  if [ "$(< "$temp_dir/view-error")" = 'release not found' ]; then
    printf 'Release %s does not exist; no existing assets to compare.\n' "$tag"
    exit 0
  fi
  printf '::error::Failed to inspect release %s in %s.\n' "$tag" "$repo" >&2
  cat "$temp_dir/view-error" >&2
  exit "$status"
fi

has_conflicts=false
for file in "$@"; do
  asset=${file##*/}
  if ! grep -Fxq -- "$asset" "$temp_dir/assets"; then
    continue
  fi

  rm -f -- "$temp_dir/download"
  if ! gh release download "$tag" --repo "$repo" --pattern "$asset" \
    --output "$temp_dir/download"; then
    printf '::error::Failed to download existing release asset %s for comparison.\n' "$asset" >&2
    exit 1
  fi
  local_digest=$(sha256sum < "$file")
  local_digest=${local_digest%% *}
  existing_digest=$(sha256sum < "$temp_dir/download")
  existing_digest=${existing_digest%% *}

  if [ "$local_digest" = "$existing_digest" ]; then
    printf 'Asset %s has identical SHA-256 %s; leaving the existing asset in place.\n' \
      "$asset" "$local_digest"
  else
    printf "::error::Asset %s differs: local SHA-256 %s; existing SHA-256 %s. The tag's assets were uploaded from an earlier build and are never replaced. Do not use 'Re-run all jobs' for a tag. If the registry already has this version, nothing needs to be done; otherwise cut a new version.\n" \
      "$asset" "$local_digest" "$existing_digest" >&2
    has_conflicts=true
  fi
done

# Report every mismatch before failing, and finish all checks before the upload step.
if "$has_conflicts"; then
  exit 1
fi
