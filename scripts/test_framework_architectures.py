#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

"""Check that a built XCFramework has only arm64 iOS device slices."""

import argparse
import plistlib
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xcframework", type=Path)
    root = parser.parse_args().xcframework
    label = str(root)
    try:
        with (root / "Info.plist").open("rb") as handle:
            libraries = plistlib.load(handle)["AvailableLibraries"]
        saw_device = False
        for library in libraries:
            label = library["LibraryIdentifier"]
            if library["SupportedPlatform"] not in {"ios", "iphoneos"}:
                continue
            is_device = not library.get("SupportedPlatformVariant")
            saw_device |= is_device
            directory = root / label
            binary = directory / (library.get("BinaryPath") or library["LibraryPath"])
            if binary.suffix == ".framework":
                executable = binary.stem
                if (binary / "Info.plist").is_file():
                    with (binary / "Info.plist").open("rb") as handle:
                        executable = plistlib.load(handle).get("CFBundleExecutable", executable)
                binary /= executable
            result = subprocess.run(
                ["xcrun", "lipo", "-archs", str(binary)],
                check=True,
                capture_output=True,
                text=True,
            )
            architectures = set(result.stdout.split())
            metadata = set(library["SupportedArchitectures"])
            if not architectures or architectures != metadata:
                raise ValueError(
                    f"binary architectures {sorted(architectures)} do not match "
                    f"SupportedArchitectures {sorted(metadata)}"
                )
            if is_device and architectures != {"arm64"}:
                raise ValueError(f"expected exactly arm64 for iOS device, got {sorted(architectures)}")
        if not saw_device:
            raise ValueError("no iOS device library found in Info.plist")
    except subprocess.CalledProcessError as error:
        print(f"{label}: lipo failed: {error.stderr.strip()}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"{label}: {error}", file=sys.stderr)
        return 1
    print(f"OK: {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
