import Flutter
import Foundation
import UIKit
import UniformTypeIdentifiers

final class SessionTransferBridge: NSObject, UIDocumentPickerDelegate {
  private let runtime: RecordingRuntime
  private let queue = DispatchQueue(
    label: "org.hohu.momentai.product.transfer", qos: .userInitiated)
  private var importer: SessionImporter?
  private var pickerResult: FlutterResult?
  private var busy = false

  init(messenger: FlutterBinaryMessenger, runtime: RecordingRuntime = .shared) {
    self.runtime = runtime
    super.init()
    let channel = FlutterMethodChannel(
      name: "org.hohu.momentai.product/transfer", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard !busy else {
      result(
        error(
          SessionImportError(
            NativeStrings.text("native_a_share_or_import_is_already_in_progress_50"))))
      return
    }
    if call.method == "cancelImport" {
      busy = true
      queue.async {
        self.importer?.cancel()
        DispatchQueue.main.async {
          self.busy = false
          result(nil)
        }
      }
      return
    }
    guard runtime.activeDirectoryPath() == nil else {
      result(
        error(
          SessionImportError(
            NativeStrings.text(
              "native_finish_the_current_recording_safely_before_sharing_or_importing_51"))))
      return
    }
    if call.method == "pickImport" {
      guard let presenter = topPresenter() else {
        result(
          error(SessionImportError(NativeStrings.text("native_could_not_open_the_file_picker_191")))
        )
        return
      }
      busy = true
      pickerResult = result
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(
          forOpeningContentTypes: [UTType("org.hohu.momentai.archive") ?? .data], asCopy: false)
      } else {
        picker = UIDocumentPickerViewController(
          documentTypes: ["org.hohu.momentai.archive"], in: .open)
      }
      picker.allowsMultipleSelection = false
      picker.delegate = self
      presenter.present(picker, animated: true)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    guard ["commitImport", "shareSession", "readSessionText"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    busy = true
    queue.async {
      do {
        if call.method == "commitImport" {
          guard let token = args["token"] as? String, let importer = self.importer else {
            throw SessionImportError(
              NativeStrings.text("native_no_import_is_awaiting_confirmation_192"))
          }
          let value = try importer.commit(token: token, asCopy: args["asCopy"] as? Bool ?? false)
          DispatchQueue.main.async {
            self.busy = false
            result(value)
          }
        } else {
          guard let id = args["sessionId"] as? String else {
            throw SessionImportError(
              NativeStrings.text("native_share_parameters_are_incomplete_193"))
          }
          let repository = ProductSessionRepository(
            rootURLProvider: { try self.runtime.sessionRootURL() },
            activeDirectoryProvider: { self.runtime.activeDirectoryPath() })
          let summary = try repository.session(sessionID: id)
          if call.method == "readSessionText" {
            let text = try SessionExporter().readShareText(
              directoryPath: summary["directory"] as! String,
              readingText: args["readingText"] as? String)
            DispatchQueue.main.async {
              self.busy = false
              result(text)
            }
            return
          }
          guard let format = args["format"] as? String else {
            throw SessionImportError(
              NativeStrings.text("native_share_parameters_are_incomplete_193"))
          }
          let path = try SessionExporter().exportShare(
            directoryPath: summary["directory"] as! String, format: format,
            readingText: args["readingText"] as? String)
          DispatchQueue.main.async { self.presentShare(path, format: format, result: result) }
        }
      } catch {
        DispatchQueue.main.async {
          self.busy = false
          result(self.error(error))
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pickerResult?(nil)
    pickerResult = nil
    busy = false
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    guard let result = pickerResult else { return }
    pickerResult = nil
    guard let url = urls.first else {
      busy = false
      result(nil)
      return
    }
    queue.async {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        if self.importer == nil {
          self.importer = SessionImporter(root: try self.runtime.sessionRootURL())
        }
        var outcome: Result<[String: Any], Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
          readingItemAt: url, options: .withoutChanges, error: &coordinationError
        ) { readable in
          outcome = Result { try self.importer!.prepare(archive: readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else {
          throw SessionImportError(
            NativeStrings.text("native_the_file_provider_returned_no_readable_content_194"))
        }
        let preview = try outcome.get()
        DispatchQueue.main.async {
          self.busy = false
          result(preview)
        }
      } catch {
        DispatchQueue.main.async {
          self.busy = false
          result(self.error(error))
        }
      }
    }
  }

  private func presentShare(_ url: URL, format: String, result: @escaping FlutterResult) {
    guard let presenter = topPresenter() else {
      busy = false
      try? FileManager.default.removeItem(at: url)
      result(
        error(SessionImportError(NativeStrings.text("native_could_not_open_system_sharing_195"))))
      return
    }
    // Text is a TXT attachment, not an NSString rejected by some share extensions.
    let item: Any = format == "text" ? SessionTextFileActivityItem(url: url) : url
    let share = UIActivityViewController(activityItems: [item], applicationActivities: nil)
    if let popover = share.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    // Keep the generated file alive until the receiving activity finishes.
    share.completionWithItemsHandler = { _, _, _, error in
      try? FileManager.default.removeItem(at: url)
      self.busy = false
      if let error { result(self.error(error)) } else { result(nil) }
    }
    presenter.present(share, animated: true)
  }

  private func topPresenter() -> UIViewController? {
    var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }
  private func error(_ error: Error) -> FlutterError {
    FlutterError(code: "SessionTransferError", message: error.localizedDescription, details: nil)
  }
}

final class SessionTextFileActivityItem: NSObject, UIActivityItemSource {
  let url: URL

  init(url: URL) {
    self.url = url
    super.init()
  }

  func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController)
    -> Any
  {
    url
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController,
    itemForActivityType activityType: UIActivity.ActivityType?
  ) -> Any? {
    // Placeholder and final payload must both be file URLs for every destination.
    url
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController,
    dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
  ) -> String {
    "public.plain-text"
  }
}
