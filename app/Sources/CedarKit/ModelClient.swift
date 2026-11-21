import Foundation

/// The model lives in a helper process (this same binary, run with `--model`), so that stopping it gives its
/// memory (~450 MB) back to macOS. Searches and indexing take turns on it; a waiting search always goes next.
///
/// Pipe protocol: request = kind byte ('q' query, 'd' document) + length (UInt32) + UTF-8 text;
/// reply = count (UInt32: 1024, or 0 when it failed) + that many Float32. The helper writes "R" once it's ready.
public final class ModelClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let lock = NSLock()           // one request on the pipe at a time
    private let loadLock = NSLock()
    private var waiting = 0
    private let countLock = NSLock()
    private var recent: [String: [Float]] = [:]     // query vectors: retyping costs nothing
    private var recentOrder: [String] = []

    public init() {}

    public var loaded: Bool { process?.isRunning == true }
    public var searchWaiting: Bool { countLock.lock(); defer { countLock.unlock() }; return waiting > 0 }

    /// True when the model file is on this Mac already (no download needed).
    public static var modelIsHere: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: Config.modelPath) { return true }
        let cache = NSHomeDirectory() + "/.cache/huggingface/hub/models--Qwen--Qwen3-Embedding-0.6B-GGUF/snapshots"
        return ((try? fm.contentsOfDirectory(atPath: cache)) ?? []).contains { fm.fileExists(atPath: cache + "/" + $0 + "/" + Config.modelFile) }
    }

    /// Where the model file is: Cedar's own folder, a copy Hugging Face tools already downloaded, or a download now.
    public static func modelFile(log: (String) -> Void = { _ in }) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: Config.modelPath) { return Config.modelPath }
        let cache = NSHomeDirectory() + "/.cache/huggingface/hub/models--Qwen--Qwen3-Embedding-0.6B-GGUF/snapshots"
        for snapshot in (try? fm.contentsOfDirectory(atPath: cache)) ?? [] {
            let path = cache + "/" + snapshot + "/" + Config.modelFile
            if fm.fileExists(atPath: path) { return path }
        }
        log("downloading the model (once, 640 MB)")
        guard let url = URL(string: "https://huggingface.co/\(Config.modelRepo)/resolve/main/\(Config.modelFile)") else { return nil }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.downloadTask(with: url) { file, response, _ in
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? fm.removeItem(atPath: Config.modelPath)
                ok = (try? fm.moveItem(at: file, to: URL(fileURLWithPath: Config.modelPath))) != nil
            }
            done.signal()
        }.resume()
        done.wait()
        log(ok ? "model downloaded" : "model download failed")
        return ok ? Config.modelPath : nil
    }

    public func load(log: (String) -> Void = { _ in }) {
        loadLock.lock(); defer { loadLock.unlock() }
        guard !loaded, let file = Self.modelFile(log: log), let binary = Bundle.main.executablePath else { return }
        let started = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["--model", file]
        p.qualityOfService = .userInitiated       // a search waits on it; indexing goes one passage at a time
        let toChild = Pipe(), fromChild = Pipe()
        p.standardInput = toChild
        p.standardOutput = fromChild
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let ready = fromChild.fileHandleForReading.readData(ofLength: 1)
        guard ready == Data("R".utf8) else { p.terminate(); log("model failed to load"); return }
        lock.lock()
        process = p; input = toChild.fileHandleForWriting; output = fromChild.fileHandleForReading
        lock.unlock()
        log(String(format: "model loaded in %.1fs", Date().timeIntervalSince(started)))
    }

    /// Stops the helper; `load` starts it again in under a second.
    public func unload(log: (String) -> Void = { _ in }) {
        loadLock.lock(); lock.lock()
        defer { lock.unlock(); loadLock.unlock() }
        guard let p = process else { return }
        try? input?.close()                      // the helper exits when its input closes
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        process = nil; input = nil; output = nil
        log("model unloaded while idle")
    }

    private func ask(_ kind: Character, _ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard loaded, let input, let output else { return nil }
        var request = Data([kind.asciiValue!])
        let bytes = Data(text.utf8)
        var length = UInt32(bytes.count)
        request.append(Data(bytes: &length, count: 4))
        request.append(bytes)
        do { try input.write(contentsOf: request) } catch { return nil }
        let head = output.readData(ofLength: 4)
        guard head.count == 4 else { return nil }
        let count = Int(head.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard count > 0 else { return nil }
        var body = Data()
        while body.count < count * 4 {
            let part = output.readData(ofLength: count * 4 - body.count)
            if part.isEmpty { return nil }
            body.append(part)
        }
        return body.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    public func query(_ text: String) -> [Float]? {
        let key = text.trimmingCharacters(in: .whitespaces)
        countLock.lock()
        if let hit = recent[key] { countLock.unlock(); return hit }
        waiting += 1
        countLock.unlock()
        let vector = ask("q", text)
        countLock.lock()
        waiting -= 1
        if let vector {
            recent[key] = vector
            recentOrder.append(key)
            if recentOrder.count > 256 { recent[recentOrder.removeFirst()] = nil }
        }
        countLock.unlock()
        return vector
    }

    public func document(_ text: String) -> [Float]? { ask("d", text) }

    /// The helper process's side (`Cedar --model file`).
    public static func serve(modelPath: String) -> Never {
        let stdin = FileHandle.standardInput, stdout = FileHandle.standardOutput
        guard let model = try? EmbeddingModel(path: modelPath), model.embed("warm up") != nil else {
            stdout.write(Data("E".utf8)); _exit(1)
        }
        stdout.write(Data("R".utf8))
        while true {
            let head = stdin.readData(ofLength: 5)
            guard head.count == 5 else { _exit(0) }          // the engine is gone, or asked us to stop
            let length = Int(head.dropFirst().withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            var body = Data()
            while body.count < length {
                let part = stdin.readData(ofLength: length - body.count)
                if part.isEmpty { _exit(0) }
                body.append(part)
            }
            let text = String(decoding: body, as: UTF8.self)
            let vector = head[head.startIndex] == Character("q").asciiValue! ? model.embedQuery(text) : model.embed(text)
            var count = UInt32(vector?.count ?? 0)
            var reply = Data(bytes: &count, count: 4)
            if let vector { vector.withUnsafeBufferPointer { reply.append(Data(buffer: $0)) } }
            stdout.write(reply)
        }
    }
}
