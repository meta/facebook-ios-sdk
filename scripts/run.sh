#!/bin/sh
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

# shellcheck disable=SC2039
# shellcheck disable=SC2005

set -euo pipefail

# --------------
# Imports
# --------------

if [ -f "$PWD/internal/scripts/internal_globals.sh" ]; then
  # shellcheck source=../internal/scripts/internal_globals.sh
  . "$PWD/internal/scripts/internal_globals.sh"
fi

if [ -f "$PWD/internal/scripts/intern_api.sh" ]; then
  # shellcheck source=../internal/scripts/intern_api.sh
  . "$PWD/internal/scripts/intern_api.sh"
fi

# --------------
# Functions
# --------------

# Main
main() {
  if [ -z "${SDK_SCRIPTS_DIR:-}" ]; then

    # Dirty trick to avoid having to install core utils on CircleCI
    realpath() {
      [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
    }

    # Set global variables

    SDK_SCRIPTS_DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
    SDK_DIR="$(dirname "$SDK_SCRIPTS_DIR")"

    CORE_KIT_BASICS="FBSDKCoreKit_Basics"
    AEM_KIT="FBAEMKit"
    CORE_KIT="FBSDKCoreKit"
    LOGIN_KIT="FBSDKLoginKit"
    SHARE_KIT="FBSDKShareKit"
    GAMING_SERVICES_KIT="FBSDKGamingServicesKit"

    SDK_BASE_KITS=(
      "$CORE_KIT_BASICS"
      "$AEM_KIT"
      "$CORE_KIT"
      "$LOGIN_KIT"
      "$SHARE_KIT"
    )

    SDK_KITS=(
      "${SDK_BASE_KITS[@]}"
      "$GAMING_SERVICES_KIT"
    )

    DOCUMENTATION_KITS=(
      "$CORE_KIT"
      "$LOGIN_KIT"
      "$SHARE_KIT"
      "$GAMING_SERVICES_KIT"
    )

    SDK_VERSION_FILES=(
      "Configurations/Version.xcconfig"
      "FBSDKCoreKit_Basics/FBSDKCoreKit_Basics/include/FBSDKVersions.h"
      "FBSDKCoreKit/FBSDKCoreKitTests/AppLinkNavigationTests.swift"
      "Package.swift"
    )

    SDK_GRAPH_API_VERSION_FILES=(
      "FBSDKCoreKit_Basics/FBSDKCoreKit_Basics/include/FBSDKVersions.h"
      "samples/FacebookLoginSample/FacebookLoginSample/LoginDetailsViewController.swift"
    )

    SDK_MAIN_VERSION_FILE="FBSDKCoreKit_Basics/FBSDKCoreKit_Basics/include/FBSDKVersions.h"

    SDK_POD_SPECS=("${SDK_KITS[@]}")
    SDK_POD_SPECS=("${SDK_POD_SPECS[@]/%/.podspec}")

    # `|| true` so a non-match does not trip `set -o pipefail` here. Without it every
    # run.sh subcommand aborts at startup with exit 1 and no output at all, which says
    # nothing about the actual problem.
    SDK_CURRENT_VERSION=$(grep -Eo 'FBSDK_VERSION_STRING @".*"' "$SDK_DIR/$SDK_MAIN_VERSION_FILE" 2>/dev/null | awk -F'"' '{print $2}' || true)
    SDK_CURRENT_GRAPH_API_VERSION=$(grep -Eo 'FBSDK_DEFAULT_GRAPH_API_VERSION @".*"' "$SDK_DIR/$SDK_MAIN_VERSION_FILE" 2>/dev/null | awk -F'"' '{print $2}' || true)

    if [ -z "$SDK_CURRENT_VERSION" ] || [ -z "$SDK_CURRENT_GRAPH_API_VERSION" ]; then
      echo "ERROR: could not read the SDK version from $SDK_MAIN_VERSION_FILE" >&2
      echo "       This is the canonical version definition; if it moved, update SDK_MAIN_VERSION_FILE." >&2
      exit 1
    fi

    SDK_GIT_REMOTE="https://github.com/meta/facebook-ios-sdk"

    if [ -f "$PWD/internal/scripts/internal_globals.sh" ]; then SDK_INTERNAL=1; else SDK_INTERNAL=0; fi
  fi

  local command_type=${1:-}
  if [ -n "$command_type" ]; then shift; fi

  case "$command_type" in
  "build") build_sdk "$@" ;;
  "bump-version") bump_version "$@" ;;
  "bump-api-version") bump_api_version "$@" ;;
  "bump-changelog") bump_changelog "$@" ;;
  "check-release-status") check_release_status "$@" ;;
  "is-valid-semver") is_valid_semver "$@" ;;
  "does-version-exist") does_version_exist "$@" ;;
  "release") release_sdk "$@" ;;
  "setup") setup_sdk "$@" ;;
  "tag-current-version") tag_current_version "$@" ;;
  "verify-xcode-integration") verify_xcode_integration "$@" ;;
  "--help" | "help") echo "Check main() for supported commands" ;;
  esac
}

# Setup SDK
setup_sdk() {
  local sdk_test_app_id=${1:-$SDK_TEST_FB_APP_ID}
  local sdk_test_app_secret=${2:-$SDK_TEST_FB_APP_SECRET}
  local sdk_test_client_token=${3:-$SDK_TEST_FB_CLIENT_TOKEN}
  local sdk_machine_unique_user_key=${4:-}

  {
    echo "IOS_SDK_TEST_APP_ID = $sdk_test_app_id"
    echo "IOS_SDK_TEST_APP_SECRET = $sdk_test_app_secret"
    echo "IOS_SDK_TEST_CLIENT_TOKEN = $sdk_test_client_token"
    echo "IOS_SDK_MACHINE_UNIQUE_USER_KEY = $sdk_machine_unique_user_key"
  } >>"$SDK_DIR"/Configurations/TestAppIdAndSecret.xcconfig
}

grep_for_old_version() {
  local old_version=${1:-}

  RED='\033[1;31m'
  RESET='\033[0m'

  FILES_WITH_OLD_VERSION=$(grep -rF "$old_version" -- * | grep -Ev '(CHANGELOG.md|Package.swift|\bbuild/|\bdocs|\.podspec)')
  if [ -n "$FILES_WITH_OLD_VERSION" ]; then
    echo "${RED}ERROR: Grep found the old $old_version version in ${FILES_WITH_OLD_VERSION}${RESET}" 1>&2;
    exit 1
  fi
}

# Bump Version
bump_version() {
  local new_version=${1:-}

  if [ "$new_version" == "$SDK_CURRENT_VERSION" ]; then
    echo "This version is the same as the current version"
    false
    return
  fi

  if ! is_valid_semver "$new_version"; then
    echo "This version isn't a valid semantic versioning"
    false
    return
  fi

  echo "Changing from: $SDK_CURRENT_VERSION to: $new_version"

  local version_change_files=(
    "${SDK_VERSION_FILES[@]}"
  )

  # Replace the previous version to the new version in relative files
  for file_path in "${version_change_files[@]}"; do
    local full_file_path="$SDK_DIR/$file_path"

    if [ ! -f "$full_file_path" ]; then
      echo "*** NOTE: unable to find $full_file_path."
      continue
    fi

    local temp_file="$full_file_path.tmp"
    sed -e "s/$SDK_CURRENT_VERSION/$new_version/g" "$full_file_path" >"$temp_file"
    if diff "$full_file_path" "$temp_file" >/dev/null; then
      echo "*** ERROR: unable to update $full_file_path"
      rm "$temp_file"
      continue
    fi

    mv "$temp_file" "$full_file_path"
  done

  bump_changelog "$new_version"

  grep_for_old_version "$SDK_CURRENT_VERSION"
}

# Bump Version
bump_api_version() {
  local new_version=${1:-}

  if [ "$new_version" == "$SDK_CURRENT_GRAPH_API_VERSION" ]; then
    echo "This version is the same as the current version"
    false
    return
  fi

  echo "Changing from: $SDK_CURRENT_GRAPH_API_VERSION to: $new_version"

  # Replace the previous version to the new version in relative files
  for file_path in "${SDK_GRAPH_API_VERSION_FILES[@]}"; do
    local full_file_path="$SDK_DIR/$file_path"

    if [ ! -f "$full_file_path" ]; then
      echo "*** NOTE: unable to find $full_file_path."
      continue
    fi

    local temp_file="$full_file_path.tmp"
    sed -e "s/$SDK_CURRENT_GRAPH_API_VERSION/$new_version/g" "$full_file_path" >"$temp_file"
    if diff "$full_file_path" "$temp_file" >/dev/null; then
      echo "*** ERROR: unable to update $full_file_path"
      rm "$temp_file"
      continue
    fi

    mv "$temp_file" "$full_file_path"
  done

  grep_for_old_version "$SDK_CURRENT_GRAPH_API_VERSION"
}

bump_changelog() {
  local new_version=${1:-}

  # Edit Changelog
  local updated_changelog=""

  while IFS= read -r line; do
    local updated_line

    case "$line" in
    "[Full Changelog]("*"$SDK_CURRENT_VERSION...HEAD)")
      local current_date
      current_date=$(date +%Y-%m-%d)

      updated_line="\n""${line/$SDK_CURRENT_VERSION/$new_version}""\n\n"
      updated_line=$updated_line"## $new_version\n\n"
      updated_line=$updated_line"[$current_date]"
      updated_line=$updated_line"($SDK_GIT_REMOTE/releases/tag/v$new_version) |\n"
      updated_line=$updated_line"[Full Changelog]($SDK_GIT_REMOTE/compare/v$SDK_CURRENT_VERSION...v$new_version)"
      ;;
    "# Changelog") updated_line=$line ;;
    *) updated_line="\n"$line ;;
    esac

    updated_changelog=$updated_changelog$updated_line
  done <"CHANGELOG.md"

  echo "$updated_changelog" >CHANGELOG.md
}

# Tag push current version
tag_current_version() {
  if ! is_valid_semver "$SDK_CURRENT_VERSION"; then
    exit 1
  fi

  if does_version_exist "$SDK_CURRENT_VERSION"; then
    echo "Version $SDK_CURRENT_VERSION already exists"
    false
    return
  fi

  git tag -a "v$SDK_CURRENT_VERSION" -m "Version $SDK_CURRENT_VERSION"

  if [ "${1:-}" == "--push" ]; then
    git push origin "v$SDK_CURRENT_VERSION"
  fi
}

build_sdk() {
  build_xcode_workspace() {
    xcodebuild build \
      -workspace "${1:-}" \
      -sdk "${2:-}" \
      -scheme "${3:-}" \
      -configuration Debug | xcpretty
  }

  local build_type=${1:-}
  if [ -n "$build_type" ]; then shift; fi

  case "$build_type" in
  "xcode") build_xcode_workspace "$@" ;;
  *) echo "Unsupported Build: $build_type" ;;
  esac
}

release_sdk() {
  release_docs() {
    for kit in "${DOCUMENTATION_KITS[@]}"; do
      rm -rf "$kit/build" || true

      ruby "$SDK_SCRIPTS_DIR"/genDocs.rb "$kit"

      # Zip the result so it can be uploaded easily
      pushd docs/ || continue
      zip -r "$kit".zip "$kit"
      if [[ $SDK_INTERNAL == 1 ]] && [ "${1:-}" == "--publish" ]; then
        api_update_reference_doc "$kit"
      fi
      popd || continue
    done
  }

  local release_type=${1:-}
  if [ -n "$release_type" ]; then shift; fi

  case "$release_type" in
  "docs" | "documentation") release_docs "$@" ;;
  *) echo "Unsupported Release: $release_type" ;;
  esac
}

# Check Release Status
check_release_status() {
  local version_to_check=${1:-}

  if [ -z "$version_to_check" ]; then
    version_to_check=$SDK_CURRENT_VERSION
  fi

  local release_success=0

  if ! is_valid_semver "$version_to_check"; then
    echo "$version_to_check isn't a valid semantic versioning"
    ((release_success += 1))
  fi

  if ! does_version_exist "$version_to_check"; then
    echo "$version_to_check isn't tagged in GitHub"
    ((release_success += 1))
  fi

  local pod_info

  for spec in "${SDK_POD_SPECS[@]}"; do
    if [ ! -f "$spec" ]; then
      echo "*** ERROR: unable to release $spec"
      continue
    fi

    pod_info=$(pod trunk info "${spec/.podspec/}")

    if [[ $pod_info != *"$version_to_check"* ]]; then
      echo "$spec hasn't been released yet"
      ((release_success += 1))
    fi
  done

  case $release_success in
  0) return ;;
  *) false ;;
  esac
}

# Proper Semantic Version
is_valid_semver() {
  if ! [[ ${1:-} =~ ^([0-9]{1}|[1-9][0-9]+)\.([0-9]{1}|[1-9][0-9]+)\.([0-9]{1}|[1-9][0-9]+)($|[-+][0-9A-Za-z+.-]+$) ]]; then
    false
    return
  fi
}

# Check Version Tag Exists
does_version_exist() {
  local version_to_check=${1:-}

  if [ "$version_to_check" == "" ]; then
    version_to_check=$SDK_CURRENT_VERSION
  fi

  if [ ! -d "$SDK_DIR"/.git ]; then
    echo "Not a Git Repository"
    return
  fi

  if git rev-parse "v$version_to_check" >/dev/null 2>&1; then
    return
  fi

  if git rev-parse "sdk-version-$version_to_check" >/dev/null 2>&1; then
    return
  fi

  false
}

# Builds the test app locally to ensure all frameworks still compile
verify_xcode_integration() {
  echo "Verifying the TextXcodeIntegration App builds"
  xcodebuild clean build \
    -quiet \
    -sdk iphonesimulator \
    -workspace testing/TestXcodeIntegration/TestXcodeIntegration.xcworkspace/ \
    -scheme TestXcodeIntegration
}

# --------------
# Main Script
# --------------

main "$@"
