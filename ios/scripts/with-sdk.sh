#!/bin/bash
# Select the target SDK before SwiftPM evaluates Package.swift. A shell's SDKROOT
# can name its host SDK even when xcodebuild will compile for an iOS destination.
set -euo pipefail
if (( $# < 2 )); then
  printf 'Usage: with-sdk.sh macosx|iphoneos|iphonesimulator command ...\n' >&2
  exit 64
fi
sdk=$1
shift
case "$sdk" in
  macosx) platform=MacOSX ;;
  iphoneos) platform=iPhoneOS ;;
  iphonesimulator) platform=iPhoneSimulator ;;
  *) printf 'Unsupported target SDK: %s\n' "$sdk" >&2; exit 64 ;;
esac
# Keep an explicit SDK of the requested platform, including an older version.
# Only a recognized OTHER platform is an inherited host/target mismatch. An
# unknown SDK selection must not silently become the default (possibly newer).
selection=$sdk
root=${SDKROOT:-}
if [[ -n "$root" ]]; then
  if [[ "$root" =~ ^(macosx|iphoneos|iphonesimulator)([0-9]+(\.[0-9]+)*)?$ ]]; then
    if [[ "${BASH_REMATCH[1]}" == "$sdk" ]]; then selection=$root; fi
  elif [[ "$root" == /* && "${root##*/}" =~ ^(MacOSX|iPhoneOS|iPhoneSimulator)([0-9]+(\.[0-9]+)*)?\.sdk$ ]]; then
    if [[ "${BASH_REMATCH[1]}" == "$platform" ]]; then selection=$root; fi
  else
    printf 'Unrecognized SDKROOT; refusing to select a different SDK.\n' >&2
    exit 64
  fi
fi
SDKROOT=$(env -u SDKROOT xcrun --sdk "$selection" --show-sdk-path)
# Also reject a successful lookup with empty, wrong-platform or unusable output.
if [[ "$SDKROOT" != /* || ! "${SDKROOT##*/}" =~ ^${platform}([0-9]+(\.[0-9]+)*)?\.sdk$ \
  || ! -f "$SDKROOT/SDKSettings.json" || ! -r "$SDKROOT/SDKSettings.json" ]]; then
  printf 'SDK lookup did not return readable target SDK settings.\n' >&2
  exit 65
fi
export SDKROOT
exec "$@"
