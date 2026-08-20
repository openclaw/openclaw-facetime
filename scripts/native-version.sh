#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="${repo_root}/version.env"

version_count="$(awk -F= '$1 == "VERSION" { count += 1 } END { print count + 0 }' "${version_file}")"
if [[ "${version_count}" != "1" ]]; then
  echo "version.env must contain exactly one VERSION entry" >&2
  exit 1
fi

version="$(sed -n 's/^VERSION=//p' "${version_file}")"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
  echo "version.env contains an invalid VERSION: ${version}" >&2
  exit 1
fi

printf '%s\n' "${version}"
