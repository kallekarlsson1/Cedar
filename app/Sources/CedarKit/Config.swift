import Foundation

/// Where Cedar looks, what it skips, and where it keeps its index.
public enum Config {
    public static let home = URL(fileURLWithPath: NSHomeDirectory())

    /// CEDAR_DATA and CEDAR_ROOTS point a test run at its own index and folders.
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
    /// Names the vectors in the index; when it changes, every passage is embedded again. `compatible` lists earlier
    /// names whose vectors are the same within rounding, so those indexes are kept.
    public static let vectors = "Qwen3-Embedding-0.6B | 512 tokens | v1"
    public static let compatible: Set<String> = ["Qwen/Qwen3-Embedding-0.6B | sentence-transformers fp16 | v1"]

    public static let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path

    /// Everything a person would look for: the home folder, apps, iCloud Drive and plugged-in drives.
    public static func roots() -> [String] {
        if let custom = ProcessInfo.processInfo.environment["CEDAR_ROOTS"] { return custom.split(separator: ":").map(String.init) }
        var out = [home.path, "/Applications"]
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: iCloud, isDirectory: &isDir), isDir.boolValue { out.append(iCloud) }
        for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let path = "/Volumes/" + volume
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey, .isVolumeKey])
            if values?.isSymbolicLink == false, values?.isVolume == true { out.append(path) }   // the startup disk is a link
        }
        return out
    }

    /// Folders whose contents are never listed: app internals, caches, version control, package managers.
    public static let skipPaths: Set<String> = [home.path + "/Library", home.path + "/.Trash"]
    public static let skipNames: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", ".venv", "venv", "env", "__pycache__", "site-packages", ".tox",
        ".mypy_cache", ".pytest_cache", ".ruff_cache", ".gradle", ".idea", "DerivedData", ".build", "build.noindex",
        "Pods", "target", ".next", ".nuxt", "dist-packages", ".ipynb_checkpoints", "System Volume Information",
        "$RECYCLE.BIN", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
    ]
    /// Bundles that macOS shows as one file: listed by name, never opened up.
    public static let packages: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary", "pkg", "mpkg", "xcodeproj",
        "xcworkspace", "playground", "kext", "plugin", "appex", "imovielibrary", "pages", "numbers", "key", "rtfd",
        "fcpbundle", "logicx", "band", "sparsebundle",
    ]
    /// A folder holding more entries than this directly is treated as a dataset.
    public static let crowded = 500

    /// Documents whose text is read.
    public static let docExtensions: Set<String> = [
        "pdf", "md", "markdown", "txt", "tex", "html", "htm", "docx", "pptx", "xlsx", "rtf", "doc", "odt", "rst", "org",
    ]
    public static let maxTextBytes = 30_000_000
    public static let maxPDFBytes = 400_000_000
    public static let firstPassPages = 3
    public static let firstPassChunks = 10

    public static func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

    public static func skipDir(path: String, name: String) -> Bool {
        name.hasPrefix(".") || skipNames.contains(name) || skipPaths.contains(path) || packages.contains(ext(name))
    }

    /// True for a file that's only in iCloud (not downloaded). Its name is searchable; its contents are never read,
    /// because reading would make macOS download it.
    public static func isDataless(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_flags & UInt32(SF_DATALESS) != 0
    }

    private static var power: (checked: Date, battery: Bool) = (.distantPast, false)
    private static let powerLock = NSLock()

    /// True when the Mac runs on battery (checked once a minute). Heavy work waits for the charger.
    public static func onBattery() -> Bool {
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

/// A line in the engine's log file.
public func logLine(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(ProcessInfo.processInfo.processIdentifier) \(text)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let handle = FileHandle(forWritingAtPath: Config.log) ?? {
        FileManager.default.createFile(atPath: Config.log, contents: nil); return FileHandle(forWritingAtPath: Config.log) }() {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}
