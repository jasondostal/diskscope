import Foundation

/// Color files by *category* (not raw extension) in OKLCH — perceptually uniform, so the
/// hues sit at even visual spacing and matched lightness/chroma, which reads calm on a dark
/// background instead of the vibrating full-saturation HSL rainbow. Dark-first by design.
public enum FilePalette {

    public struct OKLCH: Equatable, Sendable {
        public var L: Double  // perceptual lightness 0…1
        public var C: Double  // chroma (~0…0.37)
        public var H: Double  // hue degrees
        public init(_ L: Double, _ C: Double, _ H: Double) { self.L = L; self.C = C; self.H = H }
        public func lightened(_ d: Double) -> OKLCH { OKLCH(min(1, max(0, L + d)), C, H) }
    }

    public enum Category: String, CaseIterable, Sendable {
        case code, web, image, video, audio, archive, document, data, binary, system, other
    }

    /// Base OKLCH per category — even hue spacing, moderate chroma, dark-tuned lightness.
    public static func oklch(_ cat: Category) -> OKLCH {
        // Muted jewel tones: low chroma, mid lightness — calm on a dark canvas. Hues stay
        // evenly spaced so categories remain distinguishable without shouting.
        switch cat {
        case .code:     return OKLCH(0.66, 0.085, 256) // blue
        case .web:      return OKLCH(0.70, 0.075, 195) // cyan
        case .image:    return OKLCH(0.66, 0.095, 350) // pink
        case .video:    return OKLCH(0.63, 0.105,  32) // red-orange
        case .audio:    return OKLCH(0.70, 0.085, 145) // green
        case .archive:  return OKLCH(0.74, 0.090,  95) // amber
        case .document: return OKLCH(0.66, 0.085, 305) // violet
        case .data:     return OKLCH(0.70, 0.075, 172) // teal
        case .binary:   return OKLCH(0.67, 0.095,  58) // orange
        case .system:   return OKLCH(0.50, 0.020, 256) // dim slate
        case .other:    return OKLCH(0.58, 0.022, 250) // neutral gray-blue
        }
    }

    public static func oklch(forExt e: String) -> OKLCH { oklch(category(forExt: e)) }
    public static func category(forExt e: String) -> Category { extCategory[e] ?? .other }

    /// Human description for the legend (WinDirStat's "Description" column).
    public static func description(forExt e: String) -> String {
        if e.isEmpty { return "No extension" }
        if let known = extDescription[e] { return known }
        return "\(e.uppercased()) file"
    }

    private static let extDescription: [String: String] = [
        "swift": "Swift source", "py": "Python source", "js": "JavaScript", "ts": "TypeScript",
        "c": "C source", "h": "C header", "cpp": "C++ source", "go": "Go source", "rs": "Rust source",
        "java": "Java source", "rb": "Ruby source", "sh": "Shell script", "json": "JSON data",
        "html": "HTML document", "css": "Stylesheet", "svg": "SVG image", "xml": "XML document",
        "yaml": "YAML config", "yml": "YAML config", "toml": "TOML config", "md": "Markdown",
        "png": "PNG image", "jpg": "JPEG image", "jpeg": "JPEG image", "gif": "GIF image",
        "heic": "HEIC image", "webp": "WebP image", "tiff": "TIFF image", "psd": "Photoshop",
        "mp4": "MP4 video", "mov": "QuickTime video", "mkv": "Matroska video", "avi": "AVI video",
        "webm": "WebM video", "mp3": "MP3 audio", "wav": "WAV audio", "flac": "FLAC audio",
        "aac": "AAC audio", "m4a": "M4A audio", "zip": "ZIP archive", "gz": "Gzip archive",
        "tar": "Tar archive", "7z": "7-Zip archive", "rar": "RAR archive", "dmg": "Disk image",
        "pkg": "Installer package", "pack": "Git pack", "pdf": "PDF document", "doc": "Word document",
        "docx": "Word document", "txt": "Plain text", "csv": "CSV data", "db": "Database",
        "sqlite": "SQLite database", "pkl": "Python pickle", "parquet": "Parquet data", "log": "Log file",
        "o": "Object file", "a": "Static library", "so": "Shared library", "dylib": "Dynamic library",
        "wasm": "WebAssembly", "pyc": "Python bytecode", "plist": "Property list", "framework": "Framework",
    ]

    /// sRGB (0…1) for a category's base color.
    public static func srgb(_ c: OKLCH) -> (r: Double, g: Double, b: Double) { oklchToSRGB(c) }
    public static func srgb(forExt e: String) -> (r: Double, g: Double, b: Double) { srgb(oklch(forExt: e)) }

    /// "#rrggbb" for the SVG renderer.
    public static func hex(forExt e: String) -> String {
        let c = srgb(forExt: e)
        func h(_ v: Double) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#\(h(c.r))\(h(c.g))\(h(c.b))"
    }

    // MARK: - Extension → category

    private static let extCategory: [String: Category] = {
        var m: [String: Category] = [:]
        func add(_ cat: Category, _ exts: [String]) { for e in exts { m[e] = cat } }
        add(.code, ["swift","py","js","ts","tsx","jsx","c","h","cpp","cc","hpp","m","mm","go","rs","java","kt","rb","php","cs","scala","clj","ex","exs","lua","pl","r","jl","dart","sh","bash","zsh","fish","vim"])
        add(.web, ["html","htm","css","scss","sass","less","svg","json","xml","yaml","yml","toml","graphql"])
        add(.image, ["png","jpg","jpeg","gif","heic","heif","webp","tiff","tif","bmp","ico","raw","cr2","nef","psd","ai"])
        add(.video, ["mp4","mov","mkv","avi","webm","flv","wmv","m4v","mpg","mpeg","3gp"])
        add(.audio, ["mp3","wav","flac","aac","m4a","ogg","opus","aiff","alac","wma","mid"])
        add(.archive, ["zip","gz","tar","tgz","7z","rar","xz","bz2","zst","pack","dmg","pkg","iso","cab"])
        add(.document, ["pdf","doc","docx","md","txt","rtf","pages","epub","mobi","odt","tex","key","ppt","pptx","xls","xlsx","numbers","csv"])
        add(.data, ["db","sqlite","sqlite3","pkl","parquet","dat","bin","idx","model","npy","npz","h5","arrow","feather","log"])
        add(.binary, ["o","a","so","dylib","exe","wasm","framework","bundle","class","pyc","obj","lib"])
        add(.system, ["plist","cache","lock","tmp","ds_store","localized","pid","sock"])
        return m
    }()

    // MARK: - OKLCH → sRGB (Björn Ottosson's OKLab)

    private static func oklchToSRGB(_ c: OKLCH) -> (r: Double, g: Double, b: Double) {
        let hr = c.H * .pi / 180
        let a = c.C * cos(hr), b = c.C * sin(hr)
        let l_ = c.L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = c.L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = c.L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (gamma(r), gamma(g), gamma(bb))
    }

    private static func gamma(_ x: Double) -> Double {
        let v = max(0, min(1, x))
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}
