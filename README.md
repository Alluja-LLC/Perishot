# Perishot

A macOS menu bar app that takes a photo with a connected iPhone or iPad and either copies it
to the clipboard or saves it to disk.

```
📷 ─ Take Photo and Copy
     Take Photo and Save
     ─────
     Save Format ▸ HEIC • PNG • JPEG • TIFF
     Open Save Folder
     ─────
     Quit Perishot
```

Photos are saved to `~/Pictures/Perishot`. The format setting applies to saving; copying puts a
standard bitmap on the clipboard so it pastes anywhere. With more than one device connected,
each entry grows a submenu to pick which one takes the photo.

## Requirements

- macOS 26 or later (developed and tested on 26.3.1)
- An iPhone or iPad eligible for Continuity Camera: same Apple Account, Wi-Fi and Bluetooth on

## How it works

AppKit exposes Continuity Camera capture through `NSMenuItem.importFromDeviceIdentifier` — set
that identifier on a menu item and AppKit expands it into a device submenu. That mechanism is
unusable for a menu bar app:

- AppKit only expands items that live in `NSApp.mainMenu`. Items in an `NSStatusItem` menu are
  ignored outright.
- Only the **first** such item in any given menu is expanded, so two entries cannot both be
  capture items.
- AppKit overwrites the item's title with its own ("Import from iPhone").

So Perishot skips the menu item and calls the machinery behind it directly, in
[`SidecarImport.swift`](perishot/SidecarImport.swift). From `SidecarUI.framework`:

| Symbol | Use |
| --- | --- |
| `SidecarMenuController.sharedController` | Entry point |
| `-updateMenu:withEvent:withFlags:withResponder:` | Populates a throwaway `NSMenu` with the live device services, without displaying anything |
| `SidecarServiceAction` | One service; identified by unlocalized `title` (`SidecarServiceNameTakePhoto`, `…ScanDocument`, `…Sketch`) |
| `-invokeWithResponder:` | Runs the capture |
| `SidecarService.devices` | Connected `SidecarDevice`s (`name`, `identifier`, `model`) |
| `-copyWithDevice:` + `SidecarServiceAction -initWithService:` | Builds an action aimed at one specific device |

The captured photo arrives through the public `NSServicesMenuRequestor` path: the app delegate
returns itself from `validRequestor(forSendType:returnType:)` and receives the image in
`readSelection(from:)`.

**This relies on private API and can break with any macOS update.** It degrades to a disabled
menu reading "Device Import Unavailable" rather than crashing.

## Building

```sh
open perishot.xcodeproj   # then ⌘R
```

## Releasing

`scripts/release.sh` archives, exports with Developer ID, notarizes, staples, and produces a
distributable zip. One-time setup:

1. Create a **Developer ID Application** certificate: Xcode → Settings → Accounts → Alluja LLC →
   Manage Certificates → + (requires Account Holder or Admin on the team).
2. Store notarization credentials:
   ```sh
   xcrun notarytool store-credentials perishot-notary \
     --apple-id <apple-id> --team-id Z74U5327X4 --password <app-specific-password>
   ```

Then `./scripts/release.sh`.

Notarization checks signing and scans for malware; it does not review API usage, so the private
framework dependency does not affect it.
