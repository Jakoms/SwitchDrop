#!/usr/bin/env python3
"""Merge and conflict regression tests; the responder is in-memory, no USB."""
import json,os,pathlib,struct,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    tmp=pathlib.Path(directory)
    prefix=pathlib.Path(os.environ.get('LIBMTP_PREFIX',root/'.build/deps-13.0'))
    if not (prefix/'include/libmtp.h').exists():prefix=pathlib.Path(subprocess.check_output(['brew','--prefix','libmtp'],text=True).strip())
    helper=tmp/'helper'
    subprocess.run(['clang','-Wall','-Wextra','-Werror','-framework','CoreFoundation','-I'+str(prefix/'include'),str(root/'Source/mtp-helper.c'),str(root/'Tests/fake-mtp.c'),'-o',str(helper)],check=True)
    number=0
    def session(**settings):
        global number
        number+=1;trace=tmp/f'trace{number}'
        p=subprocess.Popen([str(helper),'session'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,env={**os.environ,'TEST_MTP_MODE':'browser','TEST_MTP_TRACE':str(trace),**settings})
        while json.loads(p.stdout.readline())['type']!='ready':pass
        def send(args):
            data=b''.join(str(a).encode()+b'\0' for a in args);p.stdin.write(struct.pack('!I',len(data))+data);p.stdin.flush()
        def command(args,choice='skip',all_files=False,expected='fsdone'):
            send(args);events=[]
            while True:
                e=json.loads(p.stdout.readline());events.append(e)
                if e['type']=='uploadconflict':
                    action=choice(e) if callable(choice) else choice
                    send(['uploadchoice',e['token'],action,'all' if all_files else 'one'])
                if e['type'] in ['fsdone','operror','closed','cancelled']:
                    assert e['type']==expected,events
                    return events
        return p,command,trace
    ROOT=2**32-1
    def entries(c,parent=ROOT):return [e for e in c(['list',1,parent]) if e['type']=='entry']
    def child(c,name,parent=ROOT):return next(e for e in entries(c,parent) if e['name']==name)
    download_number=0
    def content(c,item):
        global download_number
        download_number+=1;dest=tmp/f'download{download_number}'
        c(['download',1,item['id'],dest]);return dest.read_bytes()
    def summary(events):return next(e for e in events if e['type']=='uploadsummary')
    def write(path,data):path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data);return path
    p,c,trace=session()
    old=tmp/'old'/'same';new=tmp/'new'/'same'
    write(old/'keep.txt',b'remote only');write(old/'nested'/'remote-only.txt',b'keep nested');write(old/'nested'/'dupe.bin',b'OLD')
    c(['upload',1,ROOT,old]);folder=child(c,'same');nested=child(c,'nested',folder['id'])
    write(new/'new.txt',b'new root');write(new/'nested'/'local-only.txt',b'new nested');write(new/'nested'/'dupe.bin',b'NEW CONTENT')
    events=c(['upload',1,ROOT,new]);s=summary(events)
    assert (s['copied'],s['merged'],s['skipped'])==(2,2,1),s
    assert child(c,'same')['id']==folder['id'] and child(c,'nested',folder['id'])['id']==nested['id']
    assert content(c,child(c,'keep.txt',folder['id']))==b'remote only'
    assert content(c,child(c,'remote-only.txt',nested['id']))==b'keep nested'
    assert content(c,child(c,'dupe.bin',nested['id']))==b'OLD'
    assert content(c,child(c,'local-only.txt',nested['id']))==b'new nested'
    events=c(['upload',1,ROOT,new],choice='replace',all_files=True);s=summary(events)
    assert s['replaced']==3 and sum(e['type']=='uploadconflict' for e in events)==1
    assert content(c,child(c,'dupe.bin',nested['id']))==b'NEW CONTENT'
    assert not any(e['name'].startswith('.switchdrop-') for parent in [folder['id'],nested['id']] for e in entries(c,parent))
    for suffix in [2,3]:
        events=c(['upload',1,folder['id'],new/'new.txt'],choice='keep');assert summary(events)['kept']==1
        assert content(c,child(c,f'new ({suffix}).txt',folder['id']))==b'new root'
    events=c(['upload',1,nested['id'],new/'nested'/'dupe.bin']);assert sum(e['type']=='uploadconflict' for e in events)==1 # apply-all never leaks to another upload
    conflict_file=write(tmp/'type-file'/'nested',b'type conflict')
    events=c(['upload',1,folder['id'],conflict_file],choice='keep')
    assert next(e for e in events if e['type']=='uploadconflict')['destinationFolder']
    assert not child(c,'nested (2)',folder['id'])['folder'] and child(c,'nested',folder['id'])['folder']
    c(['upload',1,folder['id'],conflict_file],choice='replace',expected='operror')
    assert child(c,'nested',folder['id'])['folder']
    conflict_dir=tmp/'type-dir'/'keep.txt';write(conflict_dir/'inside.txt',b'directory copy')
    c(['upload',1,folder['id'],conflict_dir],choice='keep')
    kept=child(c,'keep.txt (2)',folder['id']);assert kept['folder'] and content(c,child(c,'inside.txt',kept['id']))==b'directory copy'
    caps=tmp/'caps'/'SAME';write(caps/'case.txt',b'case merged');c(['upload',1,ROOT,caps])
    assert len([e for e in entries(c) if e['name'].lower()=='same'])==1
    assert content(c,child(c,'case.txt',folder['id']))==b'case merged'
    for first,second in [('Игры','игры'),('Cafe\u0301','Café')]:
        one=tmp/'unicode1'/first;two=tmp/'unicode2'/second;write(one/'one.txt',b'one');write(two/'two.txt',b'two')
        c(['upload',1,ROOT,one]);remote=child(c,first)
        s=summary(c(['upload',1,ROOT,two]));assert s['merged']==1 and {e['name'] for e in entries(c,remote['id'])}=={'one.txt','two.txt'}
    c(['quit'],expected='closed');assert p.wait(timeout=5)==0
    old_file=write(tmp/'fail-old'/'same.txt',b'ORIGINAL');new_file=write(tmp/'fail-new'/'same.txt',b'REPLACEMENT')
    cases=[{'TEST_MTP_FAIL_STAGE':'1'},{'TEST_MTP_FAIL_STAGE_AFTER_CREATE':'1'},{'TEST_MTP_FAIL_COMMIT_RENAME':'1'},{'TEST_MTP_FAIL_COMMIT_RENAME':'1','TEST_MTP_FAIL_RESTORE':'1'},{'TEST_MTP_DELETE_FAIL_ID':'110'}]
    for settings in cases:
        p,c,trace=session(**settings);c(['upload',1,ROOT,old_file]);c(['upload',1,ROOT,new_file],choice='replace',expected='operror')
        items=entries(c)
        if settings.get('TEST_MTP_FAIL_RESTORE'):
            backup=next(e for e in items if e['name'].startswith('.switchdrop-backup-'));stage=next(e for e in items if e['name'].startswith('.switchdrop-upload-'))
            assert content(c,backup)==b'ORIGINAL' and content(c,stage)==b'REPLACEMENT'
        elif settings.get('TEST_MTP_DELETE_FAIL_ID'):
            assert content(c,child(c,'same.txt'))==b'REPLACEMENT'
            assert content(c,next(e for e in items if e['name'].startswith('.switchdrop-backup-')))==b'ORIGINAL'
        else:assert content(c,child(c,'same.txt'))==b'ORIGINAL'
        c(['quit'],expected='closed');p.wait(timeout=5)
    p,c,trace=session();c(['upload',1,ROOT,old_file]);c(['upload',1,ROOT,new_file],choice='stop',expected='cancelled');assert p.wait(timeout=5)==3
    assert 'rename' not in trace.read_text() and 'delete:' not in trace.read_text()
print('Merge tests passed: recursive union, destination-only preservation, skip/replace/keep-both, per-upload apply-all, type conflicts, Unicode/case equivalence, safe staging and rollback failures, stop without replacement.')
