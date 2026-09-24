import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Petit4SendCore

@main
struct Petit4SendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("Petit4Send for Mac") { ContentView().frame(minWidth:720,minHeight:540) }
            .windowStyle(.titleBar)
            .commands {
                // ヘルプブックが無いので、既定の項目は空のヘルプビューアを開くだけになる。
                // 代わりに同梱の HELP.md を別ウィンドウで出す。
                CommandGroup(replacing: .help) {
                    Button("Petit4Send ヘルプ") { openWindow(id: Petit4SendApp.helpWindowID) }
                        .keyboardShortcut("?", modifiers: .command)
                }
            }
        Window("Petit4Send ヘルプ", id: Petit4SendApp.helpWindowID) {
            HelpView().frame(minWidth: 520, minHeight: 400)
        }
        .defaultSize(width: 760, height: 620)
    }

    static let helpWindowID = "help"
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        // Xcode はこのパッケージを Info.plist の無い単体実行ファイルとしてビルドする。
        // CFBundleIconFile が効かず Dock が空白になるので、同梱 icns を自分で設定する。
        // dist/Petit4Send.app ではバンドルが既に同じアイコンを宣言しており、ここはそれを重ねるだけ。
        if let url = Bundle.module.url(forResource: "Petit4SendMac", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            // applicationIconImage が覆うのは Dock タイルだけ。情報パネルと警告は名前でアイコンを引く。
            // バンドルが無いとその名前は、親フォルダのアイコンとして既にキャッシュされている。
            // 名前が使用中だと setName は無視されるので、先に古い画像から外す。
            NSImage(named: NSImage.applicationIconName)?.setName(nil)
            icon.setName(NSImage.applicationIconName)
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
/// 送信タブと画像復元タブの状態。画面の更新はメインアクターに限定する。
@MainActor final class Model: ObservableObject {
    @Published var file: URL?
    @Published var filename = ""
    @Published var kind: FileKind = .text
    @Published var compression: Compression = .auto
    @Published var ports = SerialPort.available()
    @Published var port = ""
    @Published var syncKey = -1
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "ファイルとシリアルポートを選択してください。"
    @Published var pages: [ScreenshotPage] = []
    @Published var imageStatus = "SwitchのSCREENSHOT SENDで保存した画像を追加してください。"
    @Published var imageBusy = false
    private var cancellation: Cancellation?
    /// ポート一覧を読み直す。今の選択が消えていれば先頭を選ぶ。
    func refresh() { ports = SerialPort.available(); if !ports.contains(port) { port = ports.first ?? "" } }
    /// 送信ファイルを選ぶ。Switch 側の名前の初期値は、拡張子込みで大文字化した 32 文字。
    func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { file = url; filename = String(url.lastPathComponent.uppercased().prefix(32)) }
    }
    /// 進行中の送受信へ中止を知らせる。実際に止まるのはシリアル側の次の区切り。
    func stop() { cancellation?.cancel(); status = "中止処理中…" }
    /// DETECT SYNC KEY 画面向けに、約 4 秒の検出信号を送る。値そのものは Switch が表示する。
    func detectSyncKey() {
        guard !busy, !port.isEmpty else { return }
        let path = port, token = Cancellation()
        cancellation = token; busy = true; progress = 0
        status = "Sync Key検出中… SwitchのDETECT SYNC KEY画面を確認してください。"
        Task {
            do {
                try await Task.detached {
                    try SerialPort.detectSyncKey(path: path, cancellation: token) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }.value
                status = "検出信号の送信終了。Switchに表示された0〜24の値をSync Keyに設定し、Bボタンで戻ってUSB RECEIVEを選んでください。"
            } catch {
                status = token.isCancelled
                    ? "検出を中止しました。Switch側はBボタンで戻れます。停止信号が届かず検出が続く場合はUSBを接続し直してください。"
                    : error.localizedDescription
            }
            busy = false; cancellation = nil
        }
    }
    /// ファイルを種別に合わせてバイト列にし、HID レポートとして送る。
    /// TXT は UTF-8 または BOM 付き UTF-16 を、BOM なし UTF-16LE にする。
    /// DAT はそのまま、GRP は乗算前アルファを保った行優先 BGRA で、幅と高さはヘッダーへ出す。
    func send() {
        guard let file else { return }
        let kind = kind, mode = compression, name = filename, path = port, sync = syncKey
        let token = Cancellation(); cancellation = token; busy = true; progress = 0; status = "送信データを準備しています…"
        Task {
            do {
                try await Task.detached {
                    let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
                    guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Codec.maximumSize else { throw TransferError("入力ファイルが64 MiBを超えています。") }
                    var bytes: [UInt8], width = 0, height = 0
                    switch kind {
                    case .text:
                        let raw = try Data(contentsOf:file)
                        let encoding: String.Encoding = raw.starts(with:[0xff,0xfe]) || raw.starts(with:[0xfe,0xff]) ? .utf16 : .utf8
                        guard var text = String(data:raw,encoding:encoding) else { throw TransferError("TXTはUTF-8またはBOM付きUTF-16で保存してください。") }
                        if text.first == "\u{feff}" { text.removeFirst() }
                        bytes = Array(text.data(using:.utf16LittleEndian)!)
                    case .data: bytes = Array(try Data(contentsOf:file))
                    case .graphics:
                        let image = try Raster.load(file); bytes = image.bgra; width = image.width; height = image.height
                        guard width <= 65535, height <= 65535 else { throw TransferError("画像サイズが大きすぎます。") }
                    }
                    try token.checkForUI()
                    guard !bytes.isEmpty else { throw TransferError("空ファイルはSwitch側の受信処理に対応していません。") }
                    let stream = try USBProtocol.stream(bytes:bytes,name:name,kind:kind,compression:mode,width:width,height:height)
                    let reports = try HIDReports(stream,syncKey:sync)
                    let originalCount = bytes.count
                    // Switch が表示するのはストリーム全長ではなく、オフセット 112 のペイロード長。
                    // 秒数は実効 296 バイト/秒とした概算で、ヘッダー込みの長さから出している。
                    let payloadCount = Codec.integer(stream, 112, 4)
                    await MainActor.run { self.status = "送信中: \(originalCount) バイト → 本体 \(payloadCount) バイト（ヘッダー込み \(stream.count) バイト、約\(Int(Double(stream.count)/296))秒）" }
                    try SerialPort.send(path:path,reports:reports,cancellation:token) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }.value
                status = "送信終了。Switch側でCRC結果を確認し、Aボタンで保存してください。"
            } catch { status = error.localizedDescription }
            busy = false; cancellation = nil
        }
    }
    /// スクリーンショットを順不同で追加する。ページ番号は画像内のヘッダーから取る。
    func addImages() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.png,.jpeg,.bmp,.tiff]
        if panel.runModal() != .OK { return }
        let urls = panel.urls; imageBusy = true
        Task {
            let results = await Task.detached { urls.map { url -> (ScreenshotPage?,String?) in
                do { return (try ScreenshotPage.load(url),nil) }
                catch { return (nil,"\(url.lastPathComponent): \(error.localizedDescription)") }
            }}.value
            var errors: [String] = []
            for (page,error) in results {
                if let page { pages.append(page) }
                if let error { errors.append(error) }
            }
            imageStatus = errors.isEmpty ? "\(pages.count) 枚を読み込みました。全ページが揃ったファイルを保存できます。" : errors.joined(separator:"\n")
            imageBusy = false
        }
    }
    /// 同一ファイルのページを名前順にまとめる。枚数が足りない組も一覧には残す。
    var groups: [[ScreenshotPage]] {
        Dictionary(grouping:pages,by: { $0.groupKey }).values.sorted { $0[0].name < $1[0].name }
    }
    /// 揃った組だけ保存する。不足や CRC 不一致は、その組のエラー文として状態欄に出す。
    func saveImages() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "保存先を選択"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let groups = groups; imageBusy = true
        Task {
            let messages = await Task.detached { groups.map { group -> String in
                do { let url = try ScreenshotPage.export(group,directory:directory); return "保存: \(url.lastPathComponent)" }
                catch { return "\(group[0].name): \(error.localizedDescription)" }
            }}.value
            imageStatus = messages.joined(separator:"\n"); imageBusy = false
        }
    }
}
extension Cancellation {
    /// シリアルを開く前の準備中に使う中止。まだ Switch へは何も送っていない。
    func checkForUI() throws { if isCancelled { throw TransferError("中止しました。") } }
}
struct ContentView: View {
    @StateObject private var model = Model()
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Image(systemName:"arrow.left.arrow.right.square").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment:.leading) {
                    Text("Petit4Send").font(.title.bold())
                    Text("Mac ↔ プチコン4 • P4SEND 1.2.2互換").foregroundStyle(.secondary)
                }
                Spacer()
            }
            TabView {
                VStack(alignment:.leading,spacing:16) {
                    Text("Switchで USB RECEIVE を開き、WAITING FILE… の状態にしてください。")
                    HStack { Button("ファイルを選択…",action:model.chooseFile); Text(model.file?.lastPathComponent ?? "未選択").lineLimit(1); Spacer() }
                    Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:12) {
                        GridRow { Text("種類"); Picker("種類",selection:$model.kind) { ForEach(FileKind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden() }
                        GridRow { Text("Switch側の名前"); TextField("半角ASCII・32文字以内",text:$model.filename) }
                        GridRow { Text("圧縮"); Picker("圧縮",selection:$model.compression) { ForEach(Compression.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden() }
                        GridRow { Text("ポート"); HStack { Picker("ポート",selection:$model.port) { Text("選択してください").tag(""); ForEach(model.ports,id:\.self) { Text($0).tag($0) } }.labelsHidden(); Button("更新",action:model.refresh) } }
                        GridRow { Text("Sync Key"); HStack { Stepper(value:$model.syncKey,in:-1...24) { Text(model.syncKey == -1 ? "自動 (-1)" : "\(model.syncKey)") }; Button("Detect Sync Key", action:model.detectSyncKey).disabled(model.port.isEmpty); Text("Switchの検出値を指定。").font(.caption).foregroundStyle(.secondary) } }
                    }.disabled(model.busy)
                    Text("検出時はSwitchで DETECT SYNC KEY を選んでから、Detect Sync Keyを押してください（約4秒）。").font(.caption).foregroundStyle(.secondary)
                    Text("TXT: UTF-8 / UTF-16 → UTF-16LE　 DAT: バイナリ　 GRP: 画像 → BGRA").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value:model.progress)
                    HStack { Button("Switchへ送信",action:model.send).buttonStyle(.borderedProminent).disabled(model.busy || model.file == nil || model.port.isEmpty); Button("中止",action:model.stop).disabled(!model.busy); Spacer(); Text("9600 bps · 8N1").foregroundStyle(.secondary) }
                    Text(model.status).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    Spacer(minLength:0)
                }.padding().tabItem { Label("USB送信",systemImage:"cable.connector") }
                VStack(alignment:.leading,spacing:12) {
                    Text("原寸のスクリーンショットを追加します。分割画像は順不同で選択できます。")
                    HStack { Button("画像を追加…",action:model.addImages); Button("一覧をクリア") { model.pages = []; model.imageStatus = "一覧をクリアしました。" }; Spacer(); Button("復元して保存…",action:model.saveImages).buttonStyle(.borderedProminent).disabled(model.pages.isEmpty) }.disabled(model.imageBusy)
                    List {
                        ForEach(model.groups,id:\.first!.groupKey) { pages in
                            let first = pages[0]
                            let count = Set(pages.map(\.index)).count
                            VStack(alignment:.leading,spacing:5) {
                                HStack { Text(first.name).font(.headline); Spacer(); Text("\(count) / \(first.total) 枚").foregroundStyle(count == first.total ? .green : .orange) }
                                Text("\(first.fileSize) bytes · \(first.compression == 1 ? "LZSS" : "無圧縮") · CRC \(String(format:"%04X",first.crc))").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical,4)
                        }
                    }
                    if model.imageBusy { ProgressView() }
                    ScrollView { Text(model.imageStatus).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }.frame(height:90)
                    Text("TXTはUTF-8、GRPはPNG、DATはバイナリで保存します。同名ファイルは連番で保存します。").font(.caption).foregroundStyle(.secondary)
                }.padding().tabItem { Label("画像から復元",systemImage:"photo.on.rectangle") }
            }
        }.padding(20).onAppear { model.refresh() }
    }
}
