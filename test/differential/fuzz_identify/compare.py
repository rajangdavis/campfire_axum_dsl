#!/usr/bin/env python3
"""compare.py RUN_DIR PORT: post each case to the idfuzz app as a multipart file and compare with Rails' expectation."""
import sys, urllib.request, urllib.parse
run, port = sys.argv[1], sys.argv[2]
same = diff = 0
for line in open(f"{run}/expected.txt"):
    i, name, dt, want_type, want_meta = line.rstrip("\n").split(" ", 4)
    dt = urllib.parse.unquote(dt)
    data = open(f"{run}/cases/{i}", "rb").read()
    b = "fuzzboundary"
    head = f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n' + (f"Content-Type: {dt}\r\n" if dt else "") + "\r\n"
    body = head.encode() + data + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/id", data=body, headers={"Content-Type": f"multipart/form-data; boundary={b}"})
    got = urllib.request.urlopen(req).read().decode()
    want = f"{want_type} {want_meta}"
    if got == want:
        same += 1
    else:
        diff += 1
        if diff <= 25:
            print(f"DIFF {i} name={name} declared={dt!r}\n  rails {want}\n  port  {got}")
print(f"same={same} diff={diff}")
