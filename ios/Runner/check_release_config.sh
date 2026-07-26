#!/bin/sh
# Xcode Run Script build phase (see project.pbxproj, "Check Release
# Configuration" phase, first in the Runner target's build phases).
#
# Mirrors android/app/build.gradle.kts's validateReleaseConfig(): fails the
# build BEFORE packaging/codesigning if PRIVACY_POLICY_URL / SUPPORT_EMAIL
# are missing or invalid on a Release configuration build. This is the iOS
# equivalent of that Gradle gate — Xcode has no built-in dart-define hook,
# so this script decodes Flutter's DART_DEFINES build setting (populated by
# `flutter build ios`/`flutter build ipa --dart-define=...` into
# Flutter/Generated.xcconfig, which Debug.xcconfig/Release.xcconfig
# #include, making it visible here as a plain environment variable) and
# re-implements the same validation tool/check_release_config.dart and
# lib/config/app_config.dart use.
#
# Debug and Profile builds are never blocked here (matches Gradle, which
# only gates release/bundle tasks) — only CONFIGURATION=Release, which is
# also what `flutter build ipa` and Xcode's Archive action both use.
#
# This runs on every Xcode build (flutter build ios/ipa, Xcode Run, and
# Archive all invoke xcodebuild, which runs every build phase) — it cannot
# be skipped by forgetting a manual step, unlike a checklist item alone.

set -e

if [ "$CONFIGURATION" != "Release" ]; then
  echo "note: Check Release Configuration — skipped for $CONFIGURATION (only Release is gated)."
  exit 0
fi

decode_define() {
  # macOS ships BSD base64 (accepts --decode); fall back to -D for older/
  # alternate toolchains just in case.
  printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
}

PRIVACY_POLICY_URL_VALUE=""
SUPPORT_EMAIL_VALUE=""

if [ -n "$DART_DEFINES" ]; then
  OLD_IFS="$IFS"
  IFS=','
  for ITEM in $DART_DEFINES; do
    DECODED=$(decode_define "$ITEM")
    KEY=$(printf '%s' "$DECODED" | cut -d '=' -f1)
    VALUE=$(printf '%s' "$DECODED" | cut -d '=' -f2-)
    if [ "$KEY" = "PRIVACY_POLICY_URL" ]; then
      PRIVACY_POLICY_URL_VALUE="$VALUE"
    elif [ "$KEY" = "SUPPORT_EMAIL" ]; then
      SUPPORT_EMAIL_VALUE="$VALUE"
    fi
  done
  IFS="$OLD_IFS"
fi

PROBLEMS=""
NL="
"

case "$PRIVACY_POLICY_URL_VALUE" in
  https://*)
    case "$PRIVACY_POLICY_URL_VALUE" in
      *example.*)
        PROBLEMS="${PROBLEMS}${NL}  - PRIVACY_POLICY_URL looks like a placeholder (contains 'example.'): $PRIVACY_POLICY_URL_VALUE"
        ;;
    esac
    ;;
  *)
    PROBLEMS="${PROBLEMS}${NL}  - PRIVACY_POLICY_URL is missing or not a valid https URL: '$PRIVACY_POLICY_URL_VALUE'"
    ;;
esac

case "$SUPPORT_EMAIL_VALUE" in
  *@*) ;;
  *)
    PROBLEMS="${PROBLEMS}${NL}  - SUPPORT_EMAIL is missing or invalid: '$SUPPORT_EMAIL_VALUE'"
    ;;
esac

if [ -n "$PROBLEMS" ]; then
  echo "error: RELEASE CONFIGURATION INVALID (build stopped before packaging):${PROBLEMS}"
  echo "error: Pass the values via --dart-define, e.g.: flutter build ipa --dart-define=PRIVACY_POLICY_URL=https://yourdomain.com/privacy --dart-define=SUPPORT_EMAIL=support@yourdomain.com -- see RELEASE_CHECKLIST.md"
  exit 1
fi

echo "Check Release Configuration: OK (PRIVACY_POLICY_URL and SUPPORT_EMAIL present and valid)."
