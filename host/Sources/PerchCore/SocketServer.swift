import Darwin
import Foundation

/// เซิร์ฟเวอร์ Unix socket ที่รับบรรทัด JSON จาก hook
///
/// ใช้ POSIX ตรงๆ เพราะ AF_UNIX คือสิ่งที่ต้องการเป๊ะๆ และ hook ต้องจบเร็วที่สุด
/// โปรโตคอล: หนึ่งเหตุการณ์ = หนึ่งบรรทัด JSON แล้วปิดสายได้เลย
public final class SocketServer {
    private let path: String
    private let queue = DispatchQueue(label: "perch.socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let onLine: (Data) -> Void

    public init(path: URL, onLine: @escaping (Data) -> Void) {
        self.path = path.path
        self.onLine = onLine
    }

    public enum StartError: Error, CustomStringConvertible {
        case pathTooLong
        case alreadyRunning
        case syscall(String, Int32)

        public var description: String {
            switch self {
            case .pathTooLong: return "socket path too long for sun_path"
            case .alreadyRunning: return "another daemon already owns the socket"
            case .syscall(let name, let err):
                return "\(name) failed: \(String(cString: strerror(err)))"
            }
        }
    }

    public func start() throws {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw StartError.pathTooLong
        }

        // ถ้ามีไฟล์ socket ค้างอยู่ ให้ลองต่อดูก่อน — ต่อติด = มี daemon ตัวอื่นทำงานจริง
        if FileManager.default.fileExists(atPath: path) {
            if probeAlive() { throw StartError.alreadyRunning }
            try? FileManager.default.removeItem(atPath: path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.syscall("socket", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw StartError.syscall("bind", errno)
        }
        // เฉพาะเจ้าของเครื่องเท่านั้นที่สั่ง daemon ได้
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw StartError.syscall("listen", errno)
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        try? FileManager.default.removeItem(atPath: path)
    }

    private func probeAlive() -> Bool {
        let client = SocketClient(path: URL(fileURLWithPath: path))
        return client.canConnect()
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        queue.async { [weak self] in
            defer { close(fd) }
            guard let self else { return }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 1 << 20 { break }  // hook ไม่มีเหตุให้ส่งใหญ่กว่านี้
                while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<idx]
                    buffer = buffer[buffer.index(after: idx)...]
                    if !line.isEmpty { self.onLine(Data(line)) }
                }
            }
            if !buffer.isEmpty { self.onLine(Data(buffer)) }  // ไม่มี \n ปิดท้ายก็รับ
        }
    }
}

/// ฝั่ง hook — เปิด เขียน ปิด แล้วจบ ต้องไม่ค้างจนทำให้ Claude Code ช้า
public final class SocketClient {
    private let path: String

    public init(path: URL) {
        self.path = path.path
    }

    /// คืน false เมื่อ daemon ไม่ทำงาน — hook ต้องเงียบและ exit 0 ไม่ใช่พังทั้ง session
    @discardableResult
    public func send(_ payload: Data, timeout: TimeInterval = 1.0) -> Bool {
        guard let fd = connect(timeout: timeout) else { return false }
        defer { close(fd) }
        var data = payload
        if data.last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
        return data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    public func canConnect() -> Bool {
        guard let fd = connect(timeout: 0.2) else { return false }
        close(fd)
        return true
    }

    private func connect(timeout: TimeInterval) -> Int32? {
        let bytes = Array(path.utf8)
        var addr = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if ok != 0 {
            close(fd)
            return nil
        }
        return fd
    }
}
