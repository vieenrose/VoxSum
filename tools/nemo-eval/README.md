# nemo-eval — host accuracy runs for the ASR + diarization engine

`nemo_eval` drives the exact engine the app ships (`app/src/main/cpp/nemo`) the way the app does:
a 16 kHz WAV pushed in 2048-sample blocks through `Engine::push`, then `finish()`. It writes the
transcript segments (`<out>.json`, `[{spk,start,end,text}]`) and the diarizer's own speech turns
(`<out>.turns.json`).

```bash
git submodule update --init
tools/nemo-eval/build_host.sh                       # -> tools/nemo-eval/build/nemo_eval
# models: the two GGUFs pinned in ModelManager.kt (NEMO_FILES)
tools/nemo-eval/build/nemo_eval x-asr-zh-en-q8_0.gguf nemotron-3-diarization-q8_0.gguf in.wav out.json 4
# as the app records: 10 s line splits + the live view every 0.5 s of audio
tools/nemo-eval/build/nemo_eval ... in.wav out.json 4 --max-seg 10 --live
```

`--live` prints the live view's per-call cost (and whether it grows over the recording), checks that
frozen segments + tail always reproduce the transcript, and reports how much of the live (frozen)
speaker labelling the final pass agrees with.

## Meeting diarization (2026-09-29)

22 ten-minute excerpts (source minutes 2:00–12:00): 16 AMI meetings (EN2002a–d, ES2004a–d, IS1009a–d,
TS3003a–d) and 6 AISHELL-4 meetings, scored with the same `score.py` (time-weighted, 0.25 s collar)
that produced the previous engine's published figures. "Previous" is the LiteRT pipeline this engine
replaced (Silero VAD + X-ASR, then pyannote segmentation + CAM++ + spectral clustering over the WAV).

| | previous | nemo (transcript) | nemo (diarizer turns) |
|---|---:|---:|---:|
| AMI attribution | 95.6 % | 95.4 % | 91.6 % |
| AMI speech covered | 88.8 % | 99.0 % | 98.2 % |
| AMI DER | 22.0 % | 25.7 %* | **17.4 %** |
| AMI speaker count exact | 11/16 | **13/16** | 11/16 |
| AISHELL-4 attribution | 92.1 % | 92.3 % | 90.0 % |
| AISHELL-4 speech covered | 81.4 % | 99.9 % | 99.9 % |
| AISHELL-4 DER | 22.7 % | 10.3 % | **11.5 %** |
| AISHELL-4 speaker count exact | 4/6 | 4/6 | 4/6 |

\* Transcript segments run across the pauses between words, so they count silence as speech;
DER is meaningful on the turns column. Attribution is scored only where the hypothesis has a label,
so read it together with coverage: the new engine labels ~10–18 points more of the speech at the
same attribution.

Host RTF (x86, 4 threads, 5 runs in parallel) was 0.27–0.69; peak RSS 530 MB for a 10-minute clip.
Phone figures are in the upstream repo (RTF 0.60 on 2 A78 cores with dotprod); this app builds
for the ARMv8.0 floor, so expect slower on dotprod-capable phones — measure on-device before quoting.

## Speaker count on labelled clips (`~/voxsum-testdata`, truth confirmed by ear)

| clip | truth | previous (segmentation-first, the shipped default) | nemo |
|---|---:|---:|---:|
| mono_1spk_146s | 1 | 1 | 1 |
| diar_ref_2spk_123s | 2 | 1 ✗ | 2 |
| interview_2spk_634s | 2 | 2 | 2 |
| podcast_3spk_300s | 3 | 2 ✗ | 3 |
| meeting_2spk_0-10min | 2 | 2 | 3 ✗ (extra speaker holds 7.8 % of speech) |
| meeting_3spk_10-20min | 3 | 3 | 5 ✗ (extras hold 2.2 % and 0.5 %) |

4/6 either way, but the failure mode flips: the old pipeline merged speakers on podcasts, while this
one over-splits meetings into small extra speakers, which *Merge speaker into…* in the app fixes. A
minimum-share filter would likely recover both; it has not been tried.
