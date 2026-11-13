import json
c=[json.loads(l) for l in open('cases.jsonl')]; r=[json.loads(l) for l in open('rails.out')]; u=[json.loads(l) for l in open('rust.out')]
bad=[(a,b,x) for a,b,x in zip(c,r,u) if b!=x]
print(f"{len(c)-len(bad)}/{len(c)} match")
for a,b,x in bad[:8]: print(repr(a)); print("  rails", repr(b)); print("  rust ", repr(x))
