import Darwin
import Foundation

/// A running plugin program.
///
/// Started through the login shell (`zsh -lc 'exec "$@"'`, so `python3`, `node`, `uv` are found as in
/// Terminal) with `posix_spawn`, and two things `Process` can't do:
/// - **Its own permissions.** macOS attributes a child's privacy access to the app that started it,
///   so a plugin could otherwise record the microphone under tinyMuesli's permission. Spawned with
///   responsibility disclaimed, it's its own responsible process and macOS asks for itself.
/// - **No inherited files.** Only stdin, stdout and stderr; not the app's open audio files.
final class PluginProcess: @unchecked Sendable {
    let pid: pid_t
    /// Write end of the program's stdin.
    let input: Int32
    /// Read end of its stdout.
    let output: Int32
    private let lock = NSLock()
    private var inputClosed = false
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    /// Where this call's stderr starts in the plugin's log.
    var logOffset = 0
    /// Stopped for taking too long.
    var timedOut: Bool {
        get { flagLock.withLock { _timedOut } }
        set { flagLock.withLock { _timedOut = newValue } }
    }
    private var _timedOut = false
    /// For the exit status and flags; separate from `lock`, which a write to a full pipe holds.
    private let flagLock = NSLock()

    /// - Parameter log: stderr is appended here.
    init(command: [String], directory: URL, environment: [String: String], log: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let logFD = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        defer { if logFD >= 0 { close(logFD) } }

        var stdinPipe: [Int32] = [0, 0], stdoutPipe: [Int32] = [0, 0]
        guard pipe(&stdinPipe) == 0 else { throw PluginError.launch("pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&stdoutPipe) == 0 else {
            close(stdinPipe[0]); close(stdinPipe[1])
            throw PluginError.launch("pipe: \(String(cString: strerror(errno)))")
        }
        // Writing to a program that has exited fails with EPIPE instead of killing the app.
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        if logFD >= 0 { posix_spawn_file_actions_adddup2(&actions, logFD, 2) }
        else { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors above are inherited; its own process group, so stopping it stops
        // whatever it started too.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                                     | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Default handlers and nothing blocked: the spawning thread's signal mask would otherwise carry
        // over, and with SIGTERM blocked a plugin that timed out ran on until it finished.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        Self.disclaimResponsibility(&attributes)

        let arguments = ["/bin/zsh", "-lc", LoginShell.pathSetup + "exec \"$@\"", "tinymuesli-plugin"] + command
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = Self.withCStrings(arguments) { argv in
            Self.withCStrings(env) { envp in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
            }
        }
        close(stdinPipe[0])
        close(stdoutPipe[1])
        guard status == 0 else {
            close(stdinPipe[1]); close(stdoutPipe[0])
            throw PluginError.launch(String(cString: strerror(status)))
        }
        self.pid = pid
        self.input = stdinPipe[1]
        self.output = stdoutPipe[0]
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
            // Exit code, or 128 + signal like a shell.
            let code = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            let waiting = flagLock.withLock {
                exitStatus = code
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume(returning: code) }
        }
    }

    deinit {
        closeInput()
        close(output)
    }

    /// Writes everything, or returns false if the program stopped reading.
    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inputClosed else { return false }
        return data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(input, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// End of input: the program sees EOF on stdin.
    func closeInput() {
        lock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            close(input)
        }
    }

    /// Reads stdout to the end (blocking: call off the main thread).
    func readAll() -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(output, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Calls `onLine` for each line of stdout until it closes (blocking: call off the main thread).
    func readLines(_ onLine: (Data) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(output, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                onLine(pending[pending.startIndex..<newline])
                pending = Data(pending[(newline + 1)...])
            }
        }
        if !pending.isEmpty { onLine(pending) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done: Int32? = flagLock.withLock {
                if let exitStatus { return exitStatus }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    /// Stops the plugin and anything it started.
    func terminate() {
        kill(-pid, SIGTERM)
    }

    // MARK: - Helpers

    /// `responsibility_spawnattrs_setdisclaim` isn't in the SDK's headers, but it's what Chromium,
    /// LLDB and Claude's own helper use. Looked up at runtime; without it the plugin just shares
    /// tinyMuesli's permissions, as hooks do.
    private static func disclaimResponsibility(_ attributes: UnsafeMutablePointer<posix_spawnattr_t?>) {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return }
        _ = unsafeBitCast(symbol, to: Disclaim.self)(attributes, 1)
    }

    static var canDisclaimResponsibility: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") != nil
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

public enum PluginError: Error, LocalizedError, Equatable, CustomStringConvertible {
    case launch(String)
    case notFound(String)
    case failed(plugin: String, status: Int32, log: String)
    case badOutput(plugin: String, detail: String)
    case timedOut(plugin: String)

    public var errorDescription: String? {
        switch self {
        case .launch(let reason): "Couldn't start the plugin: \(reason)"
        case .notFound(let program): "The plugin needs \(program), which isn't installed (or isn't on your login shell's PATH)."
        case .failed(let plugin, let status, let log):
            "The \(plugin) plugin exited with status \(status)." + (log.isEmpty ? "" : " It said: \(log)")
        case .badOutput(let plugin, let detail): "The \(plugin) plugin answered with something tinyMuesli couldn't read: \(detail)"
        case .timedOut(let plugin): "The \(plugin) plugin took too long and was stopped."
        }
    }

    /// Messages read the same wherever the error is printed with `"\(error)"`.
    public var description: String { errorDescription ?? "Plugin error" }
}

/// Programs are found through `zsh -lc`, as in Terminal. But a login shell that isn't interactive
/// skips `~/.zshrc`, where installers like uv's and Claude Code's put `~/.local/bin` on the PATH; it
/// only worked when tinyMuesli had been started from Terminal and so had Terminal's PATH. This goes
/// before each such script and adds the usual places for tools after the login PATH.
public enum LoginShell {
    public static let pathSetup =
        #"PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$HOME/.bun/bin"; "#
}
