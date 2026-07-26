#!/usr/bin/env bash
# Mac / Xcode validation script for Allah Invites You to Salah
# Run on a Mac with Xcode 26 SDK + Flutter stable matching the project.
# Do NOT run on Windows. Do NOT silently ignore warnings.
#
# Usage: bash tool/ios_mac_validation.sh 2>&1 | tee mac_validation.log

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== ENV ==="
flutter --version
xcodebuild -version
swift --version || true

echo "=== CLEAN ==="
flutter clean
flutter pub get
cd ios
# Project currently uses Flutter SwiftPM (no Podfile). If CocoaPods appears, install:
if [[ -f Podfile ]]; then
  pod install --repo-update
fi
cd ..

echo "=== OPEN WORKSPACE (manual) ==="
echo "Open: ios/Runner.xcworkspace"
echo "Confirm Signing & Capabilities: Time Sensitive Notifications only."
echo "Confirm Runner > Build Phases shows 'Check Release Configuration' as the FIRST phase"
echo "  (added 2026-07-25 in ios/Runner.xcodeproj/project.pbxproj; script body in"
echo "  ios/Runner/check_release_config.sh) — this is the new hard gate that fails a"
echo "  Release build if PRIVACY_POLICY_URL/SUPPORT_EMAIL are missing/invalid. It has"
echo "  only been logic-tested with Git Bash on Windows, NOT opened in Xcode yet."
echo "Confirm Runner target Sources includes AlarmKitPlugin, AnswerPrayerAlarmIntent, AlarmKitBridgeKeys"
echo ""
echo "AlarmKit entitlement — DO NOT ASSUME ONE IS NEEDED. See IOS_ALARMKIT_ENTITLEMENT.md:"
echo "  Apple's own AlarmKit docs describe setup as ONLY NSAlarmKitUsageDescription +"
echo "  requestAuthorization() — no entitlement is mentioned anywhere in official docs."
echo "  Only if authorization/scheduling genuinely fails with 'error 1' on a real"
echo "  iOS 26+ device, check Xcode's Signing & Capabilities > + Capability for an"
echo "  'AlarmKit' entry. If it's not listed there, no entitlement exists to add and"
echo "  the error has a different cause (OS version / provisioning profile / device"
echo "  vs simulator). If it IS listed, follow Xcode's own guidance — do not hand-type"
echo "  a key from a blog post."

echo "=== RELEASE-CONFIG GATE (this should FAIL without dart-defines) ==="
echo "Sanity check that the new Xcode Run Script phase actually gates the build:"
flutter build ios --release --no-codesign 2>&1 | tee /tmp/ios_release_gate_check.log || true
if grep -q "RELEASE CONFIGURATION INVALID" /tmp/ios_release_gate_check.log; then
  echo "OK: release build correctly failed without PRIVACY_POLICY_URL/SUPPORT_EMAIL."
else
  echo "WARN: expected the 'Check Release Configuration' phase to fail this build with no dart-defines — investigate before trusting the gate."
fi

echo "=== DEBUG BUILD ==="
flutter build ios --debug --no-codesign

echo "=== PROFILE BUILD ==="
flutter build ios --profile --no-codesign

echo "=== RELEASE BUILD (unsigned, with valid production config) ==="
flutter build ios --release --no-codesign \
  --dart-define=PRIVACY_POLICY_URL=https://yourdomain.com/privacy \
  --dart-define=SUPPORT_EMAIL=support@yourdomain.com

echo "=== SIGNED DEVICE (manual codesign / Xcode) ==="
echo "In Xcode: Product > Destination = physical iPhone > Run (Debug)"
echo "Then Product > Archive > Validate App"

echo "=== NATIVE TESTS ==="
xcodebuild test \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  || echo "WARN: RunnerTests is empty template — add XCTest for AlarmKitPlugin"

echo "=== ENTITLEMENTS DUMP (after signed build) ==="
echo "codesign -d --entitlements :- build/ios/iphoneos/Runner.app"

echo "=== BUNDLE CONTENTS ==="
echo "Verify AlarmKit symbols / Swift objects and absence of custom prayer sounds:"
echo "find build/ios/iphoneos/Runner.app -iname '*.caf' -o -iname '*AlarmKit*'"

echo "=== DONE — review mac_validation.log for every warning ==="
