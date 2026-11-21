import Foundation

/// What the person chose in Settings. Kept as a small JSON file next to the index, so the panel and the engine
/// (separate processes) both read it; the panel tells the engine to read it again after a change.
public struct Settings: Codable, Equatable {
    public var excluded: [String] = []        // folders Cedar doesn't list or read
    public var paused = false                 // no embedding or text recognition for now (searching still works)
    public var deepEverything = false         // embed older documents in full too, not only ones in use

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

    /// The one in force in this process.
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
