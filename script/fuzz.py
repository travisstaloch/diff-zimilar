import tempfile
import sys
import os
import subprocess

textlen = 100

with  tempfile.NamedTemporaryFile() as tmpa:
    with tempfile.NamedTemporaryFile() as tmpb:
        exitcode = os.system(f"python3 script/random-utf8.py {textlen} > {tmpa.name}")
        if exitcode != 0:
            raise Exception(f"unexpected exitcode {exitcode}")
        for i in range(1_000):
            if i % 100 == 0:
                print(i)
        
            exitcode = os.system(f"python3 script/random-utf8.py {textlen} > {tmpb.name}")
            if exitcode != 0:
                raise Exception(f"unexpected exitcode {exitcode}")
            # exitcode = os.system(f"zig-out/bin/diffit {tmpa.name} {tmpb.name}")
            # r = subprocess.run(["zig-out/bin/diffit",  tmpa.name, tmpb.name]) # print stdout/err
            r = subprocess.run(["zig-out/bin/diffit",  tmpa.name, tmpb.name], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if r.returncode != 0:
                print(f"error: exitcode {r.returncode}")
                print(f"stdout: {r.stdout.read()}")
                print(f"stderr: {r.stderr.read()}")