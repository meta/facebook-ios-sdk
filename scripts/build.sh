#!/bin/sh
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

# Convenience script for building SDK modules.
#
# Usage:
#   ./scripts/build.sh              # Build all (BuildAllKits-Dynamic)
#   ./scripts/build.sh LoginKit     # Build FBSDKLoginKit-Dynamic
#   ./scripts/build.sh CoreKit      # Build FBSDKCoreKit-Dynamic
#   ./scripts/build.sh ShareKit     # Build FBSDKShareKit-Dynamic
#   ./scripts/build.sh GamingKit    # Build FBSDKGamingServicesKit-Dynamic
#   ./scripts/build.sh AEMKit       # Build FBAEMKit-Dynamic
#   ./scripts/build.sh BasicKit     # Build FBSDKCoreKit_Basics

set -euo pipefail

# Map short names to xcodebuild scheme names
map_scheme() {
  case "$1" in
    LoginKit)    echo "FBSDKLoginKit-Dynamic" ;;
    CoreKit)     echo "FBSDKCoreKit-Dynamic" ;;
    ShareKit)    echo "FBSDKShareKit-Dynamic" ;;
    GamingKit)   echo "FBSDKGamingServicesKit-Dynamic" ;;
    AEMKit)      echo "FBAEMKit-Dynamic" ;;
    BasicKit)    echo "FBSDKCoreKit_Basics" ;;
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

# Keep the OS paired with the simulator name. Omitting it resolves the name on
# the latest runtime, where a device selected from an older runtime may not exist.
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

if [ -z "$DESTINATION_SPEC" ]; then
  echo "Error: no iPhone simulator within iOS Simulator SDK $SIMULATOR_SDK_VERSION was found for '$SCHEME'." >&2
  echo "Select a matching Xcode via DEVELOPER_DIR or xcode-select, or install a suitable iOS runtime." >&2
  exit 1
fi

DEVICE_OS=${DESTINATION_SPEC%%|*}
DEVICE_NAME=${DESTINATION_SPEC#*|}

DESTINATION="platform=iOS Simulator,name=$DEVICE_NAME,OS=$DEVICE_OS"

echo "Building scheme: $SCHEME (destination: $DEVICE_NAME)"

# Build the xcodebuild command
XCODEBUILD_CMD="xcodebuild build \
  -workspace $WORKSPACE \
  -scheme $SCHEME \
  -sdk iphonesimulator \
  -configuration Debug \
  -destination '$DESTINATION'"

# Pipe through xcpretty if available
if command -v xcpretty >/dev/null 2>&1; then
  eval "$XCODEBUILD_CMD" | xcpretty
else
  eval "$XCODEBUILD_CMD"
fi
