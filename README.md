<p align="center">
  <img src="docs/screenshots/app-icon.png" width="96" alt="VoxSum" />
</p>

<h1 align="center">VoxSum for Android</h1>

<p align="center">
  <b>會議錄音 → 標註語者的逐字稿 → 摘要。<br>全程在手機上完成，完全離線。</b>
</p>

<p align="center">
  <a href="https://github.com/vieenrose/VoxSumDroid/releases/latest"><img alt="版本" src="https://img.shields.io/github/v/release/vieenrose/VoxSumDroid?sort=semver"></a>
  <img alt="平台" src="https://img.shields.io/badge/Android-8.0%2B-3DDC84?logo=android&logoColor=white">
  <img alt="授權" src="https://img.shields.io/badge/license-GPL--3.0-blue">
</p>

<p align="center"><img src="docs/screenshots/demo.gif" width="300" alt="錄音室、會議代理、摘要點時間播放、逐字稿、行動項目"></p>

## 特色

- **完全離線、無帳號** —— 音訊不離開手機；模型首次使用時下載一次。
- **即時逐字稿＋語者** —— 說話約 0.4 秒後文字上螢幕，語者在同一條串流中標註（AMI / AISHELL-4 語者歸屬正確率 95.4% / 92.3%）。
- **邊開會邊寫摘要** —— 會議代理在錄音時閱讀逐字稿、寫下決議／待辦／提議／未決／數字筆記；停止後約 1.5 分鐘完成段落式摘要，每個時間點一下就播放。
- **錄音不會遺失** —— 停止即存檔；可連場錄音，稍後批次處理。
- **可編輯、可匯出** —— 修正文字與語者；匯出 `.m4a`（含逐字稿與摘要）、PDF、Markdown、字幕。

## 截圖

<p><i>示範會議：AISHELL-4 L_R004S02C01（CC BY-SA 4.0）</i></p>

### 錄音室

<p align="center"><img src="docs/screenshots/qs-capture.png" width="280" alt="錄音室"></p>

錄音時逐字稿即時出現；語者確定後，每句左側出現該語者的顏色並標上時間，尚未確定的句子以淺灰顯示。上方的會議代理卡片顯示它正在聆聽或撰寫，以及距離下一次閱讀的進度。

### 會議代理

<p align="center"><img src="docs/screenshots/05-agent.png" width="280" alt="會議代理"></p>

代理的閱讀過程：最新的片段在最上面，正在寫的筆記逐字出現，每則筆記標示類型（決議、待辦、提議、未決、數字）與時間，決議、待辦與數字另有「核對」可跳到原話；較早片段的筆記收合為「+n 則筆記」。

### 摘要

<p align="center"><img src="docs/screenshots/04-summary.png" width="280" alt="摘要"></p>

會議結束後的段落式摘要；每個藍色時間點一下即從該處播放。下方是各語者的發言比例。

### 逐字稿

<p align="center"><img src="docs/screenshots/03-transcript.png" width="280" alt="逐字稿"></p>

依語者標註顏色的完整逐字稿；點任一句即跳到該處播放，播放時目前的句子會高亮。

## 安裝

從 [**Releases**](https://github.com/vieenrose/VoxSumDroid/releases/latest) 下載 APK 安裝。

- Android 8.0 以上，ARMv8.2（dotprod）處理器 —— 約 2019 年後的手機。
- 模型：語音引擎約 275 MB，會議代理約 3.35 GB。
- RAM 8 GB 以上時，代理在錄音中同步閱讀；較小的手機在錄音結束後閱讀。
- 唯一的網路請求：下載模型，以及每天一次檢查新版本。

> 第一次使用？看 **[5 分鐘快速上手](docs/QUICKSTART.zh-TW.md)**。

## 已知限制

- 摘要模型以中文會議訓練，英文會議也會寫出中文摘要。
- 約 18% 的筆記敘述與逐字稿不符（上游量測）—— 點時間即可核對。
- 偶爾會多分出一位發言很少的語者，可用「合併語者」修正。

## 運作方式

語音辨識＋語者分離是一個串流引擎（[nemo-x-asr-diarizer](https://github.com/vieenrose/nemo-x-asr-diarizer.cpp)：X-ASR ＋ Nemotron-3），
摘要是在 [llama.cpp](https://github.com/ggml-org/llama.cpp) 上執行的
[Gemma-4-E2B 會議代理](https://huggingface.co/Luigi/gemma-4-E2B-meeting-agent-zh-GGUF)。
兩者同時運作：語音辨識優先，代理在背景預填逐字稿，每約 4 分鐘的語音讀一次並寫筆記。
在 OPPO Reno7（8 GB）上，10 分鐘會議的摘要在錄音結束後 87 秒完成，記憶體峰值 3.0 GB。
模組對應見 [`ARCHITECTURE.md`](ARCHITECTURE.md)，準確度評測見 [`tools/nemo-eval`](tools/nemo-eval/README.md)。

## 從原始碼建置

需要 Android Studio、SDK 35、NDK 27.2：

```bash
git clone https://github.com/vieenrose/VoxSumDroid.git && cd VoxSumDroid
git submodule update --init           # 不要加 --recursive
./gradlew :app:assembleDebug          # arm64-v8a；模擬器用 -PvoxsumAbi=x86_64
./gradlew :app:testDebugUnitTest
scripts/test-on-device.sh             # 裝置上的儀器測試（獨立 app ID，不影響正式版）
```

發版流程見 [`RELEASING.md`](RELEASING.md)。

## 授權

[GPL-3.0-or-later](LICENSE)。模型各依其授權：X-ASR（Apache-2.0）、Nemotron-3 Diarization（OpenMDW-1.1）、Gemma-4-E2B 會議代理（Apache-2.0）。
