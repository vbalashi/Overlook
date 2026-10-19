#!/usr/bin/env python3
"""Live regression: split HTTP headers/body; empty /type never types remotely."""
import json,os,plistlib,socket,time
from pathlib import Path
prefs=plistlib.load(open(Path.home()/'Library/Preferences/com.overlook.app.plist','rb'))
key=os.environ.get('OVERLOOK_AGENT_KEY',prefs['overlook.agentServer.apiKey'])
port=int(prefs.get('overlook.agentServer.port',9876))
for padding in (0,100000):
 body=json.dumps({'text':'','padding':'x'*padding}).encode()
 with socket.create_connection(('127.0.0.1',port),timeout=10) as s:
  s.settimeout(10)
  header=f'POST /type HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {key}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n'.encode()
  s.sendall(header);time.sleep(.15)
  for i in range(0,len(body),1000): s.sendall(body[i:i+1000])
  response=b''
  while part:=s.recv(65536): response+=part
  assert response.startswith(b'HTTP/1.1 200 '),response.split(b'\r\n')[0]
  assert json.loads(response.split(b'\r\n\r\n',1)[1])=={'ok':True}
  print(f'PASS: complete fragmented JSON body ({len(body)} bytes)')
