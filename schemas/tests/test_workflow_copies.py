"""The WF-02 test copy (F-08) is generated from WF-02 and must stay current."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_wf02_test_copy_is_current():
    r = subprocess.run([sys.executable, str(ROOT / "scripts/make_wf02_test_copy.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
