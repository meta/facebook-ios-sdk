#!/bin/sh
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

# shellcheck disable=SC2039
# shellcheck source=./run.sh

# --------------
# Functions
# --------------

# Main
main() {
  test_main_setup
  test_run_routing
  test_is_valid_semver
  test_does_version_exist
  test_check_release_status
}

# Test Success
test_success() {
  local green='\033[0;32m'
  local none='\033[0m'
  echo "${green}* Passed:${none} $*"
}

# Test Failure
test_failure() {
  local red='\033[0;31m'
  local none='\033[0m'
  echo "${red}* Failed:${none} $*"
}

log_test_begin() {
  echo "Testing ${FUNCNAME[1]}"
}

log_test_results() {
  # $1: Number of Test Failures
  local test_failures=$1
  local func_name=${FUNCNAME[1]}

  case $test_failures in
  0) test_success "$func_name tests" ;;
  *) test_failure "$test_failures $func_name tests" ;;
  esac
}

# Test Shared Setup
test_main_setup() {

  # Arrange
  local test_failures=$((0))

  local test_sdk_kits=(
    "FBSDKCoreKit"
    "FBSDKLoginKit"
    "FBSDKShareKit"
    "FBSDKMarketingKit"
  )

  local test_pod_specs=(
    "FBSDKCoreKit.podspec"
    "FBSDKLoginKit.podspec"
    "FBSDKShareKit.podspec"
    "FBSDKMarketingKit.podspec"
    "FacebookSDK.podspec"
  )

  local test_lint_pod_specs=(
    "FBSDKCoreKit.podspec"
    "FBSDKLoginKit.podspec"
    "FBSDKShareKit.podspec"
  )

  local test_version_change_files=(
    "Configurations/Version.xcconfig"
    "FBSDKCoreKit/FBSDKCoreKit/FBSDKCoreKit.h"
  )

  local test_graph_api_version_change_files=(
    "FBSDKCoreKit/FBSDKCoreKit/FBSDKCoreKit.h"
    "FBSDKCoreKit/FBSDKCoreKitTests/FBSDKGraphRequestTests.m"
  )

  local test_main_version_file="FBSDKCoreKit/FBSDKCoreKit/FBSDKCoreKit.h"

  local test_current_version
  test_current_version=$(grep -Eo 'FBSDK_VERSION_STRING @".*"' "$PWD/$test_main_version_file" | awk -F'"' '{print $2}')

  local test_sdk_current_graph_api_version
  test_sdk_current_graph_api_version=$(grep -Eo 'FBSDK_DEFAULT_GRAPH_API_VERSION @".*"' "$PWD/$test_main_version_file" | awk -F'"' '{print $2}')

  if [ ! -f "$PWD/scripts/run.sh" ]; then
    test_failure "You're not in the correct working directory. Please change to the scripts/ parent directory"
  fi

  # Act
  log_test_begin

  . "$PWD/scripts/run.sh"

  # Assert
  if [ -z "$SDK_SCRIPTS_DIR" ]; then
    test_failure "SDK_SCRIPTS_DIR"
    ((test_failures += 1))
  fi

  if [ "$SDK_SCRIPTS_DIR" != "$SDK_DIR"/scripts ]; then
    test_failure "SDK_SCRIPTS_DIR not correct"
    ((test_failures += 1))
  fi

  if [ "${SDK_KITS[*]}" != "${test_sdk_kits[*]}" ]; then
    test_failure "SDK_KITS not correct"
    ((test_failures += 1))
  fi

  if [ "${SDK_POD_SPECS[*]}" != "${test_pod_specs[*]}" ]; then
    test_failure "SDK_POD_SPECS not correct"
    ((test_failures += 1))
  fi

  if [ "${SDK_LINT_POD_SPECS[*]}" != "${test_lint_pod_specs[*]}" ]; then
    test_failure "SDK_LINT_POD_SPECS not correct"
    ((test_failures += 1))
  fi

  if [ "${SDK_VERSION_FILES[*]}" != "${test_version_change_files[*]}" ]; then
    test_failure "SDK_VERSION_FILES not correct"
    ((test_failures += 1))
  fi

  if [ "${SDK_GRAPH_API_VERSION_FILES[*]}" != "${test_graph_api_version_change_files[*]}" ]; then
    test_failure "SDK_GRAPH_API_VERSION_FILES not correct"
    ((test_failures += 1))
  fi

  if [ "$SDK_MAIN_VERSION_FILE" != "$test_main_version_file" ]; then
    test_failure "SDK_MAIN_VERSION_FILE not correct"
    ((test_failures += 1))
  fi

  if [ "$SDK_FRAMEWORK_NAME" != "FacebookSDK" ]; then
    test_failure "SDK_FRAMEWORK_NAME not correct"
    ((test_failures += 1))
  fi

  if [ "$SDK_CURRENT_VERSION" != "$test_current_version" ]; then
    test_failure "SDK_CURRENT_VERSION not correct"
    ((test_failures += 1))
  fi

  if [ "$SDK_CURRENT_GRAPH_API_VERSION" != "$test_sdk_current_graph_api_version" ]; then
    test_failure "SDK_CURRENT_GRAPH_API_VERSION not correct"
    ((test_failures += 1))
  fi

  if [ "$SDK_GIT_REMOTE" != "https://github.com/meta/facebook-ios-sdk" ]; then
    test_failure "SDK_GIT_REMOTE not correct"
    ((test_failures += 1))
  fi

  if [ -f "$PWD/internal/scripts/internal_globals.sh" ] && [[ $SDK_INTERNAL == 0 ]]; then
    test_failure "SDK_INTERNAL not correct"
    ((test_failures += 1))
  elif ! [ -f "$PWD/internal/scripts/internal_globals.sh" ] && [[ $SDK_INTERNAL == 1 ]]; then
    test_failure "SDK_INTERNAL not correct"
    ((test_failures += 1))
  fi

  log_test_results $test_failures
}

test_is_valid_semver() {

  # Arrange
  local test_failures=$((0))
  local func_name=${FUNCNAME[0]}

  local proper_versions=(
    "0.0.0"
    "1.0.0"
    "0.1.0"
    "0.0.1"
    "0.1.1"
    "10.1.0"
    "100.1.0"
    "10.10.10"
    "1.9.0"
    "1.10.0"
    "1.11.0"
    "1.0.0-alpha"
    "1.0.0-alpha.1"
    "1.0.0-0.3.7"
    "1.0.0-x.7.z.92"
    "1.0.0-alpha+001"
    "1.0.0+alpha-001"
    "1.0.0+20130313144700"
    "1.0.0-beta+exp.sha.5114f85"
    "1.0.0-alpha"
    "1.0.0-alpha.1"
    "1.0.0-alpha.beta"
    "1.0.0-beta"
    "1.0.0-beta.2"
    "1.0.0-beta.11"
    "1.0.0-rc.1"
  )

  # Act
  log_test_begin

  for version in "${proper_versions[@]}"; do
    # Assert
    if ! sh "$PWD"/scripts/run.sh is-valid-semver "$version"; then
      test_failure "$version is valid, but returns false"
      ((test_failures += 1))
    fi
  done

  # Arrange
  local improper_versions=(
    "1.0."
    "0.1"
    "10.1.0.1"
    "a.b.c"
    "1.0.0-"
    "01.0.0"
    "00.0.0"
    "1.01.0"
    "0.00.0"
    "1.0.00"
    "0.0.01"
  )

  # Act
  for version in "${improper_versions[@]}"; do
    # Assert
    if sh "$PWD"/scripts/run.sh is-valid-semver "$version"; then
      test_failure "$version is invalid, but returns true"
    fi
  done

  log_test_results $test_failures
}

# Test Build SDK
test_run_routing() {

  # Arrange
  local test_failures=$((0))
  local func_name=${FUNCNAME[0]}

  local inputs=(
    "build unsupported"
    "lint unsupported"
    "release unsupported"
    "help"
    "--help"
  )

  local expected=(
    "Unsupported Build: unsupported"
    "Unsupported Lint: unsupported"
    "Unsupported Release: unsupported"
    "Check main() for supported commands"
    "Check main() for supported commands"
  )

  # Act
  log_test_begin

  for i in "${!inputs[@]}"; do
    local input_string="${inputs[$i]}"
    IFS=" " read -r -a input_params <<<"$input_string"

    local actual
    actual=$(sh "$PWD"/scripts/run.sh "${input_params[@]}")

    # Assert
    if [ "$actual" != "${expected[$i]}" ]; then
      test_failure "expected: ${expected[$i]} but got: $actual"
      ((test_failures += 1))
    fi
  done

  log_test_results $test_failures
}

test_does_version_exist() {

  # Arrange
  local test_failures=$((0))
  local func_name=${FUNCNAME[0]}

  # Act
  log_test_begin

  # Assert
  if [ ! -d "$SDK_DIR"/.git ]; then
    echo "Not a Git Repository"
    return
  fi

  if ! sh "$PWD"/scripts/run.sh does-version-exist; then
    test_failure "Current version is valid, but returns false"
    ((test_failures += 1))
  fi

  if ! sh "$PWD"/scripts/run.sh does-version-exist 4.40.0; then
    test_failure "4.40.0 is valid, but returns false"
    ((test_failures += 1))
  fi

  if sh "$PWD"/scripts/run.sh does-version-exist 0.0.0; then
    test_failure "0.0.0 is invalid, but returns true"
    ((test_failures += 1))
  fi

  log_test_results $test_failures
}

test_check_release_status() {

  # Arrange
  local test_failures=$((0))
  local func_name=${FUNCNAME[0]}

  # Act
  log_test_begin

  # Assert
  if ! sh "$PWD"/scripts/run.sh check-release-status 4.38.0; then
    test_failure "Version 4.38.0 is valid, but returns false"
    ((test_failures += 1))
  fi

  log_test_results $test_failures
}

# --------------
# Main Script
# --------------

main "$@"
