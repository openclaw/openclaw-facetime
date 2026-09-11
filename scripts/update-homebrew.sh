#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <release-tag>" >&2
  exit 2
fi

tag="$1"
tap_repository="${HOMEBREW_TAP_REPOSITORY:-openclaw/homebrew-tap}"
formula="${HOMEBREW_FORMULA:-openclaw-facetime}"

if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
  echo "Release tag must be a version such as v0.1.0" >&2
  exit 2
fi
if [[ ! "${tap_repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "HOMEBREW_TAP_REPOSITORY must be an owner/repository name" >&2
  exit 2
fi
if [[ ! "${formula}" =~ ^[A-Za-z0-9_.+-]+$ ]]; then
  echo "HOMEBREW_FORMULA contains unsupported characters" >&2
  exit 2
fi

request_id="openclaw-facetime-${tag}-${RANDOM}-$$"
expected_title="Update ${formula} for ${tag} (${request_id})"

gh workflow run update-formula.yml \
  --repo "${tap_repository}" \
  --ref main \
  -f formula="${formula}" \
  -f formula_profile=openclaw-facetime \
  -f tag="${tag}" \
  -f repository=openclaw/openclaw-facetime \
  -f macos_artifact=openclaw-facetime-macos-arm64.zip \
  -f request_id="${request_id}"

run_id=""
for _ in {1..30}; do
  run_id="$(gh run list \
    --repo "${tap_repository}" \
    --workflow update-formula.yml \
    --branch main \
    --event workflow_dispatch \
    --limit 20 \
    --json databaseId,displayTitle \
    --jq ".[] | select(.displayTitle == \"${expected_title}\") | .databaseId" | head -n1)"
  if [[ -n "${run_id}" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "${run_id}" ]]; then
  echo "Could not find Homebrew tap workflow run: ${expected_title}" >&2
  exit 1
fi

gh run watch "${run_id}" \
  --repo "${tap_repository}" \
  --exit-status \
  --interval 10

printf 'Homebrew tap update completed: https://github.com/%s/actions/runs/%s\n' \
  "${tap_repository}" "${run_id}"
