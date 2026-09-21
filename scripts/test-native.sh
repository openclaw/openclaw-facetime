#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-facetime-native-checks.XXXXXX")"

cleanup() {
  /usr/bin/trash "$build_dir"
}
trap cleanup EXIT

swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/InputRouteReadiness.swift" \
  "$repo_root/native/Checks/InputRouteReadinessChecks.swift" \
  -o "$build_dir/input-route-readiness-checks"

"$build_dir/input-route-readiness-checks"

swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/OutputRouteReadiness.swift" \
  "$repo_root/native/Checks/OutputRouteReadinessChecks.swift" \
  -o "$build_dir/output-route-readiness-checks"

"$build_dir/output-route-readiness-checks"

swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/FixedSlotRing.swift" \
  "$repo_root/native/Checks/FixedSlotRingChecks.swift" \
  -o "$build_dir/fixed-slot-ring-checks"

"$build_dir/fixed-slot-ring-checks"

swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/CaptureStandardOutput.swift" \
  "$repo_root/native/Checks/CaptureStandardOutputChecks.swift" \
  -o "$build_dir/capture-standard-output-checks"

"$build_dir/capture-standard-output-checks"

swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/ParentLossCoordinator.swift" \
  "$repo_root/native/Checks/ParentLossCoordinatorChecks.swift" \
  -o "$build_dir/parent-loss-coordinator-checks"

"$build_dir/parent-loss-coordinator-checks"
swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/FixedSlotRing.swift" \
  "$repo_root/native/Sources/FaceTimeAudioCapture/FixedSlotQueue.swift" \
  "$repo_root/native/Checks/FixedSlotQueueChecks.swift" \
  -o "$build_dir/fixed-slot-queue-checks"

"$build_dir/fixed-slot-queue-checks"

swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/CapturedProcessIdentity.swift" \
  "$repo_root/native/Sources/FaceTimeAudioCapture/CaptureCarrierOwner.swift" \
  "$repo_root/native/Checks/CaptureClock.swift" \
  "$repo_root/native/Checks/CaptureCarrierOwnerChecks.swift" \
  -o "$build_dir/capture-carrier-owner-checks"

"$build_dir/capture-carrier-owner-checks"

python3 "$repo_root/native/Checks/CapturePipeLossChecks.py" "$repo_root" "$build_dir/capture-pipe-loss-checks.swift"
swiftc -parse-as-library \
  "$repo_root/native/Sources/FaceTimeAudioCapture/FixedSlotRing.swift" \
  "$repo_root/native/Sources/FaceTimeAudioCapture/FixedSlotQueue.swift" \
  "$repo_root/native/Sources/FaceTimeAudioCapture/CaptureStandardOutput.swift" \
  "$repo_root/native/Sources/FaceTimeAudioCapture/ParentLossCoordinator.swift" \
  "$repo_root/native/Sources/FaceTimeAudioCapture/CapturedProcessIdentity.swift" \
  "$repo_root/native/Sources/FaceTimeAudioCapture/CaptureCarrierOwner.swift" \
  "$repo_root/native/Checks/CaptureClock.swift" \
  "$build_dir/capture-pipe-loss-checks.swift" \
  -o "$build_dir/capture-pipe-loss-checks"

"$build_dir/capture-pipe-loss-checks"

swiftc \
  "$repo_root/native/Sources/FaceTimeAudioCapture/CapturedProcessIdentity.swift" \
  "$repo_root/native/Checks/CapturedProcessIdentityChecks.swift" \
  -o "$build_dir/captured-process-identity-checks"

"$build_dir/captured-process-identity-checks"
