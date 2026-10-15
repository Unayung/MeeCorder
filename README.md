# Meet Recorder

Mac 選單列上的會議錄音工具。用 Google Meet、Zoom、Teams 或 Slack 開會時，它會自動開始錄音，會議結束後在這台 Mac 上產生逐字稿，分成「我」和「對方」。錄音和逐字稿都不會上傳。

逐字稿是一般的 Markdown 檔，可以貼給 ChatGPT、Claude 這類 AI 工具整理重點和待辦事項，也可以交給其他 agent 處理。

## 需要什麼

- Apple Silicon（M 系列晶片）的 Mac，macOS 15 以上
- 約 1.1 GB 的磁碟空間放語音模型；錄音兩軌合計每小時約 30 MB

## 安裝

1. 到 [Releases](../../releases/latest) 下載 `Meet-Recorder-x.y.dmg`。
2. 打開 DMG，把 Meet Recorder 拖進 Applications 資料夾。
3. 打開 Meet Recorder，允許使用麥克風。選單列會出現麥克風圖示，並開始下載語音模型（只有第一次，約 1.1 GB）。
4. 第一次開會時，macOS 會再問一次「系統音訊錄製」的權限，按允許。這個權限是用來錄下對方的聲音。

## 使用

- **自動錄音**：瀏覽器（Chrome、Edge、Safari、Arc、Brave、Firefox）、Zoom、Teams、Slack 一開始使用麥克風，就開始錄；放開麥克風 30 秒後停止。開始錄音時會跳通知，記得告訴與會者正在錄音。
- **手動**：點選單列圖示，按「開始錄音」或「停止錄音」。不想自動錄，可以在選單裡關掉。
- **逐字稿**：存在 `~/Documents/Meetings/<日期 時間> 會議/transcript.md`，旁邊的 `audio/` 是錄音檔。選單會列出最近五場會議，點名稱就會打開。
- **複製給 AI**：會把整理會議的指示和逐字稿一起複製，直接貼進 AI 工具就行。

用喇叭開會時，對方的聲音會被麥克風收進來。App 會把這種回音從「我」那邊拿掉，戴耳機的效果還是最好。

## 運作方式

- 麥克風和系統音分成兩軌錄，所以分得出誰在說話。系統音是用 Core Audio process tap 錄的，不需要另外裝虛擬音效卡。
- 轉寫用 [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 搭配聯發科的 [Breeze ASR 25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25)。這個模型針對台灣華語夾英文訓練，在 Mac 的 GPU 上跑。另外用 Silero VAD 跳過沒人說話的段落，避免模型在靜音裡編出句子。
- 錄音每 60 秒存一個檔，當機最多只會遺失最後一分鐘。App 重新開啟時，會自動補完上次沒轉寫完的會議。

## 從原始碼建置

需要 Xcode 26 以上。

```sh
gh release download b5454 -R ggml-org/whisper.cpp -p '*xcframework.zip' -D vendor && unzip -q -d vendor vendor/*.zip
curl -fL --http1.1 -o vendor/ggml-silero-v6.2.0.bin \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin
./build.sh              # 產出 build/Meet Recorder.app
./build.sh --install    # 再複製到 ~/Applications
```

`package.sh` 會用 Developer ID 簽章、送 Apple 公證，再包成 DMG。使用方式寫在檔案開頭。

不開 App 也能測試：

```sh
MeetRecorder --self-test               # 回音判斷和幻聽過濾的檢查
MeetRecorder --test-record 20 --out DIR  # 錄 20 秒
MeetRecorder --transcribe DIR          # 轉寫一個會議資料夾
```

## 授權

MIT，見 [LICENSE](LICENSE)。內含的第三方元件見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
