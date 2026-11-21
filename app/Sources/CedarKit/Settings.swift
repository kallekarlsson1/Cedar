import Foundation

/// User settings, stored as JSON next to the index so the app and the engine can both read them.
public struct Settings: Codable, Equatable {
    public var excluded: [String] = []   // folders to skip
    public var paused = false   // no embedding or OCR
    public var deepEverything = false   // embed old documents in full too

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excluded = (try? c.decode([String].self, forKey: .excluded)) ?? []
        paused = (try? c.decode(Bool.self, forKey: .paused)) ?? false
        deepEverything = (try? c.decode(Bool.self, forKey: .deepEverything)) ?? false
    }

    static var url: URL { Config.data.appendingPathComponent("settings.json") }

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save() {
        try? FileManager.default.createDirectory(at: Config.data, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    /// Settings in effect in this process.
    private static var live = Settings.load()
    private static let lock = NSLock()
    public static var current: Settings {
        get { lock.lock(); defer { lock.unlock() }; return live }
        set { lock.lock(); live = newValue; lock.unlock() }
    }

    public func excludes(_ path: String) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
