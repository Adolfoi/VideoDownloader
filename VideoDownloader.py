import tkinter as tk
from tkinter import messagebox
import pyperclip
import subprocess

def download_video():
    # クリップボードからURLを取得
    url = pyperclip.paste()
    
    # URLが空でないことを確認
    if url:
        command = ['yt-dlp', '--no-check-certificate', '-f', 'mp4', '--cookies', './cookies.txt', url]
        
        try:
            # yt-dlpコマンドを実行
            subprocess.run(command, check=True)
            messagebox.showinfo("完了", "ダウンロードが完了しました。")
        except subprocess.CalledProcessError as e:
            messagebox.showerror("エラー", f"ダウンロード中にエラーが発生しました: {str(e)}")
    else:
        messagebox.showwarning("警告", "クリップボードに有効なURLがありません。")


# GUIアプリケーションの作成
app = tk.Tk()
app.title("Video Downloader")

# 説明ラベル
label = tk.Label(app, text="クリップボードにコピーしたURLから動画をダウンロードします。")
label.pack(pady=10)

# ダウンロードボタン
download_button = tk.Button(app, text="ダウンロード", command=download_video)
download_button.pack(pady=10)

# GUIウィンドウのサイズを設定
app.geometry("400x150")

# メインループ
app.mainloop()

