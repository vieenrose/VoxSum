<p align="center">
  <img src="docs/screenshots/app-icon.png" width="96" alt="VoxSum" />
</p>

<h1 align="center">VoxSum for Android</h1>

<p align="center">
  <b>會議錄音 → 標註語者的逐字稿 → 摘要。<br>全程在手機上完成，完全離線。</b>
</p>

<p align="center">
  <a href="https://github.com/vieenrose/VoxSum/releases/latest"><img alt="版本" src="https://img.shields.io/github/v/release/vieenrose/VoxSum?sort=semver"></a>
  <img alt="平台" src="https://img.shields.io/badge/Android-8.0%2B-3DDC84?logo=android&logoColor=white">
  <img alt="授權" src="https://img.shields.io/badge/license-GPL--3.0-blue">
</p>

<p align="center"><img src="docs/screenshots/demo-studio.gif" width="300" alt="錄音室：連續錄兩場會議"><br><sub>錄音室：連續錄兩場會議。從空的資料庫開始，錄完公司尾牙籌備會議後按「下一場」，立即接著錄辦公室搬遷會議；第一場的 AI 筆記在背景接續整理，停止後兩場都自動完成筆記、摘要與標題。錄音段落以 4 倍速播放，最後的資料庫瀏覽為即時。於 Galaxy Note10+ 錄製，AI 筆記模型：行動版 E4B。</sub></p>

## 特色

- **完全離線、無帳號**：音訊不離開手機，模型只在第一次使用時下載。
- **即時逐字稿與語者**：說話約 0.4 秒後文字上螢幕，同時標註語者（AMI / AISHELL-4 語者歸屬正確率 95.4% / 92.3%）。
- **邊開會邊做筆記**：AI 筆記在錄音中閱讀逐字稿，寫下決議、待辦與數字；停止後約 1.5 分鐘完成摘要。
- **每句都可核對**：摘要與筆記的時間點一下，就從原話開始播放。
- **錄音不會遺失**：停止即存檔，可連續錄多場，稍後再批次處理。
- **可編輯、可匯出**：修正文字與語者；匯出 `.m4a`、PDF、Markdown 或字幕。
- **依手機調整**：首次啟動自動偵測核心數並做一秒測試選執行緒；全程使用 CPU 推論；GPU／NPU 暫不提供（閱讀器的圖在 GPU 上無法執行，研究見 [`docs/GPU_NPU.md`](docs/GPU_NPU.md)）。

## 畫面

| 錄音 | AI 筆記 | 摘要 | 逐字稿 |
|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/qs-capture.png" width="200" alt="錄音"> | <img src="docs/screenshots/05-agent.png" width="200" alt="AI 筆記"> | <img src="docs/screenshots/04-summary.png" width="200" alt="摘要"> | <img src="docs/screenshots/03-transcript.png" width="200" alt="逐字稿"> |

<p align="center"><img src="docs/screenshots/agent-live.gif" width="280" alt="錄音中 AI 筆記即時寫下筆記"><br><sub>錄音進行中，AI 筆記讀完一段逐字稿後逐字寫下筆記。</sub></p>

示範會議為兩場合成會議：尾牙籌備會議與辦公室搬遷會議（各三位語者，約 7 分半，[`docs/demo`](docs/demo)），在 Galaxy Note10+ 上即時錄音拍攝，未經修飾。

## 使用

**錄音**：逐字稿即時出現，語者確定後標上顏色。上方的 AI 筆記卡片顯示它在閱讀逐字稿或正在寫筆記。**下一場**存檔並立即開始下一場；**停止並儲存**直接開啟這場會議，約 1.5 分鐘後摘要完成。

**AI 筆記**：每則筆記標示類型（決議、待辦、提議、未決、數字）與時間；決議、待辦與數字可「核對」，一點就跳到原話。「顯示詳細過程」可看每段的處理情形。

**摘要**：段落式摘要，藍色時間點可直接播放；下方一行是各語者的發言比例。

**逐字稿**：點任一句從該處播放；長按可修改文字或改派語者；點標題可改名。

**匯出與重新處理**（場次右上 **⋮**）：

- **VoxSum 場次（.m4a）**：音訊、逐字稿、語者與摘要合為一檔，任何播放器都能播放，也可在 VoxSum 重新開啟。
- **文件**：PDF、Markdown、純文字。**字幕**：SRT、VTT、LRC（含語者）。
- **重新轉錄**（重跑語音辨識與語者分離）或**重新摘要**（保留逐字稿）。

**匯入**：首頁 **＋** 可加入手機上的音訊檔、Podcast、YouTube，或從其他 App 分享音訊過來。

**設定**：外觀（自動、淺色、深色、電子紙）、文字大小（85–150%，整個 App）、硬體狀態列、語言（English、繁體中文、简体中文，介面與產生的文字一起切換）、語者標註延遲、AI 筆記模型（E2B，或 8 GB 手機可選 E4B）、模型管理。

<details>
<summary>更多畫面：匯出、重新處理、設定、匯入</summary>

| 匯出 | 重新處理 | 設定 | 匯入 |
|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/export.png" width="200" alt="匯出"> | <img src="docs/screenshots/reprocess.png" width="200" alt="重新處理"> | <img src="docs/screenshots/settings.png" width="200" alt="設定"> | <img src="docs/screenshots/import.png" width="200" alt="匯入"> |

</details>

## 安裝

從 [**Releases**](https://github.com/vieenrose/VoxSum/releases/latest) 下載 APK。

- Android 8.0 以上，ARMv8.2（dotprod）處理器，約 2019 年後的手機。
- 模型首次使用時下載：語音引擎約 275 MB，AI 筆記模型 E2B 約 2.2 GB（E4B 約 3.3 GB），下載後準備一次（約一分鐘）。
- RAM 8 GB 以上：AI 筆記在錄音中同步閱讀；較小的手機在錄音結束後閱讀。
- 唯一的網路連線：下載模型，以及每天檢查一次新版本。

## 已知限制

- 摘要模型以中文會議訓練，英文會議也會寫出中文摘要。
- 會議紀錄中約六分之一的內容與原話不符（E2B，上游量測；E4B 約九分之一），請點時間核對。
- 很長的會議：AI 筆記每段只帶著精簡過的前段筆記閱讀，寫標題與摘要時也只取最重要的筆記（決議、未決、待辦優先），早段的細節可能不會出現在摘要裡。
- 偶爾會多分出發言很少的語者，可用「合併語者」修正；語音辨識漏掉標點時，換人的位置可能落在一個詞的中間。
- E4B 只能在 RAM 8 GB 以上的手機選用；錄音中同時執行時整個 App 約佔 4 GB 記憶體。

## 運作方式

- **聽寫**：[nemo-x-asr-diarizer](https://github.com/vieenrose/nemo-x-asr-diarizer.cpp) 是單一串流引擎，在同一條時間軸上完成語音辨識（X-ASR）與語者分離（Nemotron-3）。
- **AI 筆記與摘要**：[Gemma-4-E2B 會議模型（行動版）](https://huggingface.co/Luigi/gemma-4-E2B-meeting-agent-zh-GGUF/tree/main/mobile-v1) 在 [LiteRT](https://github.com/google-ai-edge/LiteRT) 上執行（[自訂引擎](https://github.com/vieenrose/LiteRT-LM/tree/mobile-fused-attention)）；8 GB 記憶體的手機可改用 [E4B](https://huggingface.co/Luigi/gemma-4-E4B-meeting-agent-zh-LiteRT)。

錄音時，語音辨識優先（它落後就會漏音）；AI 筆記在背景把已確定的句子讀進上下文，每累積約 1,500 token（數分鐘的語音）才真正閱讀一次並寫筆記。停止後只剩最後一段要讀，所以摘要很快完成。在 Galaxy Note 10+（Snapdragon 855）上，約 7 分半的示範會議即時錄音，摘要於停止後約 77 秒完成，記憶體峰值 2.4 GB；改用 E4B 約 3 分鐘、4.0 GB。

AI 筆記（閱讀代理）的設計——閱讀協定、筆記類型、約 1,500 token 的閱讀窗、4k 上下文（每段從精簡過的筆記重新開始）、標題與摘要的呼叫——見 meeting-summarizer 的 [`docs/voxsumdroid-integration.md`](https://github.com/vieenrose/meeting-summarizer/blob/main/docs/voxsumdroid-integration.md)。VoxSum 與該協定只有兩處不同：每窗筆記超過上限時優先保留決議與待辦；錄音停止後即使即時辨識漏掉部分音訊，也直接以即時逐字稿寫摘要。

完整操作說明（含介面測試地圖）見 [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md)。模組對應見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，準確度評測見 [`tools/nemo-eval`](tools/nemo-eval/README.md)。

## 從原始碼建置

需要 Android Studio、SDK 35、NDK 27.2：

```bash
git clone https://github.com/vieenrose/VoxSum.git && cd VoxSum
git submodule update --init           # 不要加 --recursive
./gradlew :app:assembleDebug          # arm64-v8a；模擬器用 -PvoxsumAbi=x86_64
./gradlew :app:testDebugUnitTest
scripts/test-on-device.sh             # 裝置上的儀器測試（獨立 app ID，不影響正式版）
```

## 授權

應用程式以 [GPL-3.0-or-later](LICENSE) 授權；模型與資料各依其授權：

<table>
  <tr><th>元件</th><th>授權</th><th>相關子專案</th></tr>
  <tr><td>X-ASR（語音辨識）</td><td>Apache-2.0</td><td rowspan="2"><a href="https://github.com/vieenrose/nemo-x-asr-diarizer.cpp">nemo-x-asr-diarizer.cpp</a><br>（語音辨識與語者分離整合為單一串流引擎）</td></tr>
  <tr><td>Nemotron-3 Diarization（語者分離）</td><td>OpenMDW-1.1</td></tr>
  <tr><td>Gemma-4-E2B 會議模型（AI 筆記、摘要）</td><td>Apache-2.0</td><td><a href="https://github.com/vieenrose/meeting-summarizer">meeting-summarizer</a><br>（閱讀代理的訓練與協定）</td></tr>
  <tr><td>示範會議音訊（以 VibeVoice-1.5B 合成）</td><td>MIT</td><td><a href="docs/demo">docs/demo</a></td></tr>
  <tr><td>AISHELL-4（語者歸屬正確率評測）</td><td>CC BY-SA 4.0</td><td rowspan="2"><a href="tools/nemo-eval/README.md">tools/nemo-eval</a></td></tr>
  <tr><td>AMI（語者歸屬正確率評測）</td><td>CC BY 4.0</td></tr>
</table>
