import tkinter as tk
from tkinter import messagebox, filedialog, ttk
from PIL import Image, ImageTk
import pyperclip
import subprocess
import threading
import re
import requests
from io import BytesIO
import json
import os
import signal
import sys

# ユーザーのDocumentsディレクトリに保存
SETTINGS_FILE = os.path.expanduser("~/Documents/settings.json")

# 設定を保存する関数
def save_settings():
    global save_directory
    settings = {
        "save_directory": save_directory
    }
    with open(SETTINGS_FILE, "w") as f:
        json.dump(settings, f)

# 設定を読み込む関数
def load_settings():
    global save_directory
    if os.path.exists(SETTINGS_FILE):
        with open(SETTINGS_FILE, "r") as f:
            settings = json.load(f)
            save_directory = settings.get("save_directory", "")
            if save_directory:
                save_label.config(text=f"保存先: {save_directory}")
            else:
                save_label.config(text="保存先が選択されていません")
    else:
        save_label.config(text="保存先が選択されていません")

# 保存先ディレクトリを選択する関数
def select_save_directory():
    global save_directory
    selected_directory = filedialog.askdirectory()
    if selected_directory:
        save_directory = selected_directory
        save_label.config(text=f"保存先: {save_directory}")
        save_settings()

# 動画をダウンロードする関数
def download_video():
    global save_directory
    url = pyperclip.paste()

    if url and save_directory:
        threading.Thread(target=get_video_info, args=(url,)).start()
        command = [
            '/Users/adolfoi/myenv/bin/yt-dlp',  # yt-dlp のフルパスを指定
            '--no-check-certificate',
            '-f', 'bestvideo+bestaudio',
            '--merge-output-format', 'mp4',
            '--cookies', './cookies.txt',
            '-o', f'{save_directory}/%(title)s.%(ext)s',
            url
        ]
        threading.Thread(target=run_download, args=(command,)).start()
    else:
        messagebox.showwarning("警告", "URLか保存先が指定されていません。")

# メタデータを取得する関数
def get_video_info(url):
    command = [
        '/Users/adolfoi/myenv/bin/yt-dlp',  # yt-dlp のフルパスを指定
        '--no-check-certificate',
        '--print', '%(title)s', '--print', '%(thumbnail)s',
        url
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    
    stdout, stderr = process.communicate()
    output = stdout.splitlines()

    if stderr:
        print(f"エラーが発生しました: {stderr}")
        return
    
    if len(output) >= 2:
        title = output[0]
        thumbnail_url = output[1]
        update_video_info(title, thumbnail_url)
    else:
        print("メタデータの取得に失敗しました")

# 動画情報を表示する関数
def update_video_info(title, thumbnail_url):
    if not thumbnail_url.startswith("http://") and not thumbnail_url.startswith("https://"):
        print(f"無効なサムネイルURLです: {thumbnail_url}")
        return

    title_label.config(text=title)

    try:
        response = requests.get(thumbnail_url)
        response.raise_for_status()
        img_data = BytesIO(response.content)
        img = Image.open(img_data)
        img = img.resize((200, 120))
        thumbnail_image = ImageTk.PhotoImage(img)
        thumbnail_label.config(image=thumbnail_image)
        thumbnail_label.image = thumbnail_image
    except requests.exceptions.RequestException as e:
        print(f"サムネイルの取得に失敗しました: {e}")

# ダウンロードを実行する関数
def run_download(command):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, universal_newlines=True)
    
    for line in process.stdout:
        match = re.search(r"(\d+(\.\d+)?)%", line)
        if match:
            progress = float(match.group(1))
            update_progress(progress)
    
    process.wait()

    if process.returncode == 0:
        messagebox.showinfo("完了", "ダウンロードが完了しました。")
    else:
        messagebox.showerror("エラー", "ダウンロード中にエラーが発生しました。")

# プログレスバーを更新する関数
def update_progress(progress):
    app.after(0, lambda: progress_var.set(progress))

# シグナルをキャッチしてウィンドウを閉じるための関数
def handle_signal(signum, frame):
    print(f"シグナル {signum} を受信しました。ウィンドウを閉じます。")
    app.quit()  # tkinterアプリケーションを終了

# シグナルハンドリングを設定
signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)

# GUIアプリケーションの作成
app = tk.Tk()
app.title("Video Downloader")

# 説明ラベル
label = tk.Label(app, text="クリップボードにコピーしたURLから動画をダウンロードします。")
label.pack(pady=10)

# 保存先選択ボタンとラベル
save_button = tk.Button(app, text="保存先を選択", command=select_save_directory)
save_button.pack(pady=5)

save_label = tk.Label(app, text="保存先が選択されていません")
save_label.pack(pady=5)

# 動画タイトルラベル
title_label = tk.Label(app, text="動画タイトル", font=("Arial", 14), wraplength=380)
title_label.pack(pady=5)

# サムネイル表示ラベル
thumbnail_label = tk.Label(app)
thumbnail_label.pack(pady=5)

# プログレスバーの設定
progress_var = tk.DoubleVar()
progress_bar = ttk.Progressbar(app, variable=progress_var, maximum=100)
progress_bar.pack(pady=10, padx=20, fill='x')

# ダウンロードボタン
download_button = tk.Button(app, text="ダウンロード", command=download_video)
download_button.pack(pady=10)

# GUIウィンドウのサイズを設定
app.geometry("400x500")

# 設定をロード
load_settings()

# 定期的にシグナルチェックを行う関数
def check_signals():
    app.after(100, check_signals)

# シグナルを定期的に確認する
app.after(100, check_signals)

# メインループ
try:
    app.mainloop()
except KeyboardInterrupt:
    print("アプリケーションが中断されました。")
    sys.exit(0)
