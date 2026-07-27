import AppKit
import UniformTypeIdentifiers

@main
enum Perishot {
    static func main() {
        // A second copy would add a second, identical status item. LaunchServices
        // only prevents that for repeat launches of the same bundle on disk.
        guard !isAlreadyRunning else { return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    private static var isAlreadyRunning: Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != pid }
    }
}

/// Menu bar controller. Capture is requested straight from the connected iOS
/// device via `SidecarImport`; the photo comes back through
/// `readSelection(from:)` once the shutter fires on the device.
final class AppDelegate: NSResponder, NSApplicationDelegate, NSMenuDelegate, NSServicesMenuRequestor {
    private enum Destination {
        case copy
        case save
    }

    private static let formatKey = "SaveFormat"
    private static let idleSymbol = "camera.on.rectangle"
    private static let successSymbol = "checkmark.circle.fill"

    /// A top-level "Take Photo and …" entry. It fires directly when one device
    /// is connected, and grows a device submenu when several are.
    private struct CaptureEntry {
        let item: NSMenuItem
        let destination: Destination
    }

    /// What a capture, once it comes back, should do and which device runs it.
    private struct CaptureRequest {
        let destination: Destination
        let device: SidecarImport.CaptureDevice
    }

    private var statusItem: NSStatusItem!
    private var captureEntries: [CaptureEntry] = []
    private var noDeviceItem: NSMenuItem!
    private var formatItems: [NSMenuItem] = []
    private var flashTask: Task<Void, Never>?

    /// Set when a capture is requested, read when the photo comes back.
    private var destination: Destination = .copy

    private var format: PhotoFormat {
        get { PhotoFormat(rawValue: UserDefaults.standard.string(forKey: Self.formatKey) ?? "") ?? .heic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.formatKey) }
    }

    private var saveDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("Perishot", isDirectory: true)
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.registerServicesMenuSendTypes([], returnTypes: NSImage.imageTypes.map(NSPasteboard.PasteboardType.init(rawValue:)))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: Self.idleSymbol, accessibilityDescription: "Perishot")
        statusItem.menu = makeMenu()
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        captureEntries = [
            makeCaptureEntry(title: "Take Photo and Copy", destination: .copy),
            makeCaptureEntry(title: "Take Photo and Save", destination: .save),
        ]
        captureEntries.forEach { menu.addItem($0.item) }

        noDeviceItem = NSMenuItem(title: "No iPhone or iPad Available", action: nil, keyEquivalent: "")
        noDeviceItem.isEnabled = false
        noDeviceItem.isHidden = true
        menu.addItem(noDeviceItem)
        menu.addItem(.separator())

        let formatMenu = NSMenu()
        formatMenu.autoenablesItems = false
        formatItems = PhotoFormat.allCases.map { photoFormat in
            let item = NSMenuItem(title: photoFormat.title, action: #selector(selectFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = photoFormat
            item.state = photoFormat == format ? .on : .off
            formatMenu.addItem(item)
            return item
        }
        let formatItem = NSMenuItem(title: "Save Format", action: nil, keyEquivalent: "")
        formatItem.submenu = formatMenu
        menu.addItem(formatItem)

        let folderItem = NSMenuItem(title: "Open Save Folder", action: #selector(openSaveFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Perishot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func makeCaptureEntry(title: String, destination: Destination) -> CaptureEntry {
        let item = NSMenuItem(title: title, action: #selector(takePhoto(_:)), keyEquivalent: "")
        item.target = self
        return CaptureEntry(item: item, destination: destination)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let devices = SidecarImport.photoDevices(for: self)
        captureEntries.forEach { configure($0, devices: devices) }
        noDeviceItem.isHidden = !devices.isEmpty
        noDeviceItem.title = SidecarImport.isSupported ? "No iPhone or iPad Available" : "Device Import Unavailable"
    }

    private func configure(_ entry: CaptureEntry, devices: [SidecarImport.CaptureDevice]) {
        entry.item.isEnabled = !devices.isEmpty

        guard devices.count > 1 else {
            entry.item.submenu = nil
            entry.item.representedObject = devices.first.map {
                CaptureRequest(destination: entry.destination, device: $0)
            }
            return
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(takePhoto(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CaptureRequest(destination: entry.destination, device: device)
            submenu.addItem(item)
        }
        entry.item.submenu = submenu
    }

    @objc private func selectFormat(_ sender: NSMenuItem) {
        guard let selected = sender.representedObject as? PhotoFormat else { return }
        format = selected
        for item in formatItems {
            item.state = (item.representedObject as? PhotoFormat) == selected ? .on : .off
        }
    }

    @objc private func openSaveFolder() {
        do {
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(saveDirectory)
        } catch {
            present(error)
        }
    }

    // MARK: - Capture

    @objc private func takePhoto(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? CaptureRequest else {
            present(CaptureError.deviceUnavailable)
            return
        }
        destination = request.destination
        request.device.capture(with: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, NSImage.imageTypes.contains(returnType.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(pasteboard: pasteboard) else { return false }

        switch destination {
        case .copy:
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([image]) else { return false }
            flashSuccess()
            return true
        case .save:
            return save(image)
        }
    }

    private func save(_ image: NSImage) -> Bool {
        let name = "Perishot \(Self.filenameFormatter.string(from: Date())).\(format.fileExtension)"
        do {
            let data = try encode(image, as: format)
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            try data.write(to: saveDirectory.appendingPathComponent(name))
            flashSuccess()
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func encode(_ image: NSImage, as format: PhotoFormat) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CaptureError.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.encodingFailed
        }
        return data as Data
    }

    // MARK: - Feedback

    private func flashSuccess() {
        flashTask?.cancel()
        statusItem.button?.image = NSImage(systemSymbolName: Self.successSymbol, accessibilityDescription: "Photo captured")
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            statusItem.button?.image = NSImage(systemSymbolName: Self.idleSymbol, accessibilityDescription: "Perishot")
        }
    }

    private func present(_ error: Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}

enum CaptureError: LocalizedError {
    case deviceUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "No iPhone or iPad is available for capture."
        case .encodingFailed: "Perishot could not encode the photo."
        }
    }
}
