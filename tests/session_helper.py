"""Exercise the session helper contract without Wine or a live Discord client."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="discord-session-") as tmp:
    root = Path(tmp).resolve() / "plugin with spaces"
    root.mkdir()
    helper = root / "session-helper"
    shutil.copy2(sys.argv[1], helper)
    prefix = root / "prefix with spaces"
    prefix.mkdir()
    wine = root / "wine loader"
    wine.touch()
    wine.chmod(0o755)
    (root / "notproton-discord.exe").touch()
    host = root / "host"
    host.write_text(f"""#!{sys.executable}
import os, sys
from pathlib import Path
assert int(sys.argv[1]) == os.getppid()
assert sys.argv[2] == {str(wine)!r}
assert sys.argv[3] == {str(root / 'notproton-discord.exe')!r}
assert os.environ['WINEPREFIX'] == {str(prefix)!r}
assert 'STEAM_DYLD_INSERT_LIBRARIES' not in os.environ
""")
    host.chmod(0o755)
    args = [str(helper), str(os.getpid()), str(wine), str(prefix)]
    env = dict(os.environ, WINEPREFIX="/incorrect", STEAM_DYLD_INSERT_LIBRARIES="/unused")
    subprocess.run(args, env=env, check=True)
    for invalid in (args[:-1], [*args[:-1], "relative"], [*args[:-1], str(root / "absent")]):
        assert subprocess.run(invalid, env=env, capture_output=True).returncode == 64
