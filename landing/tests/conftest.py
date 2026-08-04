import sys
from pathlib import Path

# main.py lives one directory up from tests/; pytest's default rootdir
# insertion only adds this file's own directory to sys.path since
# landing/ has no __init__.py.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
