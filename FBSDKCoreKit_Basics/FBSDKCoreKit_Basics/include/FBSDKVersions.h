/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

// The SDK-wide version constants.
//
// These are not specific to Basics. They live here because Basics is the lowest
// layer, so it is the only module every other one can read a single definition
// from -- FBAEMKit and FBSDKCoreKit_Basics cannot import FBSDKCoreKit, which is
// why each used to carry its own copy that a version bump had to find and update.
//
// FBSDKCoreKitVersions.h forwards this header, so both names remain available to
// FBSDKCoreKit consumers exactly as before.

#define FBSDK_VERSION_STRING @"19.0.1"
#define FBSDK_DEFAULT_GRAPH_API_VERSION @"v26.0"
