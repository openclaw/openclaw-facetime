import Foundation
import Darwin

@MainActor
final class Control {
    private var timer: DispatchSourceTimer?
    private var signals = [DispatchSourceSignal]()
    private var frames = LineFrames()
    private var output = Data()
    private var inputFlags: Int32 = 0
    private var outputFlags: Int32 = 0
    private var closing: Int32?
    private var closingAt: TimeInterval = 0
    private let handle: (Command) throws -> [String: Any]
    private let shutdown: () -> Bool

    init(handle: @escaping (Command) throws -> [String: Any], shutdown: @escaping () -> Bool) {
        self.handle = handle
        self.shutdown = shutdown
    }

    func start(initial: [String: Any]) throws {
        inputFlags = fcntl(STDIN_FILENO, F_GETFL)
        outputFlags = fcntl(STDOUT_FILENO, F_GETFL)
        guard inputFlags >= 0, outputFlags >= 0,
              fcntl(STDIN_FILENO, F_SETFL, inputFlags | O_NONBLOCK) == 0,
              fcntl(STDOUT_FILENO, F_SETFL, outputFlags | O_NONBLOCK) == 0 else {
            throw ProbeError("stdio must be readable/writable; launch the bundle executable explicitly")
        }
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.finish(0) } }
            source.resume()
            signals.append(source)
        }
        emit(initial)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(20))
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        source.resume()
        timer = source
    }

    func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= 16_384, output.count + data.count + 1 <= 32_768 else {
            finish(1)
            return
        }
        output.append(data)
        output.append(10)
    }

    func finish(_ code: Int32) {
        guard closing == nil else { return }
        closing = code
        closingAt = ProcessInfo.processInfo.systemUptime
        if !shutdown() { closing = 1 }
    }

    private func tick() {
        if closing == nil {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            if count > 0 {
                do {
                    for frame in try frames.append(Data(chunk.prefix(count))) {
                        guard closing == nil else { break }
                        do {
                            let command = try Command.parse(frame)
                            if command.command == "quit" { finish(0) }
                            else { emit(try handle(command)) }
                        } catch { emit(["error": String(describing: error)]) }
                    }
                } catch {
                    emit(["error": String(describing: error)])
                    finish(1)
                }
            } else if count == 0 {
                if frames.hasPartialFrame { emit(["error": "truncated JSONL frame at EOF"]) }
                finish(frames.hasPartialFrame ? 1 : 0)
            } else if errno != EAGAIN && errno != EINTR { finish(1) }
        }
        if !output.isEmpty {
            let count = output.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, min($0.count, 4096)) }
            if count > 0 { output.removeFirst(count) }
            else if count < 0 && errno != EAGAIN && errno != EINTR { finish(1); closing = 1; output.removeAll() }
        }
        if let code = closing, output.isEmpty || ProcessInfo.processInfo.systemUptime - closingAt > 1 {
            _ = fcntl(STDIN_FILENO, F_SETFL, inputFlags)
            _ = fcntl(STDOUT_FILENO, F_SETFL, outputFlags)
            exit(output.isEmpty ? code : 1)
        }
    }
}

// Acquire only after launch consent and a mutating command. Never unlink a lock inode.
final class InstanceLock {
    private var descriptor: Int32 = -1
    func acquire(directory: String, name: String) throws {
        if descriptor >= 0 { return }
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else { throw ProbeError("cannot create private lock directory") }
        let dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw ProbeError("unsafe lock directory") }
        defer { close(dir) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw ProbeError("lock directory must be owned by this user, mode 0700")
        }
        let fd = openat(dir, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeError("cannot open lock without following symlinks") }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ProbeError("probe already owns lock or lock is unsafe; do not delete it")
        }
        descriptor = fd
    }
    func release() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}
