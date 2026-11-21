import Foundation

/// Talks to the Python engine over its private socket, and starts it when it isn't running.
final class EngineClient {
    struct Doc: Decodable {
        let path: String
        let title: String?
        let pages: Int?
        let page: Int?
        let snippet: String?
        let score: Double
        let z: Double?
        let words: Double
    }
    struct File: Decodable { let path: String; let name: String; let dir: Bool; let score: Double }
    struct Answer: Decodable { let docs: [Doc]; let files: [File]; let ms: Double }
    struct Status: Decodable {
        let state: String
        let names: Int
        let model: Bool
        let documents: Int
        let vectors: Int
        let to_embed: Int
        let first_pass_left: Int
    }

    let socketPath: String
    let engineDir: String
    private var process: Process?
    private var restarts = 0
    private let queue = DispatchQueue(label: "sift.engine", qos: .userInteractive, attributes: .concurrent)

    init(dataDir: URL, engineDir: String) {
        socketPath = dataDir.appendingPathComponent("engine.sock").path
        self.engineDir = engineDir
    }

    // MARK: running the engine

    func startIfNeeded() {
        queue.async {
            if (try? self.request(["op": "status"], timeout: 1)) != nil { return }   // already running
            DispatchQueue.main.async { self.launch() }
        }
    }

    private func launch() {
        let python = engineDir + "/.venv/bin/python"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            NSLog("Sift: no engine at \(python)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "sift_engine"]
        p.currentDirectoryURL = URL(fileURLWithPath: engineDir)
        // Searches wait on this process: keep it out of App Nap and off the efficiency cores (as DigUp does).
        p.qualityOfService = .userInitiated
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["SIFT_APP"] = Bundle.main.executablePath ?? ""     // the engine calls back for `--ocr`
        env["TOKENIZERS_PARALLELISM"] = "false"
        p.environment = env
        p.terminationHandler = { [weak self] proc in
            guard let self, proc.terminationReason != .uncaughtSignal || proc.terminationStatus != SIGTERM else { return }
            // Came down on its own: start it again, but don't loop on a broken install.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard self.process === proc, self.restarts < 5 else { return }
                self.restarts += 1
                self.launch()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("Sift: can't start engine: \(error)")
        }
    }

    func stop() {
        let p = process
        process = nil
        p?.terminate()
    }

    // MARK: requests

    func search(_ q: String, deep: Bool, done: @escaping (Answer?) -> Void) {
        queue.async {
            let data = try? self.request(["op": "search", "q": q, "deep": deep], timeout: 3)
            let answer = data.flatMap { try? JSONDecoder().decode(Answer.self, from: $0) }
            DispatchQueue.main.async { done(answer) }
        }
    }

    func status(done: @escaping (Status?) -> Void) {
        queue.async {
            let data = try? self.request(["op": "status"], timeout: 2)
            let status = data.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
            DispatchQueue.main.async { done(status) }
        }
    }

    enum Failure: Error { case connect, send, receive }

    /// One request per connection: connecting to a local socket costs microseconds.
    private func request(_ body: [String: Any], timeout: Double) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connect }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.connect }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { throw Failure.connect }

        var line = try JSONSerialization.data(withJSONObject: body)
        line.append(0x0A)
        let sent = line.withUnsafeBytes { send(fd, $0.baseAddress, line.count, 0) }
        guard sent == line.count else { throw Failure.send }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while reply.last != 0x0A {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { throw Failure.receive }
            reply.append(buffer, count: n)
        }
        return reply
    }
}
