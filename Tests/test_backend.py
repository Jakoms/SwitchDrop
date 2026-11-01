#!/usr/bin/env python3
import json, os, pathlib, signal, subprocess, tempfile, struct
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    tmp = pathlib.Path(directory)
    mtp = os.environ.get('LIBMTP_PREFIX', str(root/'.build/deps-13.0'))
    if not pathlib.Path(mtp,'include/libmtp.h').exists():
        mtp = subprocess.check_output(['brew', '--prefix', 'libmtp'], text=True).strip()
    helper = tmp / 'helper'
    subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', '-I'+mtp+'/include', str(root/'Source/mtp-helper.c'), str(root/'Tests/fake-mtp.c'), '-o', str(helper)], check=True)
    game = tmp / 'Игра с пробелом.NSP'
    with game.open('wb') as f: f.truncate(8 * 1024**3 + 7) # sparse; no 8 GB allocation
    second = tmp / 'DLC.nsz'; second.write_bytes(b'abc')
    def args(serial='test-switch', storage=5):
        return ['send','42','7','12288',str(storage),serial,str(game),str(second)]
    def run(mode, arguments):
        p = subprocess.run([str(helper),*arguments], env={**os.environ,'TEST_MTP_MODE':mode}, capture_output=True, text=True)
        return p.returncode, [json.loads(line) for line in p.stdout.splitlines()]
    rc, events = run('ok',['scan'])
    assert rc == 0 and events[0]['storage'] == 5
    rc, events = run('ok',args())
    assert rc == 0 and sum(e['type']=='sent' for e in events) == 2
    assert next(e for e in events if e['type']=='start')['size'] == 8589934599
    for mode, arguments in [('nand',args()),('other',args()),('ok',args(storage=1)),('ok',args(serial='different'))]:
        rc, events = run(mode,arguments)
        assert rc != 0 and not any(e['type']=='start' for e in events), (mode,events)
    rc, events = run('fail',args())
    assert rc == 1 and sum(e['type']=='start' for e in events)==1 and not any(e['type']=='sent' for e in events)
    p = subprocess.Popen([str(helper),*args()],env={**os.environ,'TEST_MTP_MODE':'cancel'},stdout=subprocess.PIPE,text=True)
    events=[]
    for line in p.stdout:
        e=json.loads(line); events.append(e)
        if e['type']=='start': p.send_signal(signal.SIGUSR1)
    assert p.wait(timeout=10)==3 and events[-1]['type']=='cancelled'
    assert sum(e['type']=='start' for e in events)==1 and not any(e['type']=='sent' for e in events)
    empty=tmp/'empty.nsp'; empty.touch()
    rc, events=run('ok',args()[:6]+[str(empty)])
    assert rc==1 and not any(e['type']=='start' for e in events)
    # Regression: discovering a DBI device must NOT release it before SendObject.
    # The very same open handle must serve multiple batches without CloseSession.
    trace = tmp / 'session.trace'
    p = subprocess.Popen([str(helper),'session'], env={**os.environ,'TEST_MTP_TRACE':str(trace)},
                         stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=False)
    def until(kind):
        result=[]
        while True:
            line=p.stdout.readline()
            assert line, (kind,result,p.poll())
            event=json.loads(line); result.append(event)
            if event['type']==kind: return result
    def command(args):
        data=b''.join(str(x).encode('utf-8')+b'\0' for x in args)
        p.stdin.write(struct.pack('!I',len(data))+data); p.stdin.flush()
    until('ready')
    assert p.poll() is None and trace.read_text().splitlines()==['open']
    command(['ping']); until('pong')
    assert p.poll() is None and trace.read_text().splitlines()==['open']
    command(['send','5',game,second])
    events=until('batchdone')
    assert sum(e['type']=='sent' for e in events)==2
    assert trace.read_text().splitlines()==['open','send','send'] and p.poll() is None
    newline=tmp/'DLC\nwith newline.NSP'; newline.write_bytes(b'abc')
    command(['send','5',newline])
    until('batchdone')
    assert trace.read_text().splitlines()==['open','send','send','send']
    command(['quit']); until('closed')
    assert p.wait(timeout=5)==0
    assert trace.read_text().splitlines()==['open','send','send','send','close']
    p = subprocess.Popen([str(helper),'session'], env={**os.environ,'TEST_MTP_PING_FAIL':'1'}, stdin=subprocess.PIPE,stdout=subprocess.PIPE)
    while json.loads(p.stdout.readline())['type']!='ready': pass
    data=b'ping\0';p.stdin.write(struct.pack('!I',len(data))+data);p.stdin.flush()
    events=[json.loads(line) for line in p.stdout]
    assert any(e['type']=='sessionlost' for e in events) and p.wait(timeout=5)==1
print('Backend integration tests passed: SD-only targeting, USB/serial identity, 8 GB sparse file, stop on error, cooperative cancellation, empty-file rejection, persistent session across discovery and multiple batches, newline filenames.')
