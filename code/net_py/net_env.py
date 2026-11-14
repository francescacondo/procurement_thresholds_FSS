"""
net_env.py -- record the Python environment used by the network pipeline.
Writes code/net_environment.txt (interpreter path, versions of all packages).
If bicm cannot be imported the pipeline continues; Phases 3 and 6 then use the
fallbacks described in the task (the file says so).
"""
import os
import platform
import sys
import time
from importlib.metadata import version, PackageNotFoundError

sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))  # Stata defines no __file__
from net_common import Paths, get_root, log

P = Paths(get_root())
lines = ["Network extension -- Python environment",
         "written: " + time.strftime("%Y-%m-%d %H:%M:%S"),
         "python executable: " + sys.executable,
         "python version: " + sys.version.replace("\n", " "),
         "platform: " + platform.platform()]
for pkg in ["pandas", "numpy", "scipy", "pyreadstat", "bicm", "numba", "narwhals", "tqdm"]:
    try:
        __import__(pkg)
        lines.append("%-11s %s" % (pkg, version(pkg)))
    except (ImportError, PackageNotFoundError) as e:
        lines.append("%-11s NOT AVAILABLE (%s)" % (pkg, e))
out = os.path.join(P.code, "net_environment.txt")
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
for ln in lines:
    print(ln)
log("wrote " + out)
