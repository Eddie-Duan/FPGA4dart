import os
roots = [r"c:\Users\DUANboyang\Desktop\FPGA4dart", r"c:\Users\DUANboyang\Desktop\dart2026_-open-source"]
keys = ["数码", "smg", "seg7", "seven_seg", "segment", "SEG", "tube", "Tube", "digit", "七段", "8段"]
skip = {'.git','.venv','node_modules','xsim.dir','.runs','.cache','.hw','.sim','.gen','.ip_user_files','webtalk','__pycache__','.Xil'}
exts = ('.v','.sv','.vh','.svh','.py','.c','.h','.md','.tcl','.xdc','.html','.txt','.xpr','.xml')
for root in roots:
    print('==== ' + root)
    for dp,dn,fn in os.walk(root):
        dn[:] = [d for d in dn if d not in skip]
        for f in fn:
            if os.path.splitext(f)[1].lower() not in exts: continue
            p = os.path.join(dp,f)
            try: b = open(p,'rb').read()
            except Exception: continue
            t = None
            for enc in ('utf-8','gbk'):
                try: t = b.decode(enc); break
                except Exception: pass
            if t is None: continue
            hits = [k for k in keys if k in t]
            if hits:
                print('  ' + os.path.relpath(p, root) + '  ' + ','.join(hits))
print('done')
