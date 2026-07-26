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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
