import Cocoa

class ViewController: NSViewController {
    @IBOutlet weak var instructionLabel: NSTextField!
    @IBOutlet weak var downloadButton: NSButton!
    @IBOutlet weak var progressLabel: NSTextField!
    @IBOutlet weak var progressBar: NSProgressIndicator!
    @IBOutlet weak var thumbnailImageView: NSImageView!

    var process: Process?
    var outputPipe: Pipe?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        instructionLabel.stringValue = "クリップボードにコピーしたURLから動画をダウンロードします。"
        progressLabel.stringValue = "進捗状況がここに表示されます。"
        progressLabel.isEditable = false
        progressLabel.isSelectable = false
        progressBar.minValue = 0.0
        progressBar.maxValue = 100.0
        progressBar.doubleValue = 0.0
        progressBar.isIndeterminate = false
    }

    @IBAction func downloadButtonClicked(_ sender: NSButton) {
        downloadVideo()
    }

    func downloadVideo() {
        guard let url = NSPasteboard.general.string(forType: .string), url.hasPrefix("http") else {
            showError("クリップボードに有効なURLがありません。")
            return
        }

        fetchThumbnail(for: url) { [weak self] image in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.thumbnailImageView.image = image

                // yt-dlp, ffmpegのパス取得
                guard let ytDlpPath = Bundle.main.path(forResource: "yt-dlp", ofType: nil) else {
                    self.showError("yt-dlpファイルが見つかりません。")
                    return
                }
                
                guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
                    self.showError("ffmpegファイルが見つかりません。")
                    return
                }

                // クッキーのパス（事前にエクスポートしたcookies.txt）
                let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
                let cookiesPath = "\(homeDir)/Downloads/cookies.txt" // 必要に応じて変更

                // ダウンロード先フォルダを指定
                let downloadFolder = "\(homeDir)/Downloads/YoutubeDownloads"
                
                // フォルダが存在しない場合は作成
                if !FileManager.default.fileExists(atPath: downloadFolder) {
                    do {
                        try FileManager.default.createDirectory(atPath: downloadFolder, withIntermediateDirectories: true, attributes: nil)
                    } catch {
                        self.showError("ダウンロードフォルダの作成に失敗しました。")
                        return
                    }
                }

                // 出力ファイルのパターンを設定
                let downloadsPath = "\(downloadFolder)/%(title)s_[%(uploader)s]_[%(id)s].%(ext)s"

                // extractor-argsの設定
                let extractorArgs = "youtube:player_client=default,-ios"

                // yt-dlpの引数を設定
                let arguments = [
                    "-f", "bestvideo+bestaudio[ext=m4a]/best",
                    url,
                    "--cookies-from-browser", "chrome",
                    "--extractor-args", extractorArgs,
                    "-o", downloadsPath,
                    "--ffmpeg-location", ffmpegPath,
                    "--verbose" // デバッグ用に追加
                ]

                self.progressBar.doubleValue = 0
                self.progressLabel.stringValue = "ダウンロード開始..."

                self.runDownload(executable: ytDlpPath, arguments: arguments)
            }
        }
    }

    func fetchThumbnail(for url: String, completion: @escaping (NSImage?) -> Void) {
        guard let ytDlpPath = Bundle.main.path(forResource: "yt-dlp", ofType: nil) else {
            completion(nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytDlpPath)
        task.arguments = ["--no-warnings", "--get-thumbnail", url]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        task.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }

            // 出力を改行で分割
            let lines = output.components(separatedBy: .newlines)
            // 空行を除いて最後の有効な行を取得
            let filteredLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard let lastLine = filteredLines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                  lastLine.hasPrefix("http") || lastLine.hasPrefix("https"),
                  let thumbURL = URL(string: lastLine) else {
                completion(nil)
                return
            }

            // URLSessionで画像をダウンロード
            URLSession.shared.dataTask(with: thumbURL) { data, response, error in
                if let error = error {
                    print("サムネイルダウンロードエラー: \(error)")
                    completion(nil)
                    return
                }

                guard let data = data, !data.isEmpty,
                      let image = NSImage(data: data) else {
                    completion(nil)
                    return
                }

                completion(image)
            }.resume()
        }

        do {
            try task.run()
        } catch {
            completion(nil)
        }
    }

    func runDownload(executable: String, arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        self.outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if data.isEmpty { return }

            if let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                DispatchQueue.main.async {
                    self.handleLine(output)
                }
            }
        }

        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                if task.terminationStatus == 0 {
                    self?.showInfo("ダウンロードが完了しました。")
                } else {
                    self?.showError("ダウンロードに失敗しました。ステータスコード: \(task.terminationStatus)")
                }
            }
        }

        do {
            try task.run()
            self.process = task
        } catch {
            showError("実行中にエラーが発生しました: \(error.localizedDescription)")
        }
    }

    func handleLine(_ line: String) {
        print("yt-dlp: \(line)") // デバッグ用にコンソールに出力
        let regex = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)%")
        if let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
            if let progressRange = Range(match.range(at: 1), in: line) {
                if let progressValue = Double(String(line[progressRange])) {
                    progressBar.doubleValue = progressValue
                }
            }
        }
        progressLabel.stringValue = line
    }

    func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "エラー"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func showInfo(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "完了"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
