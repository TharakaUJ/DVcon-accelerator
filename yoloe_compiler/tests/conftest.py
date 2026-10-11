import os
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture(scope="session")
def runtime_built():
    """Build the C runtime once per test session."""
    proc = subprocess.run(["make", "-C", os.path.join(ROOT, "runtime")], capture_output=True, text=True)
    assert proc.returncode == 0, f"runtime build failed:\n{proc.stdout}\n{proc.stderr}"
    return True


@pytest.fixture(scope="session")
def tiny_model_path(tmp_path_factory):
    """tests/make_tiny_model.py output (examples/ is gitignored, so always regenerate)."""
    from make_tiny_model import build
    return build(str(tmp_path_factory.mktemp("tiny") / "tiny.onnx"))
