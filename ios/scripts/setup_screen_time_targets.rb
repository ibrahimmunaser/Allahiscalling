#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the three Screen Time app-extension targets (DeviceActivityMonitor,
# ShieldConfiguration, ShieldAction) to Runner.xcodeproj, embeds them in the
# main app, and shares GuardShared.swift across all four targets.
#
# Run from Codemagic (see codemagic.yaml, "ios-release" workflow) before
# `pod install`/`flutter build ipa`, every build — idempotent, so re-running
# it is always safe: each target/file is only added if not already present.
#
# This exists because there is no Mac available to do this once by hand in
# Xcode; see IOS_SCREEN_TIME_SETUP.md for the manual steps this still
# cannot automate (Apple Developer portal: Family Controls entitlement
# approval, App Group registration, and fetching provisioning profiles for
# the three new bundle IDs in Codemagic).

require 'xcodeproj'

# Safety gate: until Apple approves the Family Controls distribution
# entitlement AND the three extensions' App Store provisioning profiles
# exist in Codemagic, adding these targets would break signing for EVERY
# release (not just this feature) — `xcodebuild archive` fails outright if
# any target in the archived scheme has no matching provisioning profile.
#
# Set ENABLE_SCREEN_TIME_EXTENSIONS=1 as a Codemagic environment variable
# (or `export` it locally) only once both of those are true — see
# IOS_SCREEN_TIME_SETUP.md. Until then this script is a guaranteed no-op
# and the project file is never touched.
unless ENV['ENABLE_SCREEN_TIME_EXTENSIONS'] == '1'
  puts 'ENABLE_SCREEN_TIME_EXTENSIONS is not set to 1 — skipping Screen Time ' \
       'extension target setup (see IOS_SCREEN_TIME_SETUP.md). This build is unaffected.'
  exit 0
end

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'Runner.xcodeproj')
MAIN_BUNDLE_ID = 'com.salahinvite.allahInvitesYouToSalah'
APP_GROUP = 'group.com.salahinvite.allahInvitesYouToSalah'
DEPLOYMENT_TARGET = '16.0' # FamilyControls/DeviceActivity/ManagedSettingsUI minimum.

# Runner/Runner.entitlements deliberately ships WITHOUT family-controls /
# application-groups committed (see the comment in that file) — adding a
# provisioning-profile-gated capability unconditionally breaks signing for
# every ordinary release. Inject both keys here, only now that we know
# ENABLE_SCREEN_TIME_EXTENSIONS=1 (i.e. Apple has approved the entitlement
# and the main app's provisioning profile has been updated to support it).
RUNNER_ENTITLEMENTS = File.join(ROOT, 'Runner', 'Runner.entitlements')
PLISTBUDDY = '/usr/libexec/PlistBuddy'

def plistbuddy_has_key?(path, key)
  system("#{PLISTBUDDY} -c \"Print :#{key}\" \"#{path}\" > /dev/null 2>&1")
end

unless plistbuddy_has_key?(RUNNER_ENTITLEMENTS, 'com.apple.developer.family-controls')
  system("#{PLISTBUDDY} -c \"Add :com.apple.developer.family-controls bool true\" \"#{RUNNER_ENTITLEMENTS}\"") ||
    abort("Failed to add com.apple.developer.family-controls to #{RUNNER_ENTITLEMENTS}")
end

unless plistbuddy_has_key?(RUNNER_ENTITLEMENTS, 'com.apple.security.application-groups')
  system("#{PLISTBUDDY} -c \"Add :com.apple.security.application-groups array\" \"#{RUNNER_ENTITLEMENTS}\"") &&
    system("#{PLISTBUDDY} -c \"Add :com.apple.security.application-groups:0 string #{APP_GROUP}\" \"#{RUNNER_ENTITLEMENTS}\"") ||
    abort("Failed to add com.apple.security.application-groups to #{RUNNER_ENTITLEMENTS}")
end

puts "Runner.entitlements now includes family-controls + application-groups (#{RUNNER_ENTITLEMENTS})."

EXTENSIONS = [
  {
    name: 'DeviceActivityMonitorExtension',
    bundle_suffix: 'deviceactivitymonitor',
    point: 'com.apple.deviceactivity.monitor-extension',
  },
  {
    name: 'ShieldConfigurationExtension',
    bundle_suffix: 'shieldconfiguration',
    point: 'com.apple.ManagedSettingsUI.shield-configuration-service',
  },
  {
    name: 'ShieldActionExtension',
    bundle_suffix: 'shieldaction',
    point: 'com.apple.ManagedSettingsUI.shield-action-service',
  },
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
main_target = project.targets.find { |t| t.name == 'Runner' }
raise "Runner target not found in #{PROJECT_PATH}" unless main_target

# Shared App Group entitlement on the main app (also set directly in
# Runner.entitlements, but ensure the build setting points at it — it
# already does, CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements).

# Shared source file, compiled into every extension target too.
shared_file_ref =
  project.main_group['Runner']&.files&.find { |f| f.path == 'GuardShared.swift' } ||
  project.main_group['Runner'].new_file('GuardShared.swift')

embed_phase =
  main_target.copy_files_build_phases.find { |p| p.name == 'Embed App Extensions' } ||
  main_target.new_copy_files_build_phase('Embed App Extensions').tap do |phase|
    phase.symbol_dst_subfolder_spec = :plug_ins
  end

EXTENSIONS.each do |ext|
  next if project.targets.any? { |t| t.name == ext[:name] }

  group = project.main_group.new_group(ext[:name], ext[:name])
  source_dir = File.join(ROOT, ext[:name])

  swift_file = group.new_file(File.join(source_dir, "#{ext[:name]}.swift"))
  plist_file = group.new_file(File.join(source_dir, 'Info.plist'))
  entitlements_file = group.new_file(File.join(source_dir, "#{ext[:name]}.entitlements"))

  target = project.new_target(
    :app_extension,
    ext[:name],
    :ios,
    DEPLOYMENT_TARGET,
    nil,
    :swift,
  )

  target.build_configurations.each do |config|
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{MAIN_BUNDLE_ID}.#{ext[:bundle_suffix]}"
    config.build_settings['INFOPLIST_FILE'] = "#{ext[:name]}/Info.plist"
    config.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{ext[:name]}/#{ext[:name]}.entitlements"
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    config.build_settings['SKIP_INSTALL'] = 'YES'
    config.build_settings['MARKETING_VERSION'] =
      main_target.build_configurations.first.build_settings['MARKETING_VERSION'] || '1.0.0'
    config.build_settings['CURRENT_PROJECT_VERSION'] =
      main_target.build_configurations.first.build_settings['CURRENT_PROJECT_VERSION'] || '1'
    config.build_settings['CODE_SIGN_STYLE'] = main_target.build_configurations.first
                                                           .build_settings['CODE_SIGN_STYLE'] || 'Automatic'
    config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    # LD_RUNPATH_SEARCH_PATHS not needed: an app-extension Info.plist's
    # NSExtensionPointIdentifier is all the system needs to load it.
  end

  target.add_file_references([swift_file, shared_file_ref])
  # plist_file/entitlements_file are intentionally not added to any build
  # phase: INFOPLIST_FILE and CODE_SIGN_ENTITLEMENTS above reference them
  # by path directly. They're still added to the project group (above) so
  # they're visible/editable if anyone opens this in Xcode.

  # Dependency + embed, so building/archiving Runner always builds and
  # bundles the extension.
  main_target.add_dependency(target)
  embed_phase.add_file_reference(project.products_group.files.find { |f| f.path == "#{ext[:name]}.appex" })

  puts "Added target #{ext[:name]} (#{MAIN_BUNDLE_ID}.#{ext[:bundle_suffix]})"
end

project.save
puts 'Screen Time extension targets are set up.'
