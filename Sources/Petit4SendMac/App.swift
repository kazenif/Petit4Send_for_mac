import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Petit4SendCore

@main
struct Petit4SendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("Petit4Send for Mac") { ContentView().frame(minWidth:800,minHeight:640) }
            .windowStyle(.titleBar)
            .commands {
                // 単体実行では Info.plist が無く、About の名前は Petit4SendMac だけになる。
                // その直下の行に、P4SEND との対応を出す。数字だけの版数だと「Version」が付くので、文言そのものを渡す。
                CommandGroup(replacing: .appInfo) {
                    Button("About \(ProcessInfo.processInfo.processName)") {
                        // version を空にすると、CFBundleVersion の (9) のようなビルド番号を出さない。
                        NSApp.orderFrontStandardAboutPanel(options: [
                            .applicationVersion: "1.2.2 互換",
                            .version: ""
                        ])
                    }
                }
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
/// 送信と検出のあいだ、終了をキー解放または停止パケットのあとまで遅らせる。
final class TransferGate: @unchecked Sendable {
    static let shared = TransferGate()
    private let lock = NSLock()
    private var token: Cancellation?
    private var quitAfterCleanup = false
    private var onQuit: (() -> Void)?
    func begin(_ token: Cancellation, onQuit: @escaping () -> Void) {
        lock.lock()
        self.token = token
        self.onQuit = onQuit
        quitAfterCleanup = false
        lock.unlock()
    }
    /// 作業中なら中止を依頼して true。止まっていれば false（すぐ終了してよい）。
    func requestStop() -> Bool {
        lock.lock()
        let current = token
        let notify = onQuit
        if current != nil { quitAfterCleanup = true }
        lock.unlock()
        current?.cancel()
        if current != nil { notify?() }
        return current != nil
    }
    func end() -> Bool {
        lock.lock()
        token = nil
        onQuit = nil
        let quit = quitAfterCleanup
        quitAfterCleanup = false
        lock.unlock()
        return quit
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TransferGate.shared.requestStop() ? .terminateCancel : .terminateNow
    }
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !TransferGate.shared.requestStop()
    }
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
    /// ファイル送信中だけ入る残り秒数。検出中や準備中は nil。
    @Published var remainingSeconds: Int?
    @Published var status = "ファイルとシリアルポートを選択してください"
    @Published var pages: [LoadedScreenshot] = []
    @Published var imageStatus = "SwitchのSCREENSHOT SENDで保存した画像を追加してください"
    @Published var imageBusy = false
    private var cancellation: Cancellation?
    private var portWatcher: SerialPort.Watcher?
    private var didRestorePort = false
    private static let rememberedPortKey = "rememberedSerialPort"
    /// 起動時だけ、記憶しているポートが一覧にあれば選ぶ。その後の抜き差しは `refresh` の規則に任せる。
    func restoreRememberedPort() {
        guard !didRestorePort else { return }
        didRestorePort = true
        port = SerialPort.restored(saved: UserDefaults.standard.string(forKey: Self.rememberedPortKey) ?? "", available: ports)
    }
    /// 利用者が選んだポートを記憶する。未選択にしたときは記憶を消す。抜き差しで消えた選択はここを通さない。
    func selectPort(_ path: String) {
        port = path
        if path.isEmpty { UserDefaults.standard.removeObject(forKey: Self.rememberedPortKey) }
        else { UserDefaults.standard.set(path, forKey: Self.rememberedPortKey) }
    }
    /// `/dev` の変化で一覧を読み直す。送信中でも選択規則だけは同じ。
    func watchPorts() {
        guard portWatcher == nil else { return }
        portWatcher = SerialPort.Watcher { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }
    /// ポート一覧を読み直す。未選択で増分が 1 つならそれを選び、消えた選択は未選択に戻す。
    func refresh() {
        let current = SerialPort.available()
        port = SerialPort.choose(previous: ports, current: current, selected: port)
        ports = current
        if !port.isEmpty { UserDefaults.standard.set(port, forKey: Self.rememberedPortKey) }
        updateSelectionStatus()
    }
    /// 送信や検出の結果表示中は触らない。選択の案内を出しているあいだだけ、いまの選択に合わせる。
    func updateSelectionStatus() {
        guard !busy else { return }
        let namePrompt = USBProtocol.switchNameError("") ?? ""
        let prompts = [
            "ファイルとシリアルポートを選択してください",
            "ファイルを選択してください",
            "シリアルポートを選択してください",
            "送信できます",
            namePrompt,
        ]
        guard prompts.contains(status) else { return }
        if file == nil, port.isEmpty { status = prompts[0] }
        else if file == nil { status = prompts[1] }
        else if port.isEmpty { status = prompts[2] }
        else if let message = USBProtocol.switchNameError(filename) { status = message }
        else { status = prompts[3] }
    }
    /// 送信ファイルを選ぶ。Switch 側の名前の初期値は、拡張子込みで大文字化した 32 文字。
    func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            file = url
            filename = String(USBProtocol.asciiUppercased(url.lastPathComponent).prefix(32))
            if let inferred = FileKind.inferred(pathExtension: url.pathExtension) { kind = inferred }
            updateSelectionStatus()
        }
    }
    /// フォーカスを外したときと送信直前で、Sync Key を -1...24 に収める。
    func clampSyncKey() { syncKey = min(24, max(-1, syncKey)) }
    /// 進行中の送受信へ中止を知らせる。実際に止まるのはシリアル側の次の区切り。
    func stop() { cancellation?.cancel(); status = "中止処理中…" }
    /// DETECT SYNC KEY 画面向けに、約 4 秒の検出信号を送る。値そのものは Switch が表示する。
    func detectSyncKey() {
        guard !busy, !port.isEmpty else { return }
        let path = port, token = Cancellation()
        cancellation = token
        TransferGate.shared.begin(token) { [weak self] in
            Task { @MainActor in self?.status = "終了処理中…"; self?.remainingSeconds = nil }
        }
        busy = true; progress = 0; remainingSeconds = nil
        status = "Sync Key検出中… SwitchのDETECT SYNC KEY画面を確認してください"
        Task {
            defer { self.finishTransfer() }
            do {
                try await Task.detached {
                    try SerialPort.detectSyncKey(path: path, cancellation: token) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }.value
                status = "検出信号の送信終了。Switchの表示値をSync Keyに設定後、Bボタンで戻りUSB RECEIVEを選択"
            } catch {
                status = token.isCancelled
                    ? "検出を中止しました。Switch側はBボタンで戻れます。停止信号が届かず検出が続く場合はUSBを接続し直してください。"
                    : error.localizedDescription
            }
        }
    }
    /// ファイルを種別に合わせてバイト列にし、HID レポートとして送る。
    /// TXT は UTF-8、BOM 付き UTF-16、シフトJISを、BOM なし UTF-16LE にする。
    /// DAT はそのまま、GRP は乗算前アルファを保った行優先 BGRA で、幅と高さはヘッダーへ出す。
    func send() {
        guard let file else { return }
        // 数値欄に焦点があるまま押しても、入力中の値を確定してから範囲へ収める。
        NSApp.keyWindow?.makeFirstResponder(nil)
        clampSyncKey()
        let kind = kind, mode = compression, name = filename, path = port, sync = syncKey
        let token = Cancellation(); cancellation = token
        TransferGate.shared.begin(token) { [weak self] in
            Task { @MainActor in self?.status = "終了処理中…"; self?.remainingSeconds = nil }
        }
        busy = true; progress = 0; remainingSeconds = nil; status = "送信データを準備しています…"
        Task {
            defer { self.finishTransfer() }
            do {
                try await Task.detached {
                    let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
                    guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Codec.maximumSize else { throw TransferError("入力ファイルが64 MiBを超えています。") }
                    var bytes: [UInt8], width = 0, height = 0
                    switch kind {
                    case .text: bytes = try SourceText.utf16LE(from: Data(contentsOf: file))
                    case .data: bytes = Array(try Data(contentsOf:file))
                    case .graphics:
                        let image = try Raster.load(file); bytes = image.bgra; width = image.width; height = image.height
                        guard width <= 65535, height <= 65535 else { throw TransferError("画像サイズが大きすぎます。") }
                    }
                    try token.checkForUI()
                    guard !bytes.isEmpty else { throw TransferError("空ファイルはSwitch側の受信処理に対応していません。") }
                    let stream = try USBProtocol.stream(bytes:bytes,name:name,kind:kind,compression:mode,width:width,height:height) { token.isCancelled }
                    let reports = try HIDReports(stream,syncKey:sync)
                    let originalCount = bytes.count
                    // Switch が表示するのはストリーム全長ではなく、オフセット 112 のペイロード長。
                    // 秒数は実効 296 バイト/秒とした概算で、ヘッダー込みの長さから出している。
                    let payloadCount = Codec.integer(stream, 112, 4)
                    let totalSeconds = Int(Double(stream.count)/296)
                    await MainActor.run {
                        self.status = "送信中: \(originalCount) バイト → 本体 \(payloadCount) バイト（ヘッダー込み \(stream.count) バイト、約\(totalSeconds)秒）"
                        self.remainingSeconds = totalSeconds
                    }
                    try SerialPort.send(path:path,reports:reports,cancellation:token) { value in
                        let left = Int(Double(totalSeconds) * (1 - value))
                        Task { @MainActor in
                            self.progress = value
                            self.remainingSeconds = max(0, left)
                        }
                    }
                }.value
                status = "送信終了。Switch側でCRC結果を確認し、Aボタンで保存してください"
            } catch { status = error.localizedDescription }
        }
    }
    /// 送信か検出が終わったあと、終了が予約されていればここでアプリを閉じる。
    private func finishTransfer() {
        busy = false
        remainingSeconds = nil
        cancellation = nil
        if TransferGate.shared.end() { NSApp.terminate(nil) }
    }
    /// スクリーンショットを順不同で追加する。ページ番号は画像内のヘッダーから取る。
    func addImages() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.png,.jpeg,.bmp,.tiff]
        if panel.runModal() != .OK { return }
        let urls = panel.urls; imageBusy = true
        Task {
            let results = await Task.detached { urls.map { url -> (ScreenshotPage?, String, String?) in
                do { return (try ScreenshotPage.load(url), url.lastPathComponent, nil) }
                catch { return (nil, url.lastPathComponent, "\(url.lastPathComponent): \(error.localizedDescription)") }
            }}.value
            var errors: [String] = []
            for (page, filename, error) in results {
                if let page { pages.append(LoadedScreenshot(filename: filename, page: page)) }
                if let error { errors.append(error) }
            }
            imageStatus = errors.isEmpty ? "\(pages.count) 枚を読み込みました。全ページが揃ったファイルを保存できます。" : errors.joined(separator:"\n")
            imageBusy = false
        }
    }
    /// 同一ファイルのページを名前順にまとめる。枚数が足りない組も一覧には残す。
    var groups: [[LoadedScreenshot]] {
        Dictionary(grouping: pages, by: { $0.page.groupKey }).values.sorted { $0[0].page.name < $1[0].page.name }
    }
    /// 追加した画像を 1 枚だけ外す。同じページの重複は、押した 1 枚だけ消える。
    func removeScreenshot(_ id: UUID) {
        pages.removeAll { $0.id == id }
        imageStatus = pages.isEmpty ? "一覧をクリアしました。" : "\(pages.count) 枚を読み込みました。全ページが揃ったファイルを保存できます。"
    }
    /// 揃った組だけ保存する。不足や CRC 不一致は、その組のエラー文として状態欄に出す。
    func saveImages() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "保存先を選択"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let groups = groups; imageBusy = true
        Task {
            let messages = await Task.detached { groups.map { group -> String in
                do { let url = try ScreenshotPage.export(group.map(\.page), directory: directory); return "保存: \(url.lastPathComponent)" }
                catch { return "\(group[0].page.name): \(error.localizedDescription)" }
            }}.value
            imageStatus = messages.joined(separator:"\n"); imageBusy = false
        }
    }
}
/// 復元一覧の 1 枚。同じ画像を二度足したときは、削除で 1 枚ずつ外せる。
struct LoadedScreenshot: Identifiable {
    let id = UUID()
    let filename: String
    let page: ScreenshotPage
}
extension Cancellation {
    /// シリアルを開く前の準備中に使う中止。まだ Switch へは何も送っていない。
    func checkForUI() throws { if isCancelled { throw TransferError("中止しました。") } }
}
struct ContentView: View {
    @StateObject private var model = Model()
    @FocusState private var syncKeyFocused: Bool
    @State private var fieldHeight: CGFloat = 0
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Image(systemName:"arrow.left.arrow.right.square").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment:.leading) {
                    Text("Petit4Send").font(.title.bold())
                    Text("Mac ↔ プチコン4 • P4SEND 1.2.2互換").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            TabView {
                VStack(alignment:.leading,spacing:16) {
                    Grid(alignment:.leading,horizontalSpacing:16,verticalSpacing:8) {
                        GridRow(alignment:.center) {
                            Text("ポート")
                            HStack { Picker("ポート",selection:Binding(get:{ model.port }, set:model.selectPort)) { Text("選択してください").tag(""); ForEach(model.ports,id:\.self) { Text($0).tag($0) } }.labelsHidden(); Button("更新",action:model.refresh) }
                                .disabled(model.busy)
                        }
                        GridRow {
                            Color.clear.frame(width:0,height:0)
                            Text("未選択のときにケーブルを接続すると、増えたポートを選びます。選択中に抜くと未選択に戻ります").font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        GridRow(alignment:.center) {
                            Text("Sync Key").padding(.top, 8)
                            HStack {
                                TextField("−1", value: $model.syncKey, format: .number.grouping(.never))
                                    .focused($syncKeyFocused)
                                    .frame(width: 44)
                                    .onChange(of: syncKeyFocused) { _, focused in
                                        if !focused { model.clampSyncKey() }
                                    }
                                Stepper("Sync Key", value: $model.syncKey, in: -1...24).labelsHidden()
                                Button("Detect Sync Key", action: model.detectSyncKey).disabled(model.port.isEmpty)
                                Text("−1〜24。−1 は自動").font(.system(size: 14)).foregroundStyle(.secondary)
                            }.disabled(model.busy).padding(.top, 8)
                        }
                        GridRow {
                            Color.clear.frame(width:0,height:0)
                            Text("検出時はSwitchで DETECT SYNC KEY を選んでから、Detect Sync Keyを押してください").font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("ファイル名").padding(.top, 8)
                            HStack {
                                SizedTextField(text: Binding(get: { model.file?.lastPathComponent ?? "未選択" }, set: { _ in }), placeholder: "未選択", height: fieldHeight, editable: false)
                                Button("ファイル選択", action: model.chooseFile)
                            }.padding(.top, 8)
                        }
                        GridRow { Text("種類"); Picker("種類",selection:$model.kind) { ForEach(FileKind.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().background { GeometryReader { proxy in Color.clear.preference(key: FieldHeightKey.self, value: proxy.size.height) } } }
                        GridRow { Text("Switch側の名前"); SizedTextField(text: $model.filename, placeholder: "半角ASCII・32文字以内", height: fieldHeight, editable: true) }
                        GridRow {
                            Color.clear.frame(width:0,height:0)
                            Text(USBProtocol.switchNameError(model.filename) ?? USBProtocol.switchNameRule)
                                .font(.system(size: 14))
                                .foregroundStyle(USBProtocol.switchNameError(model.filename) == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        }
                        GridRow { Text("圧縮"); Picker("圧縮",selection:$model.compression) { ForEach(Compression.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden() }
                        GridRow {
                            Color.clear.frame(width:0,height:0)
                            Text("TXT: UTF-8 / UTF-16 / シフトJIS → UTF-16LE　 DAT: バイナリ　 GRP: 画像 → BGRA").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 8)
                        }
                    }.disabled(model.busy)
                    .onPreferenceChange(FieldHeightKey.self) { fieldHeight = $0 }
                    VStack(alignment:.trailing,spacing:2) {
                        ProgressView(value:model.progress).frame(maxWidth:.infinity)
                        if let seconds = model.remainingSeconds {
                            HStack(spacing:0) {
                                Text("残り ")
                                Text("\(seconds)").font(.system(size: 14, design: .monospaced))
                                Text(" 秒")
                            }.font(.system(size: 14))
                        }
                    }
                    Text("Switchで USB RECEIVE を開き、WAITING FILE… の状態にしてください").font(.system(size: 14))
                    HStack { Button("Switchへ送信",action:model.send).buttonStyle(.borderedProminent).disabled(model.busy || model.file == nil || model.port.isEmpty || USBProtocol.switchNameError(model.filename) != nil); Button("中止",action:model.stop).disabled(!model.busy); Spacer(); Text("9600 bps · 8N1").foregroundStyle(.secondary) }
                    Text(model.status).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    Spacer(minLength:0)
                }.padding().tabItem { Label("USB送信",systemImage:"cable.connector") }
                VStack(alignment:.leading,spacing:12) {
                    Text("原寸のスクリーンショットを追加します。分割画像は順不同で選択できます。")
                    HStack { Button("画像を追加…",action:model.addImages); Button("一覧をクリア") { model.pages = []; model.imageStatus = "一覧をクリアしました。" }; Spacer(); Button("復元して保存…",action:model.saveImages).buttonStyle(.borderedProminent).disabled(model.pages.isEmpty) }.disabled(model.imageBusy)
                    List {
                        ForEach(model.groups, id: \.first!.page.groupKey) { pages in
                            let first = pages[0].page
                            let count = Set(pages.map(\.page.index)).count
                            let missing = ScreenshotPage.missingPageNumbers(pages.map(\.page))
                            let items = pages.sorted { lhs, rhs in
                                if lhs.page.index != rhs.page.index { return lhs.page.index < rhs.page.index }
                                return lhs.filename < rhs.filename
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(first.name).font(.system(size: 16, weight: .semibold)); Spacer(); Text("\(count) / \(first.total) 枚").foregroundStyle(count == first.total ? .green : .orange) }
                                Text("\(first.fileSize) bytes · \(first.compression == 1 ? "LZSS" : "無圧縮") · CRC \(String(format:"%04X", first.crc))").font(.system(size: 14)).foregroundStyle(.secondary)
                                if !missing.isEmpty {
                                    Text("不足ページ: " + missing.map(String.init).joined(separator: ", "))
                                        .font(.system(size: 14))
                                        .foregroundStyle(.orange)
                                }
                                ForEach(items) { item in
                                    HStack {
                                        Text(item.filename)
                                        Text("ページ \(item.page.index + 1)").foregroundStyle(.secondary)
                                        Spacer()
                                        Button("削除") { model.removeScreenshot(item.id) }
                                            .buttonStyle(.borderless)
                                            .disabled(model.imageBusy)
                                    }
                                    .font(.system(size: 14))
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    if model.imageBusy { ProgressView() }
                    ScrollView { Text(model.imageStatus).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }.frame(height:110)
                    Text("TXTはUTF-8、GRPはPNG、DATはバイナリで保存します。同名ファイルは連番で保存します。").font(.system(size: 14)).foregroundStyle(.secondary)
                }.padding().tabItem { Label("画像から復元",systemImage:"photo.on.rectangle") }
            }
        }
        .font(.system(size: 16))
        .controlSize(.large)
        .padding(20)
        .onAppear { model.restoreRememberedPort(); model.watchPorts(); model.refresh() }
        .onChange(of: model.port) { _, _ in model.updateSelectionStatus() }
        .onChange(of: model.filename) { _, _ in model.updateSelectionStatus() }
    }
}
/// 種類ポップアップの高さを、テキスト欄へ合わせるために渡す。
private struct FieldHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
/// SwiftUI の `TextField` は高さを指定しても枠が伸びない。AppKit の枠を種類欄と同じ高さで描く。
private struct SizedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var height: CGFloat
    var editable: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> FixedHeightTextField {
        let field = FixedHeightTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: 16)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: FixedHeightTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.fixedHeight = height
        field.isEditable = editable && isEnabled
        field.isSelectable = editable && isEnabled
        field.isEnabled = isEnabled
        field.refusesFirstResponder = !editable
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FixedHeightTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.intrinsicContentSize.width
        let measured = height > 0 ? height : nsView.intrinsicContentSize.height
        return CGSize(width: width, height: measured)
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
private final class FixedHeightTextField: NSTextField {
    var fixedHeight: CGFloat = 0 { didSet { if oldValue != fixedHeight { invalidateIntrinsicContentSize() } } }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if fixedHeight > 0 { size.height = fixedHeight }
        return size
    }
}
