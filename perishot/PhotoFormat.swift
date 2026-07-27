import UniformTypeIdentifiers

/// Image format used when writing a captured photo to disk.
enum PhotoFormat: String, CaseIterable {
    case heic
    case png
    case jpeg
    case tiff

    var title: String {
        switch self {
        case .heic: "HEIC"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        }
    }

    var utType: UTType {
        switch self {
        case .heic: .heic
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        }
    }

    var fileExtension: String {
        utType.preferredFilenameExtension ?? rawValue
    }
}
