import Foundation
import Darwin

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if isCancelled { throw TransferError("送信を中止しました。Switch側もBボタンで受信を終了してください。") } }
}
public enum SerialPort {
    public static func available() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath:"/dev")) ?? []).filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/"+$0 }
    }
    public static func send(path: String, reports: HIDReports, cancellation: Cancellation, progress: @escaping (Double) -> Void) throws {
        try run(path: path, reports: reports, cancellation: cancellation, progress: progress)
    }
    public static func detectSyncKey(path: String, cancellation: Cancellation, progress: @escaping (Double) -> Void) throws {
        try run(path: path, reports: nil, cancellation: cancellation, progress: progress)
    }
    private static func run(path: String, reports: HIDReports?, cancellation: Cancellation, progress: @escaping (Double) -> Void) throws {
        guard path.hasPrefix("/dev/cu.") else { throw TransferError("/dev/cu.* のシリアルポートを選択してください。") }
        let fd = Darwin.open(path,O_RDWR|O_NOCTTY|O_NONBLOCK)
        guard fd >= 0 else { throw TransferError("ポートを開けません: \(String(cString:strerror(errno)))") }
        defer { Darwin.close(fd) }
        var settings = termios()
        guard tcgetattr(fd,&settings) == 0 else { throw TransferError("シリアル設定を取得できません。") }
        let original = settings
        defer { var s = original; _ = tcsetattr(fd,TCSANOW,&s) }
        cfmakeraw(&settings)
        settings.c_cflag = (settings.c_cflag & ~tcflag_t(CSIZE|PARENB|CSTOPB|CRTSCTS)) | tcflag_t(CS8|CLOCAL|CREAD)
        cfsetispeed(&settings,speed_t(B9600)); cfsetospeed(&settings,speed_t(B9600))
        guard tcsetattr(fd,TCSANOW,&settings) == 0 else { throw TransferError("9600bps 8N1の設定に失敗しました。") }
        var dtr = Int32(TIOCM_DTR)
        _ = ioctl(fd,TIOCMBIS,&dtr)
        func wait(_ events: Int16, until deadline: Date, checkCancellation: Bool = true) throws {
            while Date() < deadline {
                if checkCancellation { try cancellation.check() }
                var p = pollfd(fd:fd,events:events,revents:0)
                let result = poll(&p,1,50)
                if result < 0 && errno != EINTR { throw TransferError("シリアル通信に失敗しました。") }
                if p.revents & Int16(POLLERR|POLLHUP|POLLNVAL) != 0 { throw TransferError("USB接続が切断されました。") }
                if p.revents & events != 0 { return }
            }
            throw TransferError("Arduinoから応答がありません。配線・ファームウェア・ポートを確認してください。")
        }
        func write(_ bytes: [UInt8], checkCancellation: Bool = true) throws {
            let deadline = Date().addingTimeInterval(3)
            var offset = 0
            while offset < bytes.count {
                try wait(Int16(POLLOUT),until:deadline,checkCancellation:checkCancellation)
                let n = bytes.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!.advanced(by:offset),bytes.count-offset) }
                if n > 0 { offset += n } else if n < 0 && errno != EAGAIN && errno != EINTR { throw TransferError("シリアル書き込みに失敗しました。") }
            }
        }
        func ack(until deadline: Date, checkCancellation: Bool = true) throws {
            while true {
                try wait(Int16(POLLIN),until:deadline,checkCancellation:checkCancellation)
                var byte: UInt8 = 0
                if Darwin.read(fd,&byte,1) == 1 { return }
                if errno != EAGAIN && errno != EINTR { throw TransferError("シリアル応答を読み取れません。") }
            }
        }
        // Drain reset chatter, then reproduce DetectSerialStart's zero-byte probing.
        let settle = Date().addingTimeInterval(0.3)
        while Date() < settle { try cancellation.check(); Thread.sleep(forTimeInterval:0.02) }
        tcflush(fd,TCIOFLUSH)
        let deadline = Date().addingTimeInterval(5)
        var connected = false
        while Date() < deadline {
            try cancellation.check(); try write([0])
            var p = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            if poll(&p,1,100) > 0 && p.revents & Int16(POLLIN) != 0 {
                try ack(until:deadline); connected = true; break
            }
        }
        guard connected else { throw TransferError("Arduinoの初期応答がありません。") }
        guard let reports else {
            try SyncKeyDetection.run(exchange: { bytes, cancellable in
                try write(bytes, checkCancellation: cancellable)
                try ack(until: Date().addingTimeInterval(3), checkCancellation: cancellable)
            }, pause: { duration in
                let start = ProcessInfo.processInfo.systemUptime
                while ProcessInfo.processInfo.systemUptime - start < duration {
                    try cancellation.check()
                    progress(min(1, (ProcessInfo.processInfo.systemUptime - start) / duration))
                    Thread.sleep(forTimeInterval: 0.02)
                }
                try cancellation.check()
            })
            progress(1)
            return
        }
        let command = reports.command
        // Always release keys on completion or cancellation; bounded best effort on disconnect.
        defer {
            var release = [UInt8](repeating:0,count:12); release[0] = command
            for modifier: UInt8 in [10,2,8,0] {
                release[7] = modifier
                do {
                    try write(release,checkCancellation:false)
                    try ack(until:Date().addingTimeInterval(0.25),checkCancellation:false)
                } catch { /* Best effort after cancellation or USB disconnect. */ }
            }
        }
        var pending = 0
        for (i, report) in reports.enumerated() {
            try cancellation.check()
            if pending >= 4 { try ack(until:Date().addingTimeInterval(3)); pending -= 1 }
            try write(report); pending += 1
            if i % 16 == 0 { progress(Double(i)/Double(max(1,reports.count))) }
        }
        while pending > 0 { try ack(until:Date().addingTimeInterval(3)); pending -= 1 }
        progress(1)
    }
}
