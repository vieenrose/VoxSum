<p align="center">
  <img src="docs/screenshots/app-icon.png" width="96" alt="VoxSum" />
</p>

<h1 align="center">VoxSum for Android</h1>

<p align="center">
  <b>Turn any audio into a clean, speaker-labelled transcript and a short summary —<br>entirely on your phone, fully offline.</b>
</p>

<p align="center">
  <a href="https://github.com/vieenrose/VoxSumDroid/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/vieenrose/VoxSumDroid?sort=semver"></a>
  <img alt="Platform" src="https://img.shields.io/badge/Android-8.0%2B-3DDC84?logo=android&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-blue">
  <img alt="Offline" src="https://img.shields.io/badge/network-not%20required-success">
</p>

<p align="center"><a href="README.zh-TW.md">繁體中文說明 →</a></p>

---

Record a meeting, open a voice memo, drop in a podcast or a YouTube link — VoxSum writes out **who said
what**, then gives you a **concise summary** in the language you choose. Everything happens **on the
device**: no account, no cloud, no subscription, and nothing ever leaves your phone.

VoxSum is a **recording studio**: the home screen is your **session list**, every recording is
**auto-saved the moment you stop** (a crash or a stray tap can never lose one), and **recording never
waits for processing** — capture talks back-to-back all day, then let the app transcribe and summarize
them one by one while you watch each session's live status.

> New here? The **[5-minute Quick Start →](docs/QUICKSTART.md)** walks through every feature.

<p align="center"><img src="docs/screenshots/demo.gif" width="300" alt="VoxSum demo — open a session, read the prose summary, tap a time to play from there"></p>
<p align="center"><i>Open a finished session: the summary, the speaker-tagged transcript, and tap-to-play with the current line highlighted.<br>
Demo meeting: AMI Meeting Corpus ES2004a (CC BY 4.0). The summary model writes in Chinese, including for English meetings.</i></p>

## Why VoxSum

- 🛡️ **Private by design** — your audio never leaves the phone, so confidential recordings can't leak to a cloud.
- ✈️ **Works offline** — once set up, no network is needed: on a plane, a train, or off the grid.
- 💰 **No subscription** — own it outright. No metered minutes, no monthly fee.

## Screenshots

<p align="center">
  <img src="docs/screenshots/01-home.png" width="190" alt="Home">
  <img src="docs/screenshots/03-transcript.png" width="190" alt="Transcript">
  <img src="docs/screenshots/04-summary.png" width="190" alt="Summary">
  <img src="docs/screenshots/05-agent.png" width="190" alt="Meeting agent — live notes">
</p>
<p align="center"><i>The studio home (session list with live statuses) · live transcript with speakers · summary · summary-language picker</i></p>

## What you can do

**🎛️ Work like a studio**
- **The home screen is your session list** — every recording, with its live status: *Not processed · Queued · Processing (with phase and %) · Done*.
- **Record talks back-to-back** — a full-screen recording booth with a big timer, mic level bars, and two giant buttons: **⏭ Next talk** ends one session and instantly starts the next (its processing is deferred); **⏹ Stop & save** saves and processes in the background while you're free to record again.
- **Never lose a recording** — audio is saved to the library the moment the mic stops, even on a crash or an accidental stop; finished sessions embed their transcript + summary into a self-contained `.m4a` automatically.
- **Process on your schedule** — *Process pending (n)* transcribes, diarizes, summarizes and titles every saved recording in the background. Batches are processed **efficiently**: everything is transcribed first, then the summarizer loads **once** for the whole batch — and the queue survives app kills, resuming without redoing any finished work.
- **Manage your files** — tap or long-press any session: *Process now · Rename · Share audio · Delete* — plus *Remove from queue* on a queued session and *Stop processing* on the one being processed. Name a session while recording — your name always outranks the AI-generated title.

**🎙️ Bring in audio from anywhere**
- **A file** on your device — most common audio and video formats work.
- **Share from another app** — send a voice note or an audio/video file straight to VoxSum (from LINE, a recorder, your browser…) and it starts transcribing.
- **Record live** — watch the transcript appear sentence by sentence as you speak (a collapsible strip in the recording booth), with **mic level bars** so you know it hears you.
- **A podcast** — search, pick an episode, and transcribe it.
- **A YouTube link** — paste a URL, or search by keyword.
- **Reopen a saved session** — tap any *Done* session in the list and pick up exactly where you left off.

**📝 Read and understand**
- **Live transcript** — lines show up as soon as you speak; you can start reading (and playing) before it finishes.
- **Who spoke when, live** — speakers are identified *while* the words are transcribed, in the same pass: each line is tagged and colour-coded by speaker as you record, with an automatic speaker count (up to 8 speakers). Benchmarked on the AMI and AISHELL-4 meeting corpora at **95.4% / 92.3%** time-weighted attribution while labelling **99%** of the speech ([details](tools/nemo-eval/README.md)). VoxSum can even **guess speakers' real names** from what they say.
- **Minutes written live** — while you record, a meeting agent reads along and writes short notes — **decisions, actions, open issues, key figures** — each with a tap-to-play timestamp; the minutes are ready about a minute after the meeting ends. Chinese can be shown in **繁體中文** or **简体中文** (defaulting from your phone's region).
- **Action items & decisions** — pull a draft checklist of who-does-what and the key decisions out of a meeting, ready to edit.
- **Search the transcript** — find any word in a long recording; matches highlight and you can step through them.
- **A built-in player, in sync** — docked at the bottom like a music app: tap any line to jump there, and the current line highlights as it plays.
- **Easy on the eyes** — **Light**, **Dark**, or a flat high-contrast **E-ink** theme built for e-paper readers (Boox and the like). **Auto** — the default — follows your system's light/dark setting. Switch any time in **Settings → Appearance**.

**✏️ Make it yours**
- **Edit anything** — fix a word, rename a speaker, tweak the title or summary, right in place.
- **Fix the speakers** — move a misattributed line to the right person, or merge two speakers into one.
- **Copy** the whole summary with one tap.
- **Export the words** — one **Export & share…** sheet, grouped by what you get: the **VoxSum session** (`.m4a`), a **document** (**PDF**, **Markdown**, plain text) carrying the title, summary, action items and the timestamped transcript, or **subtitles** (`.srt`/`.vtt`/`.lrc`) with speaker labels. Everything can be **saved or shared**, and the transcript copies to the clipboard in one tap.
- **Re-run** the transcription, the summary, **just the speaker detection** (*Re-detect speakers*), or the speaker-name detection whenever you like — and VoxSum keeps everything consistent: edit the transcript and it offers a one-tap **re-summarize**, which also refreshes the title (unless you wrote your own). Switching just between **繁體中文 ↔ 简体中文** converts the title, summary, and transcript **instantly**, no re-run needed.
- **Save or share as one file** — the whole session (audio + transcript + summary + speakers + a cover) packs into a single **`.m4a`**. It **plays in any music app** — showing the title, cover, summary, and the **time-synced transcript** as [scrolling lyrics](#synced-lyrics-in-android-music-players) — and **reopens in VoxSum** with everything intact. `.m4a` reaches the widest set of players (iPhones, cars, every app); older `.ogg` sessions still open too.

## Languages

- **Transcription** handles English, Chinese, and speech that mixes the two.
- **Summaries** are written in the recording's language, in Traditional or Simplified Chinese script for Chinese.
- **The app itself** is available in **English and 繁體中文**.

## Install

The small AI models are **not** bundled — they download once on first use, then the app runs fully
offline. Two ways to install:

**Via F-Droid (recommended — automatic updates).** In your F-Droid client, add this repository
(**Settings → Repositories → ➕**), then install VoxSum from it:

```
https://vieenrose.github.io/VoxSumDroid/repo?fingerprint=c9fe46eb7d87d4fa4e2340a73f78a602eafbab655cbe7c7cb4ead5ab7a00b088
```

<img src="docs/screenshots/fdroid-repo-qr.png" width="150" alt="F-Droid repo QR"> &nbsp; *(or scan to add the repo)*

It's a self-hosted repository (not the official f-droid.org store), so adding it is a one-time step —
after that, updates arrive automatically.

**Sideload the APK.** Download the latest signed APK from the
[**Releases page**](https://github.com/vieenrose/VoxSumDroid/releases/latest) and open it to install
(Android may ask for permission to install from your browser or file manager).

## Good to know

- **First run downloads models.** The first time you use a feature, VoxSum fetches the model it needs
  from **Hugging Face**, verifies its integrity, and caches it. After that you
  can go fully offline. Downloads **resume where they left off** on flaky Wi-Fi, and a corrupt file is
  cleaned up automatically with a one-tap **Retry**.
- **Quiet audio just works.** Far-field or low-volume recordings get an automatic, clip-safe volume
  boost — for transcription, speaker detection, and playback alike.
- **While a transcription is running,** exports and settings are briefly locked so the session can't be
  saved half-finished — they unlock the moment it completes.
- **The only thing it ever sends** is an optional, once-a-day check to GitHub for a new version — no
  tracking, and skipped when you're offline. (F-Droid users get updates through their client instead.)
- **Runs on Android 8.0+** with an ARMv8.2 processor (dot-product instructions — most phones from 2019 on). A recent phone with a few GB of free storage is comfortable. The
  first transcription downloads the speech engine's two models (~275 MB); the first summary
  downloads the meeting agent (~3.35 GB). With ~8 GB of RAM both run at once during a recording
  (about 3 GB peak); with less, the agent runs after the speech engine is released.

## Project status

**Speech engine: one streaming pass (from the next release).** Transcription and speaker
identification now run together, live: [nemo-x-asr-diarizer](https://github.com/vieenrose/nemo-x-asr-diarizer.cpp)
pairs the X-ASR transcriber with NVIDIA's Nemotron-3 diarizer on one audio timeline, so speakers
are tagged while you record instead of in a separate pass after the recording ends. It replaces
the previous pipeline (voice-activity detection + X-ASR, then a separate speaker-clustering pass),
and every setting that only applied to it is gone.

- **Verified:** on 22 ten-minute AMI and AISHELL-4 meetings, speaker attribution is unchanged
  (95.4% / 92.3%, was 95.6% / 92.1%) while 99% of the speech now gets a speaker, up from 81–89%,
  and the diarization error rate drops from 22% to 17% (AMI) and 12% (AISHELL-4).
  [Full results](tools/nemo-eval/README.md).
- **Not yet verified:** speed and memory on a phone. The numbers above come from a desktop run of
  the same engine code. On meetings it can also split off a small extra speaker; *Merge speaker into…*
  fixes that in one tap.

**Live speaker tags: accuracy vs latency.** While recording, words appear in ~0.4 s, but a speaker
tag has to wait for the diarizer to settle. We measured that trade-off end to end — every diarizer
chunk size (~1 s to 27 s) × every display delay (0–30 s), scored against the ground-truth speakers of
4 meetings, with the latency measured word by word:

<p align="center"><img src="docs/figures/latency_accuracy.png" width="820" alt="Live speaker accuracy vs latency"></p>

- **Today's live view is accurate but slow.** A line's tag appears only once the whole line (up to
  ~10 s) is frozen, so a word waits ~12–30 s for its tag even though the diarizer itself commits
  turns ~5 s behind; accuracy is 86–91 %, close to the saved transcript's 90 %.
- **Tagging a line as soon as its first word settles is fast but wrong.** Latency drops to 2–3 s, but
  words later in the line inherit the tag before the diarizer has seen them, and accuracy falls to
  60–67 %; it recovers to ~81 % at ~8 s and ~88 % at ~19 s.
- **Smaller diarizer chunks barely buy accuracy and cost a lot of compute** — on an OPPO Reno7
  (Dimensity 900, 2 threads) the ~1 s `low` profile runs at RTF 4.2 (4× slower than real time),
  against 0.61 for the shipped 4 s chunks.
- **The saved transcript is unaffected** by any of this: it is re-attributed in full when the
  recording stops.

The next step is word-level tagging — a tag on each *settled word* rather than per line — which should
bring the latency close to the diarizer's own ~5 s at today's accuracy.
Data and plotting: [`tools/nemo-eval/latency/`](tools/nemo-eval/latency).

**Summarizer: a live meeting-reading agent (from the next release).** The summary is written *while
the meeting happens*, by [Gemma-4-E2B meeting agent](https://huggingface.co/Luigi/gemma-4-E2B-meeting-agent-zh-GGUF)
(Apache-2.0, 3.35 GB), fine-tuned in [meeting-summarizer](https://github.com/vieenrose/meeting-summarizer)
as a *reader*: transcript lines are fed into one growing conversation as soon as their speaker is
settled (prefill only, while people talk), and every ~2,000 tokens (~4 min) it writes up to five
short, typed notes — decision, action, open issue, figure — each citing the line it rests on. After the
stop, the same model writes the summary as prose from those notes (only times that match a note are
kept, so every `[time]` is tap-to-play and grounded); action items are the ACTION notes. When the context
reaches 8k tokens it restarts from a compacted journal. Its protocol is a byte-exact port of
upstream's `phone_live.py` (checked by a parity test that replays the real script).

```mermaid
gantt
    title A 14-minute meeting on an OPPO Reno7 — who works when
    dateFormat mm:ss
    axisFormat %M:%S
    section Speech recognition
    words on screen ~0.4 s after they are spoken   :active, a1, 00:00, 14:00
    section Speaker identification
    turns commit ~5 s behind the audio             :active, d1, 00:05, 14:00
    speaker tags shown once settled (delay 15 s)   :d2, 00:15, 14:15
    section Meeting agent
    load model (~8 s)                               :g0, 00:00, 00:08
    prefill settled lines, 20 s segments           :active, g1, 00:15, 04:00
    reading turn → notes (window 1)                :crit, g2, 04:00, 04:45
    prefill                                        :active, g3, 04:45, 08:00
    reading turn → notes (window 2)                :crit, g4, 08:00, 08:25
    prefill                                        :active, g5, 08:25, 12:00
    reading turn → notes (window 3)                :crit, g6, 12:00, 12:30
    prefill                                        :active, g7, 12:30, 14:15
    last window + minutes, after the stop           :crit, g8, 14:15, 15:27
    section You
    stop recording                                  :milestone, m1, 14:00, 0s
    minutes ready (~1.5 min after the stop)         :milestone, m2, 15:27, 0s
```

Every lane runs at once. Speech recognition keeps priority — it is the only one that loses audio when it
falls behind — so the agent prefills in the background while people talk and only does real work (a
reading turn, 17–45 s on the phone) once every ~4 minutes of speech. It never sees a line whose speaker
could still change, and at the stop it only has the last window left to read.

Three lanes run at once while recording — speech recognition, speaker identification, and the
agent — and the recording screen shows all three: the live transcript, speaker tags as they
settle, and the agent's status, the note it is writing, and its latest notes (the full activity
log — every prefill, reading turn, dropped note and restart — is on the session screen).

- **Verified on an OPPO Reno7 (Dimensity 900, 8 GB)**, a 10-minute meeting replayed at real time
  with all three lanes: speech recognition never fell more than 6.5 s behind and lost no audio,
  reading turns took 17–45 s, the minutes were ready **87 s after the audio ended**, peak memory
  3.0 GB.
- **Quality, measured upstream** on 38 held-out zh-TW meetings: coverage 0.91, 77 % of decisions
  recalled — and **18 % of statements contradicted** by the transcript. The app labels the output
  as notes, not minutes; check a note by tapping its time.
- **Limits.** The model was trained on Chinese (Legislative Yuan) meetings and writes its notes in
  Chinese, also for English meetings. Live mode needs ~8 GB of RAM; on smaller phones the agent
  reads the transcript right after the recording instead.

## Synced lyrics in Android music players

An exported `.m4a` stores the title, cover, **summary** (in the *comment* tag) and the
**time-synced transcript** (in the *lyrics* tag, as LRC `[mm:ss.xx]` lines). Android players that parse
**synced lyrics** scroll the transcript **in real time** as it plays — read straight from the file,
**no sidecar and no permission**. (Players without sync support just show the text, with the `[mm:ss]`
timestamps visible.)

| App | Open the lyrics here | Real-time sync |
|---|---|---|
| **Retro Music** *(free)* | now-playing lyrics (歌詞) | ✅ |
| **Gramophone** *(free)* | the Lyrics view | ✅ |
| **Musicolet** *(free)* | tap the album cover → lyrics | ✅ |

<p align="center">
<img src="docs/screenshots/synced-retromusic.png" width="232" alt="Synced lyrics in Retro Music">
&nbsp;<img src="docs/screenshots/synced-gramophone.png" width="232" alt="Synced lyrics in Gramophone">
&nbsp;<img src="docs/screenshots/synced-musicolet.png" width="232" alt="Synced lyrics in Musicolet">
</p>

*Synced transcript scrolling on a Pixel — **Retro Music**, **Gramophone**, and **Musicolet** (the current line highlights as the audio plays).*

> **Notes.** All three verified on a Pixel — the current line highlights as it plays. The **summary**
> also lives in the standard **comment** tag (song info). A standalone **`.lrc` sidecar** export
> (**Export & share… → Subtitles → LRC**) is also available for players that prefer one.

## For developers

VoxSum is an on-device port of [VoxSum Studio](https://huggingface.co/spaces/Luigi/VoxSum-bak).
Every model runs locally, and everything native is built from source:

- **Speech recognition + speaker diarization, in one streaming pass** —
  [nemo-x-asr-diarizer](https://github.com/vieenrose/nemo-x-asr-diarizer.cpp): X-ASR, a streaming
  Zipformer2 transducer for Chinese + English (via [CrispASR](https://github.com/CrispStrobe/CrispASR)),
  and NVIDIA's streaming Nemotron-3 Diarization (via [audio.cpp](https://github.com/0xShug0/audio.cpp)),
  fused so every word carries the speaker whose turn covers it. Words appear ~0.4 s after they are
  spoken; speaker turns settle ~5 s behind the audio. Two GGUFs, ~275 MB together.
- **Summarization** — a live reading agent (Gemma-4-E2B, fine-tuned) on
  [llama.cpp](https://github.com/ggml-org/llama.cpp), through a session that keeps its KV cache
  between calls so the meeting is read incrementally (`core/reader/`, `llm_jni.cpp`).

All of it runs on ggml, built for `armv8.2-a+dotprod`: the int8 dot-product kernels are what make
the models run in real time. ARMv8.0 devices (Cortex-A53/A72/A73, e.g. the older Boox tablets) are
not supported; the app says so at launch instead of crashing.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the module map.

### Build from source

Requires Android Studio (Ladybug+), SDK 35, NDK 27.2:

```bash
git clone https://github.com/vieenrose/VoxSumDroid.git
cd VoxSumDroid
git submodule update --init           # NOT --recursive (see .gitmodules / CMakeLists.txt)
./gradlew :app:assembleDebug          # arm64-v8a by default
./gradlew :app:testDebugUnitTest      # JVM unit tests
scripts/test-on-device.sh             # instrumented suite on a connected device
```

`test-on-device.sh` installs under its own application id, so an installed release build — and its
sessions and models — is left untouched. Set `VOXSUM_SEED_MODELS` to a directory laid out like the
app's `files/models` to skip the on-device download.

[`RELEASING.md`](RELEASING.md) covers how tagging `v*` produces a signed release APK via CI, and
[`tools/nemo-eval`](tools/nemo-eval/README.md) the host accuracy run for the speech engine.

## License

[GPL-3.0-or-later](LICENSE). Bundled source dependencies retain their own licenses. Downloaded models
carry theirs: X-ASR (Apache-2.0), Nemotron-3 Diarization (OpenMDW-1.1), and the summarizer models
listed in `LlmRegistry.kt`.
