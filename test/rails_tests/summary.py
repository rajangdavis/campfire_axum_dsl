#!/usr/bin/env python3
"""summary.py TESTS_LOG: one line per failing test (its first message line), then the counts."""
import re, sys
text = open(sys.argv[1]).read()
blocks = re.split(r"\n(?=(?:Failure|Error):\n)", text)
for b in blocks[1:]:
    lines = b.split("\n")
    kind, name = lines[0].rstrip(":"), lines[1].rstrip(":")
    msg = next((l for l in lines[2:] if l.strip() and not l.startswith("    ")), "").strip()
    print(f"{kind[0]} {name} | {msg[:170]}")
m = re.search(r"\d+ runs, .*", text)
print(m.group(0) if m else "no summary")
