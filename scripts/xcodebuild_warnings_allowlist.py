# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

XCODEBUILD_WARNINGS_ALLOWLIST = [
    "warning: Input PNG is already optimized for iPhone OS.  Copying source file to destination...",
    # Pika Warnings:
    "warning: failed to load toolchain: could not find Info.plist in /Users/facebook/Library/Developer/Toolchains/pika-",
    # Deprecation Warnings:
    "is deprecated and will be removed in the next major release",
    "warning: Building targets in manual order is deprecated",
    "warning: 'web' is deprecated: The web sharing mode is deprecated. Consider using automatic sharing mode instead.",
    "warning: 'feedWeb' is deprecated: The feed web sharing mode is deprecated. Consider using automatic sharing mode instead.",
    "warning: 'feedBrowser' is deprecated: The feed browser sharing mode is deprecated. Consider using automatic or browser sharing modes instead.",
    # Build system warnings (Xcode 16+):
    "warning: tasks in 'Copy Headers' are delayed by unsandboxed script phases",
    # Toolchain noise, emitted per-target regardless of anything in this repo.
    # Matched on the stem because Xcode 27 reworded this from
    # "skipped. No AppIntents..." to "skipped, no AppIntents...", which silently
    # stopped the old entry from matching and surfaced 14 "new" warnings.
    "Metadata extraction skipped",
    # Apple ships XCTest built for iOS 17, so every test bundle below that floor
    # gets this. Scoped to Apple's test dylibs on purpose: the same warning about
    # one of our own frameworks is a real problem and must still be caught.
    "but linking with dylib '@rpath/XCTest.framework/XCTest' which was built for newer version",
    "but linking with dylib '@rpath/libXCTestSwiftSupport.dylib' which was built for newer version",
    # Apple's own StoreKitTest header, reported once per installed simulator SDK, so every
    # new SDK version surfaced it as "new". Matched on the header path, because raw lines
    # put ":line:col:" between it and the message; the same deprecation in this repo's
    # code is still caught.
    "StoreKitTest.framework/Headers/SKTestTransaction.h:",
]

# Anything not matched above is compared against scripts/xcodebuild_warnings_baseline.txt.
# Prefer the baseline for real warnings: an allowlist entry is a pattern that suppresses
# every future instance too, which is how this check stopped catching anything.
