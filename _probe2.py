import os
ROOT = r"c:\Users\DUANboyang\Desktop\FPGA4dart"
out = []
for d in ("rtl","sim","prj","tools"):
    for dp, dn, fn in os.walk(os.path.join(ROOT,d)):
        dn[:] = [x for x in dn if x not in ("xsim.dir","webtalk","__pycache__")]
        for f in fn:
            if not f.lower().endswith((".v",".vh",".sv",".xdc",".tcl",".py")): continue
            p = os.path.join(dp,f)
            b = open(p,"rb").read()
            try: t = b.decode("utf-8")
            except UnicodeDecodeError:
                try: t = b.decode("gbk")
                except UnicodeDecodeError: continue
            for i,l in enumerate(t.splitlines(),1):
                if ("资料" in l or "致能" in l or "实作" in l) and "TERM_MAP" not in l and "to_simplified" not in p:
                    out.append("%s:%d: %s" % (os.path.relpath(p,ROOT), i, l.strip()))
open(os.path.join(os.environ["TEMP"],"zh_ctx.txt"),"w",encoding="utf-8").write("\n".join(out))
print("lines:", len(out))
