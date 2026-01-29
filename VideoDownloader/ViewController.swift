//
//  ViewController.swift
//  VideoDownloader
//
//  Updated 2026-01-29
//

import Cocoa

final class ViewController: NSViewController {

    // MARK: – IBOutlets (Storyboard で接続してください)
    @IBOutlet weak var instructionLabel:     NSTextField!
    @IBOutlet weak var downloadButton:       NSButton!
    @IBOutlet weak var selectCookiesButton:  NSButton!   // Title: cookies.txtを選択…
    @IBOutlet weak var progressLabel:        NSTextField!
    @IBOutlet weak var progressBar:          NSProgressIndicator!
    @IBOutlet weak var thumbnailImageView:   NSImageView!

    // MARK: – Properties
    private let cookiesDefaultsKey = "CookiesFilePath"
    private var cookiesPath: String?                         // ユーザーが選択した cookies.txt
    private var process: Process?
    private var outputPipe: Pipe?

    // MARK: – Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()

        // 以前保存した Cookie パスを取得
        if let saved = UserDefaults.standard.string(forKey: cookiesDefaultsKey),
           FileManager.default.fileExists(atPath: saved) {
            cookiesPath = saved
            // ボタンタイトルを更新（ファイル名だけ表示）
            selectCookiesButton.title = "Cookie: " + (saved as NSString).lastPathComponent
        }

        instructionLabel.stringValue = "クリップボードにコピーした URL から動画をダウンロードします。"
        progressLabel.stringValue    = "進捗状況がここに表示されます。"
        progressLabel.isEditable     = false
        progressLabel.isSelectable   = false

        progressBar.minValue         = 0.0
        progressBar.maxValue         = 100.0
        progressBar.doubleValue      = 0.0
        progressBar.isIndeterminate  = false
    }

    // MARK: – Environment
    /// 親プロセス（Xcode/Terminal等）から継承された Proxy 系の環境変数を除去した環境を返す
    private func sanitizedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let keys = [
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"
        ]
        for k in keys { env.removeValue(forKey: k) }
        return env
    }

    // MARK: – Bundle Helpers
    private func bundledPath(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: nil)
    }

    // MARK: – IBActions
    /// cookies.txt を選択 → UserDefaults に保存
    @IBAction func selectCookiesFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title                   = "cookies.txt を選択"
        panel.allowedFileTypes        = ["txt"]
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        cookiesPath = url.path
        UserDefaults.standard.set(url.path, forKey: cookiesDefaultsKey)

        selectCookiesButton.title = "Cookie: " + url.lastPathComponent
        showInfo("Cookie を設定しました:\n\(url.path)")
    }

    /// ダウンロード開始
    @IBAction func downloadButtonClicked(_ sender: NSButton) {
        downloadVideo()
    }

    // MARK: – Main logic
    private func downloadVideo() {
        // 1) URL をクリップボードから取得
        guard let url = NSPasteboard.general.string(forType: .string),
              url.hasPrefix("http") else {
            showError("クリップボードに有効な URL がありません。")
            return
        }

        // 2) Cookie 未指定なら警告
        guard let cookiesPath = cookiesPath,
              FileManager.default.fileExists(atPath: cookiesPath) else {
            showError("まず『cookies.txtを選択…』ボタンで Cookie ファイルを設定してください。")
            return
        }

        // 3) サムネイル取得（非同期）
        fetchThumbnail(for: url) { [weak self] image in
            DispatchQueue.main.async { self?.thumbnailImageView.image = image }
        }

        // 4) yt-dlp / ffmpeg バンドルパス
        guard let ytDlpPath  = bundledPath("yt-dlp") else {
            showError("yt-dlp ファイルが見つかりません。"); return
        }
        guard let ffmpegPath = bundledPath("ffmpeg") else {
            showError("ffmpeg ファイルが見つかりません。"); return
        }

        // 4.5) Deno (JS runtime) のバンドルパス
        // YouTube の signature / n challenge 対策に必要
        guard let denoPath = bundledPath("deno") else {
            showError("YouTube のダウンロードには JavaScript runtime が必要です。\nResources に deno を同梱してください。")
            return
        }

        // 5) 保存先フォルダ
        let homeDir        = FileManager.default.homeDirectoryForCurrentUser.path
        let downloadFolder = "\(homeDir)/Downloads/YoutubeDownloads"
        if !FileManager.default.fileExists(atPath: downloadFolder) {
            try? FileManager.default.createDirectory(atPath: downloadFolder,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
        }

        let outputTemplate = "\(downloadFolder)/%(title)s_[%(uploader)s]_[%(id)s].%(ext)s"
        let extractorArgs  = "youtube:player_client=default,-ios"

        // 6) yt-dlp 引数
        // - --proxy "" で明示的にプロキシを無効化
        // - --js-runtimes deno:... で YouTube の署名・チャレンジを解けるようにする
        // - mp4(DASH) 優先にして HLS 403 に寄りにくくする
        let arguments: [String] = [
            "--proxy", "",
            "--js-runtimes", "deno:\(denoPath)",
            "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            url,
            "--cookies",            cookiesPath,
            "--extractor-args",     extractorArgs,
            "-o",                   outputTemplate,
            "--ffmpeg-location",    ffmpegPath,
            "--verbose"
        ]

        // 7) 進捗初期化
        progressBar.doubleValue   = 0
        progressLabel.stringValue = "ダウンロード開始..."

        runDownload(executable: ytDlpPath, arguments: arguments)
    }

    // MARK: – Thumbnail
    private func fetchThumbnail(for url: String, completion: @escaping (NSImage?) -> Void) {
        guard let ytDlpPath = bundledPath("yt-dlp") else {
            completion(nil); return
        }
        guard let denoPath = bundledPath("deno") else {
            completion(nil); return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytDlpPath)
        task.environment   = sanitizedEnvironment()  // Proxy 系を継承しない
        task.arguments     = [
            "--proxy", "",
            "--js-runtimes", "deno:\(denoPath)",
            "--no-warnings",
            "--get-thumbnail",
            url
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe

        task.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                completion(nil); return
            }
            guard let urlStr = output.split(separator: "\n")
                .last(where: { $0.hasPrefix("http") }),
                  let thumbURL = URL(string: String(urlStr)) else {
                completion(nil); return
            }

            URLSession.shared.dataTask(with: thumbURL) { data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                completion(image)
            }.resume()
        }

        do {
            try task.run()
        } catch {
            completion(nil)
        }
    }

    // MARK: – yt-dlp 実行
    private func runDownload(executable: String, arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.environment   = sanitizedEnvironment()  // Proxy 系を継承しない
        task.arguments     = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe
        outputPipe          = pipe

        // リアルタイム出力ハンドリング
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self = self else { return }
            let data = h.availableData
            guard !data.isEmpty else { return }

            guard let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }

            DispatchQueue.main.async { self.handleLine(line) }
        }

        task.terminationHandler = { [weak self] t in
            DispatchQueue.main.async {
                (t.terminationStatus == 0)
                    ? self?.showInfo("ダウンロードが完了しました。")
                    : self?.showError("ダウンロードに失敗しました。（code \(t.terminationStatus)）")
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            showError("実行エラー: \(error.localizedDescription)")
        }
    }

    private func handleLine(_ line: String) {
        // 進捗パーセント抽出
        let pat = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)%")
        if let m = pat.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)),
           let r = Range(m.range(at: 1), in: line),
           let v = Double(line[r]) {
            progressBar.doubleValue = v
        }
        progressLabel.stringValue = line
        print("yt-dlp:", line) // デバッグ用
    }

    // MARK: – Alerts
    private func showError(_ msg: String) {
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "エラー"
        a.informativeText = msg
        a.runModal()
    }

    private func showInfo(_ msg: String) {
        let a = NSAlert(); a.alertStyle = .informational
        a.messageText = "完了"
        a.informativeText = msg
        a.runModal()
    }
}
