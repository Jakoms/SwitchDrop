#!/usr/bin/env python3
"""Exercise preview/confirmation/commit without touching USB or user files."""
import json, os, pathlib, struct, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    tmp=pathlib.Path(directory)
    prefix=pathlib.Path(os.environ.get('LIBMTP_PREFIX',root/'.build/deps-13.0'))
    if not (prefix/'include/libmtp.h').exists():
        prefix=pathlib.Path(subprocess.check_output(['brew','--prefix','libmtp'],text=True).strip())
    helper=tmp/'helper'
    subprocess.run(['clang','-framework','CoreFoundation','-Wall','-Wextra','-Werror','-I'+str(prefix/'include'),str(root/'Source/mtp-helper.c'),str(root/'Tests/fake-mtp.c'),'-o',str(helper)],check=True)
    def session(**settings):
        trace=tmp/('trace-'+str(len(list(tmp.iterdir()))))
        p=subprocess.Popen([str(helper),'session'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,env={**os.environ,'TEST_MTP_MODE':'browser','TEST_MTP_TRACE':str(trace),**settings})
        while json.loads(p.stdout.readline())['type']!='ready':pass
        def command(args,expected='fsdone'):
            data=b''.join(str(a).encode()+b'\0' for a in args)
            p.stdin.write(struct.pack('!I',len(data))+data);p.stdin.flush();events=[]
            while True:
                event=json.loads(p.stdout.readline());events.append(event)
                if event['type'] in ['fsdone','operror','closed']:
                    assert event['type']==expected,events
                    return events
        def deleted():return [line for line in trace.read_text().splitlines() if line.startswith('delete:')]
        return p,command,deleted
    def preview(command,sid=1,root=103):
        return next(e for e in command(['deleteplan',sid,root]) if e['type']=='deletepreview')
    p,c,deleted=session()
    plan=preview(c);assert plan['files']==1 and plan['folders']==1 and not deleted()
    c(['deletecommit',1,103,'wrong-token'],'operror');assert not deleted()
    c(['deletecancel',1,103,plan['token']]);assert not deleted()
    c(['deletecommit',1,103,plan['token']],'operror');assert not deleted()
    plan=preview(c)
    events=c(['deletecommit',1,103,plan['token']]);assert deleted()==['delete:104','delete:103']
    assert [e['done'] for e in events if e['type']=='deleteprogress']==[1,2]
    c(['deleteplan',9,105],'operror');c(['deleteplan',1,105],'operror')
    c(['deleteplan',1,1],'operror');c(['deleteplan',1,2**32-1],'operror')
    c(['quit'],'closed');assert p.wait(timeout=5)==0
    p,c,deleted=session(TEST_MTP_CHANGE_TREE='1')
    plan=preview(c);events=c(['deletecommit',1,103,plan['token']],'operror')
    assert 'contents changed' in events[-1]['message'] and not deleted()
    c(['quit'],'closed');p.wait(timeout=5)
    for setting in ['TEST_MTP_BAD_TREE','TEST_MTP_BAD_STORAGE']:
        p,c,deleted=session(**{setting:'1'})
        c(['deleteplan',1,103],'operror');assert not deleted()
        c(['quit'],'closed');p.wait(timeout=5)
    p,c,deleted=session(TEST_MTP_DELETE_FAIL_ID='103')
    plan=preview(c);events=c(['deletecommit',1,103,plan['token']],'operror')
    assert deleted()==['delete:104'] and 'already have been deleted' in events[-1]['message']
    c(['quit'],'closed');p.wait(timeout=5)
    p,c,deleted=session()
    plan=preview(c);c(['list',1,2**32-1]);c(['deletecommit',1,103,plan['token']],'operror');assert not deleted()
    c(['quit'],'closed');p.wait(timeout=5)
print('Deletion tests passed: preview does not write, explicit token required, cancel preserves data, leaf-first recursion, revalidation, root/read-only/cross-storage guards, cycle rejection, partial failure.')
