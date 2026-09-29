#!/usr/bin/env python3
"""Plot live speaker-tag accuracy vs latency (docs/figures/latency_accuracy.png).

Inputs (produced by nemo_eval --sweep-settle over the diarizer geometries, scored with score.py):
  results_4meetings.json  word-level latency + accuracy, both display rules, 4 meetings
  results_8meetings.json  host RTF per geometry, 8 meetings
"""
import json, os, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
rows = json.load(open(os.path.join(HERE, "results_4meetings.json")))
rtf = {r["geo"]: r["host_rtf"] for r in json.load(open(os.path.join(HERE, "results_8meetings.json")))}
OUT = os.path.join(HERE, "../../../docs/figures/latency_accuracy.png")
GEOS = ["low", "c12", "c25", "c50", "c100", "c200", "c340"]
SHORT = {"low": "low", "c12": "1 s", "c25": "2 s", "c50": "4 s", "c100": "8 s", "c200": "16 s", "c340": "27 s"}
SURF, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e0"
COL = {"linestart": "#2a78d6", "frozen": "#eb6834"}
LAB = {"linestart": "Tag shown once a line's first word is settled",
       "frozen": "Tag shown once the whole line is frozen (current app)"}

fig, ax = plt.subplots(figsize=(12, 7.2), dpi=150)
fig.patch.set_facecolor(SURF); ax.set_facecolor(SURF)
for rule in ("linestart", "frozen"):
    pts = sorted([r for r in rows if r["rule"] == rule], key=lambda r: r["latency"])
    ax.scatter([r["latency"] for r in pts], [r["attr"] for r in pts], s=20, color=COL[rule], alpha=0.3,
               edgecolors=SURF, linewidths=1, zorder=2)
    front, best = [], -1
    for r in pts:                          # best accuracy reachable at <= this latency (0.5-pt steps)
        if r["attr"] > best + 0.5:
            front.append(r); best = r["attr"]
    ax.plot([r["latency"] for r in front], [r["attr"] for r in front], color=COL[rule], lw=2, zorder=3,
            label=LAB[rule])
    ax.scatter([r["latency"] for r in front], [r["attr"] for r in front], s=64, color=COL[rule],
               edgecolors=SURF, linewidths=2, zorder=4)
    last_x = -99
    for r in front:
        if r["latency"] - last_x < 1.6: continue
        last_x = r["latency"]
        ax.annotate(f"{SHORT[r['geo']]} · {r['settle']} s", (r["latency"], r["attr"]), textcoords="offset points",
                    xytext=(5, -13 if rule == "frozen" else 7), fontsize=8, color=INK2)
fin = sum(r["final_attr"] for r in rows if r["rule"] == "frozen" and r["settle"] == 0) / len(GEOS)
ax.axhline(fin, color=INK2, lw=1, zorder=1)
ax.text(0.8, fin + 0.5, f"Saved (final) transcript: {fin:.1f} %", fontsize=8.5, color=INK2)
ax.axvspan(1, 30, color="#2a78d6", alpha=0.04, zorder=0)
ax.text(29.6, 57.6, "1–30 s range", fontsize=8, color=INK2, ha="right")
ax.set_xlim(0, 55); ax.set_ylim(57, 95)
ax.set_xlabel("Mean latency from a spoken word to its displayed speaker tag (s)", color=INK)
ax.set_ylabel("Displayed speaker tags attributed correctly (%)", color=INK)
ax.grid(color=GRID, lw=1); ax.set_axisbelow(True)
for sp in ("top", "right"): ax.spines[sp].set_visible(False)
for sp in ("left", "bottom"): ax.spines[sp].set_color(GRID)
ax.tick_params(colors=INK2)
ax.legend(loc="lower right", frameon=False, fontsize=9, labelcolor=INK)
box = "Diarizer chunk · RTF (PC / phone)\n" + "\n".join(
    f"{SHORT[g]:>5} : {rtf[g]:.2f} / —" + ("   ← current" if g == "c50" else "") for g in GEOS)
ax.text(36, 60.5, box, fontsize=8, color=INK2, family="monospace", va="bottom",
        bbox=dict(boxstyle="round,pad=0.5", fc=SURF, ec=GRID))
fig.suptitle("Live speaker accuracy vs latency — 4 meetings (2 AMI, 2 AISHELL-4)",
             x=0.055, ha="left", fontsize=13, color=INK)
ax.set_title("Point = diarizer chunk size × display delay (labelled “chunk · delay”). Line = best accuracy reachable at that\n"
             "latency. RTF on an x86 PC (2 threads, loaded machine); phone RTF not measured yet.",
             loc="left", fontsize=8.5, color=INK2)
fig.tight_layout()
fig.savefig(OUT, facecolor=SURF)
print("wrote", os.path.normpath(OUT))
