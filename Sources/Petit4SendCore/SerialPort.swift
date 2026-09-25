import Foundation
import Darwin

/// バックグラウンドの送受信を UI から止めるフラグ。
///
/// `NSLock` で守った可変状態をスレッド間で共有するため `@unchecked Sendable` にしている。
/// 検出の停止パケットのように、中止後も送り切る処理は `check()` を呼ばない。
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    /// 中止されていれば送信ループを抜ける。Switch 側も B ボタンで受信を終える必要がある。
    func check() throws { if isCancelled { throw TransferError("送信を中止しました。Switch側もBボタンで受信を終了してください。") } }
}

/// Arduino との 9600bps・8N1 シリアル。
///
/// Windows 版の DetectSerialStart と同じく、DTR を上げたあとゼロバイトを繰り返して
/// 最初の 1 バイト応答を待つ。応答の中身は見ない。
/// 本送信では 12 バイトの HID レポートを最大 4 個まで先行させ、1 レポートにつき
/// Arduino から 1 バイトの ACK を受け取る。これは Arduino 経路の確認であり、
/// Switch 本体が受信を終えたことではない。
public enum SerialPort {
    /// 呼び出し側のシリアルポート。`/dev/cu.*` だけを返す。
    /// `tty.*` は待ち受けでオープンがブロックし得るため列挙しない。
    public static func available() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath:"/dev")) ?? []).filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/"+$0 }
    }
    /// 抜き差しのあと、どのポートを選ぶか。
    ///
    /// 未選択で増えたポートが 1 つならそれを選ぶ。選択中のポートが残っていれば維持する。
    /// 選択中のポートが消えていたら未選択に戻し、残った別のポートには切り替えない。
    /// 未選択のまま複数同時に増えたときは、どれかを決めない。
    public static func choose(previous: [String], current: [String], selected: String) -> String {
        if !selected.isEmpty { return current.contains(selected) ? selected : "" }
        let added = current.filter { !previous.contains($0) }
        return added.count == 1 ? added[0] : ""
    }
    /// 前回選んだポートが今の一覧にあればそれを返す。無い、または空なら未選択。
    public static func restored(saved: String, available: [String]) -> String {
        !saved.isEmpty && available.contains(saved) ? saved : ""
    }
    /// `/dev` の変化で `onChange` を呼ぶ。`cu.*` の出現と消滅はここから一覧を読み直して知る。
    public final class Watcher: @unchecked Sendable {
        private var source: DispatchSourceFileSystemObject?
        public init?(onChange: @escaping @Sendable () -> Void) {
            let fd = open("/dev", O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler(handler: onChange)
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        deinit { source?.cancel() }
    }
    /// `reports` を送り切る。終了時（中止や失敗を含む）にキー解放レポートを出す。
    public static func send(path: String, reports: HIDReports, cancellation: Cancellation, progress: @escaping (Double) -> Void) throws {
        try run(path: path, reports: reports, cancellation: cancellation, progress: progress)
    }
    /// Sync Key 検出だけを行う。検出値はシリアル応答には載らず、Switch の画面に出る。
    public static func detectSyncKey(path: String, cancellation: Cancellation, progress: @escaping (Double) -> Void) throws {
        try run(path: path, reports: nil, cancellation: cancellation, progress: progress)
    }
    /// ポートを 9600 8N1 で開き、接続確認のあと本送信または検出へ分岐する。
    private static func run(path: String, reports: HIDReports?, cancellation: Cancellation, progress: @escaping (Double) -> Void) throws {
        guard path.hasPrefix("/dev/cu.") else { throw TransferError("/dev/cu.* のシリアルポートを選択してください。") }
        let fd = Darwin.open(path,O_RDWR|O_NOCTTY|O_NONBLOCK)
        guard fd >= 0 else { throw TransferError("ポートを開けません: \(String(cString:strerror(errno)))") }
        defer { Darwin.close(fd) }
        var settings = termios()
        guard tcgetattr(fd,&settings) == 0 else { throw TransferError("シリアル設定を取得できません。") }
        let original = settings
        defer { var s = original; _ = tcsetattr(fd,TCSANOW,&s) }
        // 生モード。8 ビット、パリティなし、ストップビット 1、RTS/CTS なし。
        cfmakeraw(&settings)
        settings.c_cflag = (settings.c_cflag & ~tcflag_t(CSIZE|PARENB|CSTOPB|CRTSCTS)) | tcflag_t(CS8|CLOCAL|CREAD)
        cfsetispeed(&settings,speed_t(B9600)); cfsetospeed(&settings,speed_t(B9600))
        guard tcsetattr(fd,TCSANOW,&settings) == 0 else { throw TransferError("9600bps 8N1の設定に失敗しました。") }
        // DTR をアサートする。多くの Arduino はこれでリセットされ、起動時のゴミがポートに出る。
        var dtr = Int32(TIOCM_DTR)
        _ = ioctl(fd,TIOCMBIS,&dtr)
        /// `events` が立つまで 50ms 間隔で待つ。切断は即失敗、期限切れは応答なし。
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
        /// 3 秒以内に書き切る。`EAGAIN` と `EINTR` は繰り返す。
        func write(_ bytes: [UInt8], checkCancellation: Bool = true) throws {
            let deadline = Date().addingTimeInterval(3)
            var offset = 0
            while offset < bytes.count {
                try wait(Int16(POLLOUT),until:deadline,checkCancellation:checkCancellation)
                let n = bytes.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!.advanced(by:offset),bytes.count-offset) }
                if n > 0 { offset += n } else if n < 0 && errno != EAGAIN && errno != EINTR { throw TransferError("シリアル書き込みに失敗しました。") }
            }
        }
        /// ACK を 1 バイト読む。値は検査しない（Windows 版と同じ）。
        func ack(until deadline: Date, checkCancellation: Bool = true) throws {
            while true {
                try wait(Int16(POLLIN),until:deadline,checkCancellation:checkCancellation)
                var byte: UInt8 = 0
                if Darwin.read(fd,&byte,1) == 1 { return }
                if errno != EAGAIN && errno != EINTR { throw TransferError("シリアル応答を読み取れません。") }
            }
        }
        // リセット直後のゴミを時間を置いて捨て、DetectSerialStart と同じゼロバイト探査に入る。
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
        // レポートが無ければ本送信ではなく Sync Key 検出。進捗は 4 秒の待機に対する割合。
        guard let reports else {
            try SyncKeyDetection.run(exchange: { bytes, cancellable in
                try write(bytes, checkCancellation: cancellable)
                try ack(until: Date().addingTimeInterval(3), checkCancellation: cancellable)
            }, pause: { duration in
                // 壁時計ではなく起動後経過時間で測る。スリープや時刻変更で 4 秒が伸び縮みしない。
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
        // 正常終了・中止のどちらでもキーを離す。切断時は 0.25 秒で打ち切るベストエフォート。
        // キー無し・修飾バイト 10, 2, 8, 0 の順は Windows 版の解放レポートと同じ。
        defer {
            var release = [UInt8](repeating:0,count:12); release[0] = command
            for modifier: UInt8 in [10,2,8,0] {
                release[7] = modifier
                do {
                    try write(release,checkCancellation:false)
                    try ack(until:Date().addingTimeInterval(0.25),checkCancellation:false)
                } catch { /* 中止後や USB 切断後は、解放が届かなくても送信処理は終わらせる。 */ }
            }
        }
        // 未 ACK は 4 個まで。5 個目を書く前に 1 個分の ACK を消化する。
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
