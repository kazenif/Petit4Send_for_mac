import Foundation

/// Petit4Send.exe の MethodDef 41（`buttonDetectSyncKey_Click`）と同じ手順。
///
/// Arduino が検出用パターンを出し、Switch の画面に 0〜24 が表示される。
/// シリアルの ACK に検出値は含まれない。手順は次のとおり。
///
/// 1. `01` に続く 11 バイトの 0 を送り、ACK を待つ（中止できる）
/// 2. 4 秒待つ。この間に Switch が値を表示する
/// 3. 12 バイトすべて 0 の停止パケットを 2 回送る（中止フラグは見ない）
///
/// 開始失敗・中止・1 回目の停止失敗のあとでも停止は 2 回試みる。
/// 停止側で中止を無視するのは、検出パターンを動かしっぱなしにしないため。
/// 切断中は停止が届かないことがあり、そのときは USB を挿し直す。
enum SyncKeyDetection {
    /// `exchange` は 12 バイトを書き、ACK を 1 バイト読む。第 2 引数が false のときは中止を見ない。
    /// `pause` は検出表示のための待ちで、ここだけ中止を反映してよい。
    static func run(exchange: ([UInt8], Bool) throws -> Void, pause: (TimeInterval) throws -> Void) throws {
        var failure: Error?
        do {
            try exchange([1] + [UInt8](repeating: 0, count: 11), true)
            try pause(4)
        } catch { failure = error }
        // 開始・中止・1 回目の停止が失敗しても、停止は 2 回とも試みる。
        // ここで中止を無視し、検出を走らせたままにしない。
        for _ in 0..<2 {
            do { try exchange([UInt8](repeating: 0, count: 12), false) }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}
