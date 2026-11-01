#!/usr/bin/env python3
import os, pathlib, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[1]
prefix=pathlib.Path(os.environ.get('LIBMTP_PREFIX',root/'.build/deps-13.0'))
if not (prefix/'include/libmtp.h').exists():
    prefix=pathlib.Path(subprocess.check_output(['brew','--prefix','libmtp'],text=True).strip())
with tempfile.TemporaryDirectory() as directory:
    binary=str(pathlib.Path(directory)/'adapter-unit')
    subprocess.run(['clang','-Wall','-Wextra','-Werror','-I'+str(prefix/'include'),str(root/'Tests/adapter-unit.c'),'-o',binary],check=True)
    subprocess.run([binary],check=True)
