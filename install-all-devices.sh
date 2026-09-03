#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0
# Build + install INTERACT Talk on iPad, iPhone, and Samsung (USB).
set -euo pipefail
cd "$(dirname "$0")"
bash build-and-install-ios.sh ipad
bash build-and-install-ios.sh iphone
bash build-and-install-android.sh samsung
