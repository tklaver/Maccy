import AppKit
import Sauce

class Clipboard {
  typealias OnNewCopyHook = (HistoryItem) -> Void

  public var onNewCopyHooks: [OnNewCopyHook] = []

  private let pasteboard = NSPasteboard.general
  private let timerInterval = 1.0

  // See http://nspasteboard.org for more details.
  private let ignoredTypes: Set = [
    "org.nspasteboard.TransientType",
    "org.nspasteboard.ConcealedType",
    "org.nspasteboard.AutoGeneratedType"
  ]

  private var changeCount: Int

  private let supportedTypes: Set = [
    NSPasteboard.PasteboardType.fileURL,
    NSPasteboard.PasteboardType.png,
    NSPasteboard.PasteboardType.string,
    NSPasteboard.PasteboardType.tiff
  ]
  private var enabledTypes: Set<NSPasteboard.PasteboardType> { UserDefaults.standard.enabledPasteboardTypes }
  private var disabledTypes: Set<NSPasteboard.PasteboardType> { supportedTypes.subtracting(enabledTypes) }

  private var accessibilityAlert: NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = NSLocalizedString("accessibility_alert_message", comment: "")
    alert.informativeText = NSLocalizedString("accessibility_alert_comment", comment: "")
    alert.addButton(withTitle: NSLocalizedString("accessibility_alert_deny", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("accessibility_alert_open", comment: ""))
    alert.icon = NSImage(named: "NSSecurity")
    return alert
  }
  private var accessibilityAllowed: Bool { AXIsProcessTrustedWithOptions(nil) }
  private let accessibilityURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  )

  init() {
    changeCount = pasteboard.changeCount
  }

  func onNewCopy(_ hook: @escaping OnNewCopyHook) {
    onNewCopyHooks.append(hook)
  }

  func startListening() {
    Timer.scheduledTimer(timeInterval: timerInterval,
                         target: self,
                         selector: #selector(checkForChangesInPasteboard),
                         userInfo: nil,
                         repeats: true)
  }

  func copy(_ item: HistoryItem, removeFormatting: Bool = false) {
    pasteboard.clearContents()
    var contents = item.getContents()

    if removeFormatting {
      let stringContents = contents.filter({
        NSPasteboard.PasteboardType($0.type) == .string
      })

      // If there is no string representation of data,
      // behave like we didn't have to remove formatting.
      if !stringContents.isEmpty {
        contents = stringContents
      }
    }

    for content in contents {
      pasteboard.setData(content.value, forType: NSPasteboard.PasteboardType(content.type))
    }

    if UserDefaults.standard.playSounds {
      NSSound(named: NSSound.Name("knock"))?.play()
    }
  }

  // Based on https://github.com/Clipy/Clipy/blob/develop/Clipy/Sources/Services/PasteService.swift.
  func paste() {
    guard accessibilityAllowed else {
      Maccy.returnFocusToPreviousApp = false
      // Show accessibility window async to allow menu to close.
      DispatchQueue.main.async(execute: showAccessibilityWindow)
      return
    }

    DispatchQueue.main.async {
      let vCode = Sauce.shared.keyCode(by: .v)
      let source = CGEventSource(stateID: .combinedSessionState)
      // Disable local keyboard events while pasting
      source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                         state: .eventSuppressionStateSuppressionInterval)

      let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: true)
      let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: false)
      keyVDown?.flags = .maskCommand
      keyVUp?.flags = .maskCommand
      keyVDown?.post(tap: .cgAnnotatedSessionEventTap)
      keyVUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
  }

  @objc
  func checkForChangesInPasteboard() {
    guard pasteboard.changeCount != changeCount else {
      return
    }

    if UserDefaults.standard.ignoreEvents {
      return
    }

    // Some applications add 2 items to pasteboard when copying:
    //   1. The proper meaningful string.
    //   2. The empty item with no data and types.
    // An example of such application is BBEdit.
    // To handle such cases, handle all new pasteboard items,
    // not only the last one.
    // See https://github.com/p0deje/Maccy/issues/78.
    pasteboard.pasteboardItems?.forEach({ item in
      // Reading types on NSPasteboard gives all the available
      // types - even the ones that are not present on the NSPasteboardItem.
      // See https://github.com/p0deje/Maccy/issues/241.
      if shouldIgnore(Set(pasteboard.types ?? [])) {
        return
      }

      let types = Set(item.types)
      if types.contains(.string) && isEmptyString(item) {
        return
      }

      let contents = types.subtracting(disabledTypes).map({ type in
        return HistoryItemContent(type: type.rawValue, value: item.data(forType: type))
      })
      let historyItem = HistoryItem(contents: contents)

      onNewCopyHooks.forEach({ $0(historyItem) })
    })

    changeCount = pasteboard.changeCount
  }

  private func shouldIgnore(_ types: Set<NSPasteboard.PasteboardType>) -> Bool {
    let ignoredTypes = self.ignoredTypes
      .union(UserDefaults.standard.ignoredPasteboardTypes)
      .map({ NSPasteboard.PasteboardType($0) })
    return types.isDisjoint(with: enabledTypes) ||
      !types.isDisjoint(with: ignoredTypes)
  }

  private func isEmptyString(_ item: NSPasteboardItem) -> Bool {
    guard let string = item.string(forType: .string) else {
      return true
    }

    return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func showAccessibilityWindow() {
    if accessibilityAlert.runModal() == NSApplication.ModalResponse.alertSecondButtonReturn {
      if let url = accessibilityURL {
        NSWorkspace.shared.open(url)
      }
    }
  }
}
