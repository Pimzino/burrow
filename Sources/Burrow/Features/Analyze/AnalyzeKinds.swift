import SwiftUI

/// What an analyzer entry is, for colour, symbol and wording.
enum AnalyzeKind: String, CaseIterable, Sendable {
    case folder, cleanable, app, image, video, audio, archive, document, code, data, other, group

    static func of(_ entry: AnalyzeReport.Entry) -> AnalyzeKind {
        if entry.cleanable == true { return .cleanable }
        let name = entry.displayName.lowercased()
        let ext = (name as NSString).pathExtension
        if ["app", "appex", "framework", "bundle", "plugin", "kext", "xpc"].contains(ext) { return .app }
        if entry.isDir { return ["photoslibrary", "musiclibrary", "tvlibrary"].contains(ext) ? .image : .folder }
        return of(fileName: name)
    }

    static func of(fileName name: String) -> AnalyzeKind {
        let ext = (name.lowercased() as NSString).pathExtension
        switch ext {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng",
             "webp", "psd", "svg", "bmp", "ico", "icns", "avif", "sketch", "fig", "afphoto", "pxd":
            return .image
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mpg", "mpeg", "prores", "braw", "r3d", "mxf", "fcpbundle":
            return .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "caf", "alac", "logicx", "band":
            return .audio
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "mpkg", "xip", "ipa", "apk",
             "sparseimage", "sparsebundle", "img", "zst":
            return .archive
        case "pdf", "doc", "docx", "pages", "key", "keynote", "numbers", "xls", "xlsx", "ppt", "pptx", "rtf", "epub",
             "txt", "md", "csv":
            return .document
        case "swift", "c", "h", "m", "mm", "cpp", "hpp", "js", "ts", "tsx", "jsx", "py", "go", "rs", "java", "kt", "rb",
             "php", "sh", "zsh", "json", "yml", "yaml", "xml", "html", "css":
            return .code
        case "db", "sqlite", "sqlite3", "realm", "store", "log", "bin", "dat", "vmdk", "vdi", "qcow2", "raw_disk",
             "asar", "pak", "cache", "gguf", "safetensors", "ckpt", "pt", "onnx", "mlmodel":
            return .data
        default:
            return .other
        }
    }

    var label: String {
        switch self {
        case .folder: "Folder"
        case .cleanable: "Cleanable"
        case .app: "App or bundle"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .archive: "Archive or disk image"
        case .document: "Document"
        case .code: "Source"
        case .data: "Data"
        case .other: "File"
        case .group: "Smaller items"
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .cleanable: "arrow.triangle.2.circlepath"
        case .app: "app.dashed"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .archive: "archivebox.fill"
        case .document: "doc.richtext.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .data: "cylinder.split.1x2.fill"
        case .other: "doc.fill"
        case .group: "square.grid.3x3.fill"
        }
    }

    /// Hue for file kinds (folders get a per-name hue instead).
    var hue: Double {
        switch self {
        case .folder: 0.74
        case .cleanable: 0.40
        case .app: 0.58
        case .image: 0.08
        case .video: 0.99
        case .audio: 0.90
        case .archive: 0.12
        case .document: 0.50
        case .code: 0.17
        case .data: 0.54
        case .other: 0.62
        case .group: 0.66
        }
    }
}

enum AnalyzePalette {
    /// Folders take a stable hue from their name within the analyzer's blue → violet → pink family.
    static func hue(forName name: String) -> Double {
        let h = XXHash64.hash(name)
        return 0.60 + Double(h % 1000) / 1000 * 0.36
    }

    static func base(for kind: AnalyzeKind, name: String, dark: Bool) -> (Double, Double, Double) {
        switch kind {
        case .folder:
            let h = hue(forName: name)
            let jitter = Double((XXHash64.hash(name) >> 20) % 100) / 100
            return (h.truncatingRemainder(dividingBy: 1), 0.52 + jitter * 0.18, dark ? 0.62 + jitter * 0.12 : 0.74 + jitter * 0.14)
        case .cleanable: return (0.40, 0.62, dark ? 0.62 : 0.72)
        case .other: return (0.62, 0.10, dark ? 0.48 : 0.66)
        case .group: return (0.66, 0.06, dark ? 0.36 : 0.80)
        default: return (kind.hue, 0.66, dark ? 0.72 : 0.86)
        }
    }

    static func color(for kind: AnalyzeKind, name: String, dark: Bool) -> Color {
        let (h, s, b) = base(for: kind, name: name, dark: dark)
        return Color(hue: h, saturation: s, brightness: b)
    }

    static func gradient(for kind: AnalyzeKind, name: String, dark: Bool, highlighted: Bool) -> LinearGradient {
        let (h, s, b) = base(for: kind, name: name, dark: dark)
        let lift = highlighted ? 0.10 : 0
        let top = Color(hue: h, saturation: max(0, s - 0.10), brightness: min(1, b + 0.10 + lift))
        let bottom = Color(hue: (h + 0.015).truncatingRemainder(dividingBy: 1), saturation: min(1, s + 0.08), brightness: max(0, b - 0.10 + lift))
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Explanations for the overview's "hidden space" rows (`cmd/analyze/insights.go`).
struct AnalyzeInsight {
    let symbol: String
    let tint: Color
    let explanation: String
    /// True when `mo clean` handles this location, so offering Clean makes sense.
    let cleanable: Bool

    static func forName(_ name: String) -> AnalyzeInsight {
        switch name {
        case "iOS Backups":
            AnalyzeInsight(symbol: "iphone.gen3", tint: .blue,
                           explanation: "Local iPhone and iPad backups made by Finder. Remove old devices' backups from Finder › your device › Manage Backups.",
                           cleanable: false)
        case let n where n.hasPrefix("Old Downloads"):
            AnalyzeInsight(symbol: "arrow.down.circle.fill", tint: .orange,
                           explanation: "Items in Downloads you haven't touched for 90 days or more. Only those old top-level items are counted.",
                           cleanable: false)
        case "System Logs":
            AnalyzeInsight(symbol: "list.bullet.rectangle.fill", tint: .gray,
                           explanation: "Diagnostic and app logs in ~/Library/Logs. Safe to trim; Mole's Clean removes old ones.",
                           cleanable: true)
        case "Homebrew Cache":
            AnalyzeInsight(symbol: "mug.fill", tint: .brown,
                           explanation: "Downloaded bottles and source archives Homebrew keeps after installing. They are re-downloaded if needed.",
                           cleanable: true)
        case "Xcode DerivedData":
            AnalyzeInsight(symbol: "hammer.fill", tint: .blue,
                           explanation: "Build products and indexes. Xcode rebuilds them on the next build, so this is safe to clear.",
                           cleanable: true)
        case "Xcode Simulators":
            AnalyzeInsight(symbol: "ipad.and.iphone", tint: .indigo,
                           explanation: "Simulator devices and their data. Unavailable runtimes' devices can be removed safely.",
                           cleanable: true)
        case "Xcode Archives":
            AnalyzeInsight(symbol: "archivebox.fill", tint: .teal,
                           explanation: "Archived app builds. Keep the ones you may need for symbolicating crash reports.",
                           cleanable: false)
        case "Spotify Cache":
            AnalyzeInsight(symbol: "music.note", tint: .green,
                           explanation: "Streamed music Spotify keeps offline. Spotify rebuilds it as you listen.",
                           cleanable: true)
        case "JetBrains Cache":
            AnalyzeInsight(symbol: "curlybraces", tint: .purple,
                           explanation: "IDE indexes and caches. JetBrains IDEs rebuild them when projects reopen.",
                           cleanable: true)
        case "Docker Data":
            AnalyzeInsight(symbol: "shippingbox.fill", tint: .cyan,
                           explanation: "Docker Desktop's virtual disk with images, containers and volumes. Prune from Docker itself.",
                           cleanable: false)
        case "pip Cache", "uv Cache":
            AnalyzeInsight(symbol: "cube.box.fill", tint: .yellow,
                           explanation: "Downloaded Python packages and wheels kept for faster installs. Safe to clear.",
                           cleanable: true)
        case "Gradle Cache":
            AnalyzeInsight(symbol: "square.stack.3d.up.fill", tint: .mint,
                           explanation: "Dependencies and build outputs cached by Gradle. They are re-downloaded when needed.",
                           cleanable: true)
        case "CocoaPods Cache":
            AnalyzeInsight(symbol: "leaf.fill", tint: .red,
                           explanation: "Pod sources cached by CocoaPods. Safe to clear; pods re-download on install.",
                           cleanable: true)
        case "OrbStack Data":
            AnalyzeInsight(symbol: "circle.hexagongrid.fill", tint: .purple,
                           explanation: "OrbStack's containers and machines. Manage it from OrbStack; Mole never touches it.",
                           cleanable: false)
        default:
            AnalyzeInsight(symbol: "lightbulb.fill", tint: .yellow,
                           explanation: "A location that often grows quietly.", cleanable: false)
        }
    }
}

/// The overview's four fixed rows.
struct AnalyzeLocationStyle {
    let symbol: String
    let color: Color
    let caption: String

    static func forName(_ name: String) -> AnalyzeLocationStyle {
        switch name {
        case "Home": AnalyzeLocationStyle(symbol: "house.fill", color: Color(red: 0.49, green: 0.33, blue: 1.0),
                                          caption: "Your files, excluding ~/Library")
        case "User Library": AnalyzeLocationStyle(symbol: "books.vertical.fill", color: Color(red: 0.85, green: 0.40, blue: 0.95),
                                                  caption: "App data, caches and containers")
        case "Applications": AnalyzeLocationStyle(symbol: "square.grid.2x2.fill", color: Color(red: 0.25, green: 0.52, blue: 1.0),
                                                  caption: "Installed apps in /Applications")
        case "System Library": AnalyzeLocationStyle(symbol: "building.columns.fill", color: Color(red: 0.98, green: 0.45, blue: 0.62),
                                                    caption: "Shared support files in /Library")
        default: AnalyzeLocationStyle(symbol: "folder.fill", color: .gray, caption: "")
        }
    }
}
