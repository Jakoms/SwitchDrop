#!/usr/bin/env python3
"""Fake helper for native connection lifecycle tests. Never opens USB."""
import json, os, signal, struct, sys, time
from pathlib import Path
root=Path(os.environ['SWITCHDROP_TEST_ROOT'])
def config(): return json.loads((root/'device.json').read_text())
def trace(event):
    with (root/'trace.jsonl').open('a') as f:f.write(json.dumps({'event':event,'pid':os.getpid()})+'\n')
def emit(event): print(json.dumps(event),flush=True)
def terminate(signum,frame):
    time.sleep(.1);emit({'type':'error','message':'STALE-EVENT'});trace('terminated');sys.exit(0)
signal.signal(signal.SIGTERM,terminate)
trace('launch');d=config()['device']
emit({'type':'device','bus':d['bus'],'dev':d['address'],'product':d['product'],'storage':5,'serial':'fixture','label':'5: SD Card install','free':1000,'capacity':2000})
emit({'type':'storage','id':1,'label':'1: SD Card','writable':True,'install':False,'free':1000})
emit({'type':'ready','message':'ready'})
def exact(n):
    data=b''
    while len(data)<n:
        chunk=sys.stdin.buffer.read(n-len(data))
        if not chunk:return None
        data+=chunk
    return data
while True:
    header=exact(4)
    if header is None:break
    data=exact(struct.unpack('!I',header)[0])
    if data is None:break
    args=data[:-1].decode().split('\0');trace(args[0])
    if args[0]=='quit':emit({'type':'closed','message':'closed'});break
    if args[0]=='ping':
        if not config().get('hangPing'):emit({'type':'pong'})
    elif args[0]=='send':emit({'type':'start','index':0,'size':3})
    else:emit({'type':'fsdone'})
