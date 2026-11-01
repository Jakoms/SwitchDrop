#!/usr/bin/env python3
"""Run the real helper against an in-memory libmtp responder; never opens USB."""
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    tmp = pathlib.Path(directory)
    prefix = pathlib.Path(os.environ.get('LIBMTP_PREFIX', root/'.build/deps-13.0'))
    if not (prefix/'include/libmtp.h').exists():
        prefix = pathlib.Path(subprocess.check_output(['brew','--prefix','libmtp'],text=True).strip())
    helper = tmp/'helper'
    subprocess.run(['clang','-framework','CoreFoundation','-Wall','-Wextra','-Werror','-I'+str(prefix/'include'),str(root/'Source/mtp-helper.c'),str(root/'Tests/fake-mtp.c'),'-o',str(helper)],check=True)
    p = subprocess.Popen([str(helper),'session'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,env={**os.environ,'TEST_MTP_MODE':'browser'})
    def receive():
        line=p.stdout.readline()
        assert line, 'helper unexpectedly closed the session'
        return json.loads(line)
    initial=[]
    while True:
        e=receive(); initial.append(e)
        if e['type']=='ready': break
    assert {e['id'] for e in initial if e['type']=='storage'} == {1,5,9}
    assert next(e for e in initial if e.get('id')==1)['writable']
    assert not next(e for e in initial if e.get('id')==9)['writable']
    def command(args, expected='fsdone'):
        data=b''.join(str(a).encode()+b'\0' for a in args)
        p.stdin.write(struct.pack('!I',len(data))+data); p.stdin.flush()
        result=[]
        while True:
            e=receive(); result.append(e)
            if e['type']=='uploadconflict':
                reply=b'uploadchoice\0'+e['token'].encode()+b'\0skip\0one\0'
                p.stdin.write(struct.pack('!I',len(reply))+reply);p.stdin.flush()
            if e['type'] in ('fsdone','operror','closed'):
                assert e['type']==expected,result
                return result
    ROOT=2**32-1
    def listing(parent=ROOT,storage=1):
        return [e for e in command(['list',storage,parent]) if e['type']=='entry']
    assert {e['name'] for e in listing()} == {'hello.txt','empty','full'}
    command(['mkdir',1,ROOT,'Новая папка'])
    folder=next(e for e in listing() if e['name']=='Новая папка')
    command(['rename',1,folder['id'],'renamed'])
    assert any(e['name']=='renamed' for e in listing())
    command(['mkdir',1,ROOT,'hello.txt'],'operror')
    command(['mkdir',1,ROOT,'../escape'],'operror')
    command(['mkdir',9,ROOT,'blocked'],'operror')
    command(['delete',1,105],'operror')  # wrong storage for the object
    command(['delete',9,105],'operror') # read-only policy
    command(['delete',1,103],'operror') # recursive deletion forbidden
    command(['delete',1,102])
    assert not any(e['id']==102 for e in listing())
    source=tmp/'payload.bin'; source.write_bytes(bytes(range(256))*16)
    command(['upload',1,folder['id'],source])
    item=next(e for e in listing(folder['id']) if e['name']=='payload.bin')
    assert item['size']==4096
    destination=tmp/'download.bin'
    command(['download',1,item['id'],destination])
    assert hashlib.sha256(source.read_bytes()).digest()==hashlib.sha256(destination.read_bytes()).digest()
    command(['download',1,item['id'],destination],'operror')
    assert destination.read_bytes()==source.read_bytes()
    duplicate=command(['upload',1,folder['id'],source])
    assert next(e for e in duplicate if e['type']=='uploadsummary')['skipped']==1
    link=tmp/'link'; link.symlink_to(source)
    command(['upload',1,folder['id'],link],'operror')
    tree=tmp/'tree'; (tree/'nested').mkdir(parents=True); (tree/'nested'/'tiny.txt').write_text('hello')
    command(['upload',1,ROOT,tree])
    remote_tree=next(e for e in listing() if e['name']=='tree')
    nested=next(e for e in listing(remote_tree['id']) if e['name']=='nested')
    assert next(e for e in listing(nested['id']) if e['name']=='tiny.txt')['size']==5
    command(['list',5,ROOT],'operror') # installer volume isn't a file browser
    command(['quit'],expected='closed'); assert p.wait(timeout=5)==0
print('Browser tests passed: list, folder navigation, mkdir, rename, safe delete, upload tree, no-overwrite download SHA-256, read-only/cross-storage guards, collision and symlink rejection.')
