import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var poCBridge: PoCBridge?
  private var productSessionRepositoryBridge: ProductSessionRepositoryBridge?
  private var sessionTransferBridge: SessionTransferBridge?
  private var modelCenterChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let localizationChannel = FlutterMethodChannel(
      name: "org.hohu.momentai.localization", binaryMessenger: messenger)
    localizationChannel.setMethodCallHandler { call, result in
      guard call.method == "setLanguage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      let language = arguments?["language"] as? String ?? "system"
      guard ["system", "zh", "en"].contains(language) else {
        result(
          FlutterError(code: "invalid_language", message: "Unsupported language", details: nil))
        return
      }
      UserDefaults.standard.set(language, forKey: "appLanguage")
      result(nil)
    }
    poCBridge = PoCBridge(messenger: messenger)
    productSessionRepositoryBridge = ProductSessionRepositoryBridge(messenger: messenger)
    sessionTransferBridge = SessionTransferBridge(messenger: messenger)
    let modelChannel = FlutterMethodChannel(
      name: "momentai/model_center",
      binaryMessenger: messenger
    )
    modelChannel.setMethodCallHandler { call, result in
      guard call.method == "availableStorageBytes" || call.method == "prepareModelStorage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        !path.isEmpty
      else {
        result(
          FlutterError(
            code: "invalid_path",
            message: "A model storage path is required.",
            details: nil
          )
        )
        return
      }
      if call.method == "prepareModelStorage" {
        do {
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          var url = URL(fileURLWithPath: path, isDirectory: true)
          try url.setResourceValues(values)
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "storage_prepare_failed",
              message: "Unable to exclude model storage from backup.",
              details: String(describing: error)
            )
          )
        }
        return
      }
      do {
        let values = try URL(fileURLWithPath: path).resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        )
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
          result(capacity)
        } else if let capacity = values.volumeAvailableCapacity {
          result(Int64(capacity))
        } else {
          result(nil)
        }
      } catch {
        result(
          FlutterError(
            code: "storage_failed",
            message: "Unable to read available storage.",
            details: String(describing: error)
          )
        )
      }
    }
    modelCenterChannel = modelChannel
  }

  func attachPresenter(_ viewController: UIViewController?) {
    poCBridge?.setPresenter(viewController)
  }
}

/// App-owned native UI follows the Flutter preference. System permission dialogs
/// use the app language selected by iOS and the localized InfoPlist resources.
enum NativeStrings {
  static func text(_ key: String, _ arguments: CVarArg...) -> String {
    let preference = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    let language = preference == "system" ? (Locale.preferredLanguages.first ?? "en") : preference
    let code = language.hasPrefix("zh") ? "zh-Hans" : "en"
    let bundle =
      Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
      ?? Bundle.main
    let format = bundle.localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, locale: Locale(identifier: code), arguments: arguments)
  }
}
