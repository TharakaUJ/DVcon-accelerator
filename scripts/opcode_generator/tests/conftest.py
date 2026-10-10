import os
import sys

# Tests live in scripts/opcode_generator/tests/ and import the modules as
# `scripts.opcode_generator.<module>`, so the repository root must be on
# sys.path (true when running `python3 -m ...` from the repo root; this makes
# plain `pytest` work from any directory too).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
