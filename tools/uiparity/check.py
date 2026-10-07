#!/usr/bin/env python3
"""Static UI parity: every user-visible string an Android UI file shows must exist (same zh-Hant text) in the iOS app.
Usage: tools/uiparity/check.py [android-ref=android]   Exit 1 if anything is missing (per-file report)."""
import re, subprocess, sys, collections
ref = sys.argv[1] if len(sys.argv) > 1 else "android"
def git(*a): return subprocess.check_output(["git", *a], text=True)
xml = git("show", f"{ref}:app/src/main/res/values-zh-rTW/strings.xml")
vals = {m[0]: re.sub(r"\\(.)", r"\1", m[1]) for m in re.findall(r'<string name="(\w+)"[^>]*>(.*?)</string>', xml, re.S)}
ios = open("ios/App/Resources/zh-Hant.lproj/Localizable.strings").read()
ios_vals = {re.sub(r"%\d*\$?[,.\d]*[dsf@]", "%", v) for v in re.findall(r'=\s*"((?:[^"\\]|\\.)*)";', ios)}
norm = lambda v: re.sub(r"%\d*\$?[,.\d]*[dsf@]", "%", v)
files = [f for f in git("ls-tree", "-r", "--name-only", ref).split() if "/ui/" in f and f.endswith(".kt") and "/test/" not in f]
total = miss = 0; rep = collections.defaultdict(list)
for f in files:
    for k in sorted(set(re.findall(r"R\.string\.(\w+)", git("show", f"{ref}:{f}")))):
        if k not in vals: continue
        total += 1
        if norm(vals[k]) not in ios_vals: miss += 1; rep[f.split("/")[-1]].append(f"{k} = {vals[k][:40]}")
for f, ks in sorted(rep.items(), key=lambda x: -len(x[1])):
    print(f"{f}: {len(ks)} missing"); [print("   ", k) for k in ks[:int(__import__("os").environ.get("N","6"))]]
print(f"parity: {total-miss}/{total} Android UI strings present on iOS ({100*(total-miss)//max(total,1)}%)")
sys.exit(1 if miss else 0)
