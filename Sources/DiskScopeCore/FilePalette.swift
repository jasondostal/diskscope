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
        case code, web, image, video, audio, archive, document, data, model, model3d, binary, system, other
    }

    /// Representative categories for a legend/theme swatch preview.
    public static let previewCategories: [Category] =
        [.code, .web, .image, .video, .audio, .archive, .document, .data, .model, .model3d, .binary, .other]

    /// Base OKLCH per category — even hue spacing, dark-tuned lightness, and enough chroma to
    /// read as real color on the treemap (the tiles are the point; the palette should sing, not
    /// whisper). Hues stay roughly evenly spaced so categories remain distinguishable.
    public static func oklch(_ cat: Category) -> OKLCH {
        switch cat {
        case .code:     return OKLCH(0.68, 0.130, 256) // blue
        case .web:      return OKLCH(0.74, 0.115, 195) // cyan
        case .image:    return OKLCH(0.70, 0.150, 350) // pink
        case .video:    return OKLCH(0.66, 0.165,  32) // red-orange
        case .audio:    return OKLCH(0.74, 0.140, 145) // green
        case .archive:  return OKLCH(0.78, 0.140,  95) // gold
        case .document: return OKLCH(0.70, 0.130, 305) // violet
        case .data:     return OKLCH(0.74, 0.120, 172) // teal
        case .model:    return OKLCH(0.70, 0.170, 328) // magenta — ML weights (often the giants)
        case .model3d:  return OKLCH(0.68, 0.150, 268) // indigo — 3D / print
        case .binary:   return OKLCH(0.70, 0.140,  58) // orange
        case .system:   return OKLCH(0.55, 0.030, 256) // dim slate
        case .other:    return OKLCH(0.62, 0.045, 250) // muted blue-grey (still has a pulse)
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
        "safetensors": "Model weights", "gguf": "GGUF model", "ggml": "GGML model", "ckpt": "Model checkpoint",
        "pt": "PyTorch weights", "pth": "PyTorch weights", "onnx": "ONNX model", "mlmodel": "Core ML model",
        "mlpackage": "Core ML package", "tflite": "TensorFlow Lite", "bin": "Binary / model weights",
        "stl": "3D model (STL)", "obj": "3D model (OBJ)", "3mf": "3D print (3MF)", "gcode": "G-code (print)",
        "step": "CAD (STEP)", "stp": "CAD (STEP)", "blend": "Blender scene", "gltf": "glTF 3D scene",
        "glb": "glTF 3D (binary)", "scad": "OpenSCAD", "fbx": "FBX 3D model", "usdz": "USDZ 3D",
        "ipynb": "Jupyter notebook", "h5": "HDF5 data", "npy": "NumPy array",
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
        add(.code, ["swift","py","js","ts","tsx","jsx","c","h","cpp","cc","hpp","m","mm","go","rs","java","kt","rb","php","cs","scala","clj","ex","exs","lua","pl","r","jl","dart","sh","bash","zsh","fish","vim","ipynb","sql"])
        add(.web, ["html","htm","css","scss","sass","less","svg","json","jsonl","ndjson","xml","yaml","yml","toml","graphql"])
        add(.image, ["png","jpg","jpeg","gif","heic","heif","webp","tiff","tif","bmp","ico","raw","cr2","nef","dng","psd","ai","avif"])
        add(.video, ["mp4","mov","mkv","avi","webm","flv","wmv","m4v","mpg","mpeg","3gp","prores"])
        add(.audio, ["mp3","wav","flac","aac","m4a","ogg","opus","aiff","alac","wma","mid","aif"])
        add(.archive, ["zip","gz","tar","tgz","7z","rar","xz","bz2","zst","pack","dmg","pkg","iso","cab","img","vmdk","qcow2","sparseimage","sparsebundle"])
        add(.document, ["pdf","doc","docx","md","txt","rtf","pages","epub","mobi","odt","tex","key","ppt","pptx","xls","xlsx","numbers","csv","tsv"])
        add(.data, ["db","sqlite","sqlite3","wal","pkl","parquet","dat","idx","npy","npz","h5","hdf5","arrow","feather","log"])
        // ML model weights / checkpoints — frequently the largest files on a disk.
        add(.model, ["safetensors","gguf","ggml","ckpt","pt","pth","onnx","pb","mlmodel","mlpackage","mlmodelc","tflite","bin","caffemodel","params"])
        // 3D models / printing / CAD.
        add(.model3d, ["stl","obj","3mf","gcode","step","stp","ply","fbx","dae","blend","gltf","glb","3ds","scad","amf","usdz"])
        add(.binary, ["o","a","so","dylib","exe","wasm","framework","bundle","class","pyc","lib"])
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

    // MARK: - sRGB → OKLCH (inverse of the above) — lets themes be authored from familiar hex.

    /// sRGB (0…1) → OKLCH.
    public static func oklch(fromSRGB c: (r: Double, g: Double, b: Double)) -> OKLCH {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        let C = (a * a + bb * bb).squareRoot()
        var H = atan2(bb, a) * 180 / .pi
        if H < 0 { H += 360 }
        return OKLCH(L, C, H)
    }

    /// Parse "#rrggbb" (or "rrggbb") → sRGB (0…1). Invalid input → mid-grey.
    public static func srgb(hex: String) -> (r: Double, g: Double, b: Double) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0.5, 0.5, 0.5) }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    /// Parse "#rrggbb" → OKLCH.
    public static func oklch(hex: String) -> OKLCH { oklch(fromSRGB: srgb(hex: hex)) }
}
