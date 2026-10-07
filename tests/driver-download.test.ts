import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("privileged driver download", () => {
  const installer = readFileSync("scripts/install-driver-root.sh", "utf8");
  const start = installer.indexOf("/usr/bin/curl -fsSL");
  const end = installer.indexOf('\nplist="$source_dir/', start);

  it.each([
    { name: "download timeout", curlExit: 28, hashExit: 0, expected: 28, steps: ["download"] },
    { name: "checksum mismatch", curlExit: 0, hashExit: 1, expected: 1, steps: ["download", "checksum"] },
    { name: "verified archive", curlExit: 0, hashExit: 0, expected: 0, steps: ["download", "checksum", "extract"] },
  ])("handles $name before any privileged installation", ({ curlExit, hashExit, expected, steps }) => {
    expect(start).toBeGreaterThan(0);
    expect(end).toBeGreaterThan(start);
    // Execute the real download/verification sequence with command fixtures;
    // no network, driver installation, or audio-service restart is permitted.
    const result = spawnSync("/bin/bash", ["-c", String.raw`
set -eu
function /usr/bin/curl() {
  connect_timeout=0
  total_timeout=0
  while test "$#" -gt 0; do
    case "$1" in
      --connect-timeout) shift; connect_timeout=$1 ;;
      --max-time) shift; total_timeout=$1 ;;
    esac
    shift
  done
  test "$connect_timeout" -gt 0 && test "$connect_timeout" -le 30 || return 97
  test "$total_timeout" -gt 0 && test "$total_timeout" -le 120 || return 97
  echo download
  return "$CURL_EXIT"
}
function /usr/bin/shasum() {
  cat >/dev/null
  echo checksum
  return "$HASH_EXIT"
}
function /usr/bin/tar() { echo extract; }
version=fixture
archive_sha256=fixture
archive=/nonexistent/archive
work_dir=/nonexistent/work
` + installer.slice(start, end)], {
      encoding: "utf8",
      env: { PATH: "/usr/bin:/bin", CURL_EXIT: String(curlExit), HASH_EXIT: String(hashExit) },
      timeout: 5_000,
    });

    expect(result.error).toBeUndefined();
    expect(result.status).toBe(expected);
    expect(result.stdout.trim().split("\n")).toEqual(steps);
  });
});
