#!/bin/sh
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

# Convenience script for running SDK tests.
#
# Usage:
#   ./scripts/test.sh              # Run all tests (BuildAllKits-Dynamic)
#   ./scripts/test.sh LoginKit     # Run FBSDKLoginKit-Dynamic tests
#   ./scripts/test.sh CoreKit      # Run FBSDKCoreKit-Dynamic tests
#   ./scripts/test.sh ShareKit     # Run FBSDKShareKit-Dynamic tests
#   ./scripts/test.sh GamingKit    # Run FBSDKGamingServicesKit-Dynamic tests
#   ./scripts/test.sh AEMKit       # Run FBAEMKit-Dynamic tests
#   ./scripts/test.sh BasicKit     # Run FBSDKCoreKit_Basics tests

set -euo pipefail

# Map short names to xcodebuild scheme names
map_scheme() {
  case "$1" in
    LoginKit)    echo "FBSDKLoginKit-Dynamic" ;;
    CoreKit)     echo "FBSDKCoreKit-Dynamic" ;;
    ShareKit)    echo "FBSDKShareKit-Dynamic" ;;
    GamingKit)   echo "FBSDKGamingServicesKit-Dynamic" ;;
    AEMKit)      echo "FBAEMKit-Dynamic" ;;
    BasicKit)    echo "FBSDKCoreKit_Basics-Dynamic" ;;
    *)
      echo "Unknown kit: $1" >&2
      echo "Available kits: LoginKit, CoreKit, ShareKit, GamingKit, AEMKit, BasicKit" >&2
      exit 1
      ;;
  esac
}

# Determine scheme
if [ $# -eq 0 ]; then
  SCHEME="BuildAllKits-Dynamic"
else
  SCHEME=$(map_scheme "$1")
fi

WORKSPACE="FacebookSDK.xcworkspace"

# Other Xcode installs may provide runtimes newer than the active toolchain.
if ! SIMULATOR_SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version); then
  echo "Error: cannot determine the iOS Simulator SDK for the active Xcode." >&2
  echo "Check DEVELOPER_DIR or xcode-select and finish Xcode setup." >&2
  exit 1
fi
if ! printf '%s\n' "$SIMULATOR_SDK_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
  echo "Error: invalid iOS Simulator SDK version '$SIMULATOR_SDK_VERSION'." >&2
  exit 1
fi

# Select the newest scheme-available iPhone runtime no newer than the active SDK.
# Compare release families so a matching runtime patch is still usable.
DESTINATION_SPEC=$(xcodebuild -scheme "$SCHEME" -workspace "$WORKSPACE" -showdestinations 2>/dev/null \
  | grep 'platform:iOS Simulator' \
  | grep 'name:iPhone' \
  | grep -v 'error:' \
  | sed -n 's/.*OS:\([0-9][0-9.]*\).*name:\(.*\) }.*/\1|\2/p' \
  | awk -F'|' -v sdk="$SIMULATOR_SDK_VERSION" '
      BEGIN { split(sdk, sdk_parts, ".") }
      {
        split($1, os_parts, ".")
        if (os_parts[1]+0 < sdk_parts[1]+0 ||
            (os_parts[1]+0 == sdk_parts[1]+0 && os_parts[2]+0 <= sdk_parts[2]+0)) print
      }' \
  | sort -t'|' -k1,1 -Vr \
  | head -1 || true)

# `|| true` above so that a scheme with no matching destination reaches this check rather than
# aborting the pipeline under `set -e`, which exits silently with no output at all.
if [ -z "$DESTINATION_SPEC" ]; then
  echo "Error: no iPhone simulator within iOS Simulator SDK $SIMULATOR_SDK_VERSION was found for '$SCHEME'." >&2
  echo "Select a matching Xcode via DEVELOPER_DIR or xcode-select, or install a suitable iOS runtime." >&2
  exit 1
fi

DEVICE_OS=${DESTINATION_SPEC%%|*}
DEVICE_NAME=${DESTINATION_SPEC#*|}

DESTINATION="platform=iOS Simulator,name=$DEVICE_NAME,OS=$DEVICE_OS"

echo "Running tests for scheme: $SCHEME"

# Build the xcodebuild command
XCODEBUILD_CMD="xcodebuild test \
  -workspace $WORKSPACE \
  -scheme $SCHEME \
  -configuration Debug \
  -destination '$DESTINATION'"

# Pipe through xcpretty if available
if command -v xcpretty >/dev/null 2>&1; then
  eval "$XCODEBUILD_CMD" | xcpretty
else
  eval "$XCODEBUILD_CMD"
fi
