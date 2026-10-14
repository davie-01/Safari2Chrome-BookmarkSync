#!/usr/bin/env python3
"""Dev helper: send one request to the BookmarkSync agent. Usage: agentctl.py TYPE [JSON_PARAMS]"""
import json, os, socket, sys
p = os.path.expanduser('~/Library/Application Support/BookmarkSync/agent.sock')
s = socket.socket(socket.AF_UNIX); s.connect(p); s.settimeout(300)
params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
s.sendall((json.dumps({'id': 1, 'type': sys.argv[1], 'params': params}) + '\n').encode())
buf = b''
while True:
    chunk = s.recv(1 << 20)
    if not chunk: break
    buf += chunk
    while b'\n' in buf:
        line, buf = buf.split(b'\n', 1)
        m = json.loads(line)
        if m.get('id') == 1:
            print(json.dumps(m, ensure_ascii=False)); sys.exit(0 if m.get('ok') else 1)
