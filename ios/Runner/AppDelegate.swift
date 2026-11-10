import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register AlarmKit MethodChannel bridge (no-ops / unavailable on
    // older iOS or SDKs without AlarmKit).
    if let registrar = self.registrar(forPlugin: "AlarmKitPlugin") {
      AlarmKitPlugin.register(with: registrar)
    }

    // App Guard (Screen Time shield). Degrades to "unsupported" on its own
    // when the Family Controls entitlement/SDK/OS version isn't available
    // (see AppGuardManager.swift) — safe to always register.
    if let registrar = self.registrar(forPlugin: "AppGuardManager") {
      AppGuardManager.register(with: registrar)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
