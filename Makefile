SHELL := /bin/bash

.PHONY: help native-archive native-sign native-verify

help:
	@printf "%s\n" \
		"make native-archive - build an ad-hoc-signed Apple Silicon release archive" \
		"make native-sign    - build, Developer ID sign, notarize, and verify the archive" \
		"make native-verify  - verify the archive at NATIVE_ARCHIVE or bin/openclaw-facetime-macos-arm64.zip"

native-archive:
	FACETIME_HELPER_CONFIGURATION=release scripts/build-native-release.sh

native-sign:
	scripts/sign-and-notarize.sh

native-verify:
	scripts/verify-native-release.sh "$${NATIVE_ARCHIVE:-bin/openclaw-facetime-macos-arm64.zip}"
