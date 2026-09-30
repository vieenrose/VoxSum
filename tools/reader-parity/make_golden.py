#!/usr/bin/env python3
"""Golden fixture for the Kotlin meeting reader: run upstream's REAL eval/phone_live.py against an
in-process fake llama-server, and record the exact conversation at every reading turn.

The fake tokenizer is one token per Unicode codepoint (so token counts are string lengths and the
conversation is readable text); the fake model answers each reading turn with a deterministic reply
built from the window it was shown - valid notes, an invented citation, a near-duplicate, more than
six notes, a reply cut off before NEXT - so every guard fires. The Kotlin test
(app/src/test/.../ReaderParityTest.kt) replays the same replies through MeetingReader with the same
tokenizer and must reproduce every conversation byte for byte.

    tools/reader-parity/make_golden.py <meeting-summarizer checkout> <out.json> <nemo.json>...
"""
import json, os, re, sys, types

MS, OUT, INPUTS = sys.argv[1], sys.argv[2], sys.argv[3:]

# --- the transcript: nemo segments split into sentence lines, meetings back to back, one hour apart
lines = []
for m, path in enumerate(INPUTS):
    for seg in json.load(open(path, encoding="utf-8")):
        parts = [p for p in re.split(r"(?<=[。？！?!])", seg["text"]) if p.strip()]
        total = sum(len(p) for p in parts) or 1
        t, acc = seg["start"], 0
        for p in parts:
            start = int(m * 3600 + seg["start"] + (seg["end"] - seg["start"]) * acc / total)
            acc += len(p)
            spk = f"S{seg['spk'] + 1}" if seg["spk"] >= 0 else None
            lines.append((start, spk, p.strip()))

# --- stubs: transformers (window sizing), asr_streaming (ingest import), requests (the server)
tf = types.ModuleType("transformers")
class _Tok:
    def encode(self, t, add_special_tokens=False): return list(t)
tf.AutoTokenizer = types.SimpleNamespace(from_pretrained=lambda *_a, **_k: _Tok())
sys.modules["transformers"] = tf
asr = types.ModuleType("asr_streaming")
asr.ChunkGeometry = lambda **k: None
asr.chunk_segments = lambda *a, **k: []
sys.modules["asr_streaming"] = asr

MARKS = ["⁣S⁣", "⁣U1⁣", "⁣A1⁣", "⁣U2⁣"]
P0, P1, P2, P3 = "<bos><|turn>system\n", "<turn|>\n<|turn>user\n", "<turn|>\n<|turn>model\n", "<turn|>\n<|turn>user\n"
turns = []

def decode(tokens): return "".join(chr(t) for t in tokens)

def reply_for(prompt_text, k):
    body = prompt_text[prompt_text.rindex("## 逐字稿片段"):]
    ts = re.findall(r"^\[(\d+:\d{2}(?::\d{2})?)\]", body, re.M)
    first, last = ts[0], ts[-1]
    notes = [f"NOTE [{first}] (DECISION) 第{k}段決議：通過第{k}案",
             f"NOTE [{last}] (ACTION) 第{k}段待辦：物業於下週回報",
             "NOTE [9:59:59] (NUMBER) 捏造的時間不應被採用",
             f"NOTE [{first}] (DECISION) 第{k}段決議：通過第{k}案。",          # near-duplicate
             f"NOTE {last} (OPEN-ISSUE) 第{k}段保留：停車費率未定",              # brackets optional
             "NOTE 這行格式錯誤",
             f"NOTE [{last}] (DECISION) 建議第{k}區增設停車位",                 # v5 guard: -> PROPOSAL
             f"NOTE [{first}] (PROPOSAL) 第{k}段提議改用線上報名",
             f"NOTE [{last}] (ACTION) 同意照辦：第{k}段建議案通過後執行"]      # decided word: stays ACTION
    if k % 3 == 0:
        notes += [f"NOTE [{first}] (NUMBER) 第{k}段數字{i}：{i * 100} 萬元" for i in range(1, 7)]  # cap
    text = "\n".join(notes)
    return text, k % 4 != 2          # every 4th-plus-2 reply is cut off before NEXT

def post(url, json=None, timeout=None):
    path = url.split("://", 1)[1].split("/", 1)[1]
    body = json
    if path == "apply-template":
        m = body["messages"]
        out = P0 + m[0]["content"] + P1 + m[1]["content"] + P2 + m[2]["content"] + P3 + m[3]["content"] + P2
    elif path == "tokenize":
        out = {"tokens": [ord(c) for c in body["content"]]}
    elif path == "completion":
        prompt = decode(body["prompt"])
        timings = {"prompt_n": len(body["prompt"]), "prompt_ms": 1.0, "predicted_n": 0, "predicted_ms": 1.0}
        if body["n_predict"] == 0:
            out = {"timings": timings, "content": ""}
        else:
            k = len(turns) + 1
            content, stopped = reply_for(prompt, k)
            turns.append({"prompt": prompt, "content": content, "stopped": stopped})
            out = {"timings": timings, "content": content, "stop_type": "word" if stopped else "limit"}
    else:
        raise ValueError(path)
    return types.SimpleNamespace(json=lambda: out if path != "apply-template" else {"prompt": out},
                                 raise_for_status=lambda: None)

req = types.ModuleType("requests")
req.post = post
sys.modules["requests"] = req

# --- run the real phone_live.py on this transcript, at a speed that makes the replay instant
tmp = os.path.join(os.path.dirname(os.path.abspath(OUT)), "_parity_tmp")
os.makedirs(os.path.join(tmp, "tx"), exist_ok=True)
sys.path.insert(0, MS)
from summarizer.ingest import Line  # noqa: E402
with open(os.path.join(tmp, "tx", "golden.txt"), "w", encoding="utf-8") as f:
    for s, spk, text in lines:
        f.write(Line(s, spk, text).render() + "\n")
import eval.phone_live as pl  # noqa: E402
pl.time.sleep = lambda *_: None
sys.argv = ["phone_live.py", "--session", "golden", "--transcripts", os.path.join(tmp, "tx"),
            "--speed", "1e9", "--ctx", "8192", "--out", os.path.join(tmp, "out")]
pl.main()
rec = json.load(open(os.path.join(tmp, "out", "golden.json"), encoding="utf-8"))

# --- v5 minutes, assembled exactly as upstream realtime_agent does for --harness v5: the proposal
# guard (reclassify_proposals) on every kept note, then the five sections in order.
import eval.realtime_agent as ra  # noqa: E402
kept = [dict(n) for n in rec["notes"]]
for e in kept:
    ra.reclassify_proposals(e)
sections = {"決議事項": ["DECISION"], "待辦與負責人": ["ACTION"], "保留與未決": ["OPEN-ISSUE"],
            "討論要點": ["PROPOSAL"], "重要數字": ["NUMBER"]}
out = []
for title, tags in sections.items():
    items = [e for e in kept if (e["tag"] or "").upper() in tags]
    out += [f"【{title}】"] + ([f"- {e['text'].rstrip('。')} [{e['ts']}]" for e in items] or ["- 無"])
minutes_v5 = "\n".join(out)
json.dump({
    "system_prompt": pl.SYSTEM_V3,
    "lines": [{"start": s, "speaker": spk, "text": t} for s, spk, t in lines],
    "turns": turns,
    "notes": rec["notes"],
    "minutes": rec["minutes"],        # phone_live.py's own (v3) assembly
    "minutes_v5": minutes_v5,
    "restarts": rec["restarts"],
}, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"{len(lines)} lines, {len(turns)} turns, {len(rec['notes'])} notes, {rec['restarts']} restarts -> {OUT}")
