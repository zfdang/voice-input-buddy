#!/bin/bash
set -euo pipefail
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in
    arm64) RELEASE_ARCH_LABEL=arm64 ;;
    x86_64) RELEASE_ARCH_LABEL=intel ;;
    *) echo 'Supported architectures: arm64, x86_64' >&2; exit 1 ;;
esac
export BUILD_ARCH RELEASE_ARCH_LABEL
