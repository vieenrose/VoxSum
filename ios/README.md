# VoxSum iOS — native engine feasibility (2026-10-05)

Built on a MacBook Pro 16,3 (Intel, macOS 15.7, Xcode 26.2, iOS 26.2 SDK) with `ios/native/build_ios.sh`
(cmake 3.31.6 installed in `~/tools`; Homebrew is not writable there).

| Piece | Result |
|---|---|
| CrispASR x-asr + pinned ggml fork (static) | builds: simulator x86_64 and device arm64 |
| audio.cpp diarization (`libaudiocpp.dylib`, ggml hidden, 75 exported symbols, 0 `ggml_*`) | builds: simulator x86_64 and device arm64 |
| `nemo/` glue (engine, fusion, diar_crispasr) | compiles for iOS arm64 (syntax check) |
| `mfa/` LiteRT-LM fork (mfa_engine.cc, i8_attn.cc) | compiles for iOS arm64 (syntax check) |
| LiteRT runtime | `CLiteRTLM.xcframework` v0.17.1 exports the full LiteRT C API incl. `LiteRtAddCustomOpKernelOption` → the fused-attention custom op can link against it |

Changes needed vs Android: deployment target 17.0 (`std::to_chars`), `ru_minflt` (profiling only) patched out of
audio.cpp, a no-op `set_xcode_property` for sentencepiece, OpenMP off (CrispASR kernels run single-threaded
until an iOS libomp is wired in), Metal/Accelerate/BLAS off.

Known limits: CLiteRTLM ships arm64 device + arm64 simulator slices only — no x86_64 — so this Intel Mac can
build but not run the reader in the simulator; running needs a real iPhone (no signing identity configured yet).
Not done yet: JNI → C/Swift bridge for nemo and mfa, linking `libvoxsum-nemo`, Xcode/SwiftUI project.

## CLI check on the iOS simulator (`build_nemo_eval.sh`)

`nemo_eval` (the app's engine, driven from the command line) built for iphonesimulator x86_64 and run with
`xcrun simctl spawn` on an iPhone 17 Pro simulator, on `diar_ref_2spk_123s.wav` (123 s, 2 speakers), against the
Linux host build of the same sources:

| | Linux host (4 threads) | iOS simulator (x86_64, no OpenMP) |
|---|---|---|
| speakers / diarizer turns | 2 / 57 | 2 / 57 |
| transcript text | — | identical (similarity 1.0000) |
| speaker label per second | — | 108/119 agree (91 %); the host agrees with itself at 119/119 across 1 and 4 threads |
| wall / RTF | 47 s / 0.38 | 208 s / 1.69 (1.4 GHz Intel i5, single-threaded — not representative of an iPhone) |

The label differences start where speech overlaps (~48 s) and are ±10–20 ms on most turn edges. Likely cause: the
iOS build uses baseline x86 SIMD kernels (`GGML_NATIVE=OFF`) where the host build uses AVX2, i.e. float-rounding
differences in the diarizer — not verified. `engine.cpp` needs `apple_sched_shim.h` (Linux CPU affinity).

## État (reader + app)

- Le lecteur de réunion (protocole, `MeetingReader`, `ReaderSummarizer`) est porté en Swift, identique octet par octet aux goldens Android (`tests/run.sh`).
- `native/mfa/` : moteur LiteRT (CPU) + SentencePiece compilés pour iOS arm64 (`native/build_mfa_lib.sh`). Lien/ABI avec `CLiteRTLM.xcframework` à valider sur un iPhone.
- Simulateur Intel : x86_64 uniquement, donc `StubLlm` (notes simulées) ; `MfaSession` n'est compilé que pour l'appareil.
- Prochain pas sur iPhone : signature (Apple ID), `build_app.sh iphoneos arm64` (lien mfa + sentencepiece + CLiteRTLM, à intégrer au bundle), téléchargement des modèles du lecteur, mesure de vitesse ASR (ggml sans OpenMP = mono-thread).

## Vrai lecteur dans le simulateur Intel

`native/litert_x86_sim/` compile `libLiteRt.so` v2.1.6 pour `ios_x86_64` (Bazel, ~25 min, patch de 3 lignes de lien).
`build_app.sh` la lie dès qu'elle existe (`-DVOX_REAL_READER`) ; `VOX_READER_DIR=<dossier des modèles>` choisit le lecteur réel.
Vérifié : E2B charge, notes/titre/résumé réels sur l'extrait de 123 s (ASR rtf 0,73 dans le simulateur).

## Projet Xcode (signature sur iPhone)

`Xcode/VoxSum.xcodeproj` est une cible app minimale : sa phase « Build + embed native bundle »
(`Xcode/embed_prebuilt.sh`) lance `native/build_app.sh`, copie le binaire et `Frameworks/` dans le
produit, signe les frameworks, puis Xcode signe l'app (signature automatique).

1. iPhone branché, « Faire confiance », Réglages > Confidentialité et sécurité > Mode développeur.
2. Xcode > Settings > Accounts : ajouter l'identifiant Apple.
3. Ouvrir `~/work/vox/ios/Xcode/VoxSum.xcodeproj`, cible VoxSum > Signing & Capabilities : choisir la Team
   (changer le bundle id `studio.voxsum.ios` s'il est pris), choisir l'iPhone, Run.

Sans Xcode GUI : `xcodebuild -project Xcode/VoxSum.xcodeproj -target VoxSum -sdk iphoneos -allowProvisioningUpdates DEVELOPMENT_TEAM=<ID> build`.
`SKIP_NATIVE_BUILD=1` réutilise le bundle déjà compilé. Structure validée sans signature
(`CODE_SIGNING_ALLOWED=NO`) ; la signature elle-même n'est pas testée.

## État validé sur iPhone (2026-10-07)

Appareil de référence : iPhone 14 Pro Max (6 Go, iOS 27). L'iPhone XR (3 Go, A12) ne tient pas E2B de façon fiable
(app perdue à la transition ASR → lecteur) ; il n'est plus utilisé pour valider.

- `long.mp3` (45 min) : transcription en ~15 min (RTF ≈ 0,3), lecteur E2B en parallèle, résumé confirmé correct.
- Enregistrement micro : sessions de 30 s et 62 s terminées.
- Mode séquentiel automatique sous 4,5 Go de RAM (lecteur en pause pendant l'ASR).
- Point de reprise de la transcription (`Library/Application Support/checkpoints/`) : un kill pendant l'étape lecteur ne refait pas l'ASR.
- Tâche d'arrière-plan `BGProcessingTask` (`tw.com.pesi.voxsum.queue`) : reprend la file de jobs quand l'app est quittée.
- Réglages : délai des locuteurs en direct (5–30 s, défaut 15) et taille du texte.
- Pré-traitement audio : normalisation du gain, saut des silences, découpe des longues interventions.
- Non testé sur appareil : gain/silences, découpe, réglages, tâche d'arrière-plan, reprise depuis le point de reprise.

## Construire et tester sur appareil

- `DEV=1 bash native/build_app.sh iphoneos arm64` active `-DVOX_DEV` : variables `VOX_*` (`VOX_IMPORT`, `VOX_DOWNLOAD`,
  `VOX_OPEN`, `VOX_PODCAST`, `VOX_READER_DIR`, `VOX_AUTORUN`) et bouton Sample. Les builds sans `DEV` n'en contiennent aucune.
- Puis `xcodebuild … SKIP_NATIVE_BUILD=1 clean build` (sinon la phase de script Xcode recompile sans `DEV=1`).
- Les modèles se téléchargent dans l'app (`VOX_DOWNLOAD=reader` pour le lecteur ; ASR au premier job).
- Journal : `Documents/status.log` (`devicectl device copy from --domain-type appDataContainer`).
