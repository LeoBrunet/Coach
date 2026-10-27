#!/bin/bash
# Build the Coach app and (re)launch it in the booted simulator.
set -o pipefail
cd "$(dirname "$0")"
DEVICE="${DEVICE:-iPhone 17 Pro}"
if ! xcodebuild build -project Coach.xcodeproj -scheme Coach -configuration Debug \
    -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath .build > .build-log.txt 2>&1; then
    echo "BUILD FAILED"; grep "error:" .build-log.txt | sort -u | head -30; exit 1
fi
echo "Built"
[ "$1" = "build" ] && exit 0
APP=.build/Build/Products/Debug-iphonesimulator/Coach.app
xcrun simctl terminate booted com.leobrunet.coach 2>/dev/null
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.leobrunet.coach > /dev/null && echo "Launched"
