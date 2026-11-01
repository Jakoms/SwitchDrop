#!/usr/bin/env python3
import os,pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    subprocess.run([str(root/'SwitchDrop.app/Contents/MacOS/SwitchDrop'),'--connection-test',str(root/'Tests/fake-session.py')],env={**os.environ,'SWITCHDROP_TEST_ROOT':directory},check=True,timeout=35)
