import AppKit

// SPI: SidecarUI.framework backs AppKit's "Import from iPhone" menu item. Going
// through it directly avoids that item's constraint of only ever expanding
// inside the main menu.

@objc private protocol SidecarMenuController {
    @objc(updateMenu:withEvent:withFlags:withResponder:)
    func update(_ menu: NSMenu, event: NSEvent?, flags: UInt, responder: NSResponder?)
}

@objc private protocol SidecarServiceAction {
    /// Unlocalized service name, e.g. `SidecarServiceNameTakePhoto`.
    var title: String? { get }
    var sidecarService: NSObject? { get }

    /// Runs the capture on the device; the result arrives as
    /// `readSelection(from:)` on `responder`.
    @objc(invokeWithResponder:)
    func invoke(responder: NSResponder)
}

@objc private protocol SidecarService {
    var devices: [NSObject]? { get }

    /// A copy of the service aimed at one device rather than the default.
    @objc(copyWithDevice:)
    func copy(device: NSObject) -> NSObject?
}

@objc private protocol SidecarDevice {
    var name: String? { get }
}

enum SidecarImport {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/SidecarUI.framework/Versions/A/SidecarUI"
    private static let takePhotoService = "SidecarServiceNameTakePhoto"

    /// A device that can take a photo, and the action that asks it to.
    struct CaptureDevice {
        let name: String
        fileprivate let action: SidecarServiceAction

        func capture(with responder: NSResponder) {
            action.invoke(responder: responder)
        }
    }

    private static let controller: SidecarMenuController? = {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let controllerClass = NSClassFromString("SidecarMenuController") as? NSObject.Type,
              let shared = controllerClass.perform(NSSelectorFromString("sharedController"))?.takeUnretainedValue()
        else { return nil }
        return unsafeBitCast(shared, to: SidecarMenuController.self)
    }()

    static var isSupported: Bool { controller != nil }

    /// Every connected iPhone or iPad that can take a photo, in the order the
    /// system reports them.
    static func photoDevices(for responder: NSResponder) -> [CaptureDevice] {
        guard let action = takePhotoAction(for: responder) else { return [] }
        guard let serviceObject = action.sidecarService else { return [] }

        let service = unsafeBitCast(serviceObject, to: SidecarService.self)
        let devices = service.devices ?? []

        // The default action already targets the only device.
        guard devices.count > 1 else {
            guard let device = devices.first else { return [] }
            let name = unsafeBitCast(device, to: SidecarDevice.self).name ?? "iPhone"
            return [CaptureDevice(name: name, action: action)]
        }

        return devices.compactMap { device in
            guard let name = unsafeBitCast(device, to: SidecarDevice.self).name,
                  let targeted = service.copy(device: device),
                  let action = makeAction(for: targeted)
            else { return nil }
            return CaptureDevice(name: name, action: action)
        }
    }

    private static func takePhotoAction(for responder: NSResponder) -> SidecarServiceAction? {
        guard let controller else { return nil }

        let menu = NSMenu()
        controller.update(menu, event: nil, flags: 0, responder: responder)

        return menu.items.lazy
            .compactMap { $0.representedObject as? NSObject }
            .map { unsafeBitCast($0, to: SidecarServiceAction.self) }
            .first { $0.title == takePhotoService }
    }

    private static func makeAction(for service: NSObject) -> SidecarServiceAction? {
        guard let actionClass = NSClassFromString("SidecarServiceAction") as? NSObject.Type,
              let allocated = actionClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let initialized = allocated.perform(NSSelectorFromString("initWithService:"), with: service)?.takeRetainedValue()
        else { return nil }
        return unsafeBitCast(initialized, to: SidecarServiceAction.self)
    }
}
