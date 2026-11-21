import Foundation

/// Paths, limits and skip rules.
public enum Config {
    public static let home = URL(fileURLWithPath: NSHomeDirectory())

    /// CEDAR_DATA and CEDAR_ROOTS override the index location and the roots (used by tests).
    public static var data: URL = {
        if let custom = ProcessInfo.processInfo.environment["CEDAR_DATA"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cedar")
    }()
    public static var namesDB: String { data.appendingPathComponent("names.db").path }
    public static var contentDB: String { data.appendingPathComponent("content.db").path }
    public static var socket: String { data.appendingPathComponent("engine.sock").path }
    public static var log: String { data.appendingPathComponent("engine.log").path }

    public static let modelRepo = "Qwen/Qwen3-Embedding-0.6B-GGUF"
    public static let modelFile = "Qwen3-Embedding-0.6B-Q8_0.gguf"
    public static var modelPath: String { data.appendingPathComponent(modelFile).path }
    /// Identifies the embedding setup that produced the stored vectors. If it changes, everything is re-embedded,
    /// unless the old value is in `compatible`.
    public static let vectors = "Qwen3-Embedding-0.6B | 512 tokens | v1"
    public static let compatible: Set<String> = ["Qwen/Qwen3-Embedding-0.6B | sentence-transformers fp16 | v1"]

    public static let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path

    /// Home folder, /Applications, iCloud Drive and mounted volumes.
    public static func roots() -> [String] {
        if let custom = ProcessInfo.processInfo.environment["CEDAR_ROOTS"] { return custom.split(separator: ":").map(String.init) }
        var out = [home.path, "/Applications"]
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: iCloud, isDirectory: &isDir), isDir.boolValue { out.append(iCloud) }
        for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let path = "/Volumes/" + volume
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey, .isVolumeKey])
            if values?.isSymbolicLink == false, values?.isVolume == true { out.append(path) }   // the startup disk appears here as a symlink
        }
        return out
    }

    /// Never descended into.
    public static let skipPaths: Set<String> = [home.path + "/Library", home.path + "/.Trash"]
    public static let skipNames: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", ".venv", "venv", "env", "__pycache__", "site-packages", ".tox",
        ".mypy_cache", ".pytest_cache", ".ruff_cache", ".gradle", ".idea", "DerivedData", ".build", "build.noindex",
        "Pods", "target", ".next", ".nuxt", "dist-packages", ".ipynb_checkpoints", "System Volume Information",
        "$RECYCLE.BIN", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
    ]
    /// Package extensions: listed as a single item.
    public static let packages: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "pkg", "mpkg", "xcodeproj",
        "xcworkspace", "playground", "kext", "plugin", "appex", "imovielibrary", "pages", "numbers", "key", "rtfd",
        "fcpbundle", "logicx", "band", "sparsebundle",
    ]
    /// Folders with more direct entries than this are treated as datasets.
    public static let crowded = 500

    /// File types whose contents are indexed.
    public static let docExtensions: Set<String> = [
        "pdf", "md", "markdown", "txt", "tex", "html", "htm", "docx", "pptx", "xlsx", "rtf", "doc", "odt", "rst", "org",
    ]
    public static let maxTextBytes = 30_000_000
    public static let maxPDFBytes = 400_000_000
    public static let firstPassPages = 3
    public static let firstPassChunks = 10

    public static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

    public static func skipDir(path: String, name: String) -> Bool {
        name.hasPrefix(".") || name.hasSuffix(".noindex") || skipNames.contains(name) || skipPaths.contains(path)
            || packages.contains(ext(name))
            || Settings.current.excluded.contains(path)
    }

    /// True for an iCloud file that isn't downloaded. Reading it would trigger a download, so only its name
    /// is indexed.
    public static func isDataless(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_flags & UInt32(SF_DATALESS) != 0
    }

    private static var power: (checked: Date, battery: Bool) = (.distantPast, false)
    private static let powerLock = NSLock()

    /// Cached for a minute.
    public static var ignoreBattery = false

    public static func onBattery() -> Bool {
        if ignoreBattery { return false }
        powerLock.lock(); defer { powerLock.unlock() }
        if Date().timeIntervalSince(power.checked) > 60 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["-g", "batt"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var battery = false
            if (try? p.run()) != nil {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                battery = out.contains("Battery Power")
            }
            power = (Date(), battery)
        }
        return power.battery
    }
}

/// Appends a line to the engine log.
public func logLine(_ text: String) {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let stamp = format.string(from: Date())
    let line = "\(stamp) \(ProcessInfo.processInfo.processIdentifier) \(text)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let handle = FileHandle(forWritingAtPath: Config.log) ?? {
        FileManager.default.createFile(atPath: Config.log, contents: nil); return FileHandle(forWritingAtPath: Config.log) }() {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}
