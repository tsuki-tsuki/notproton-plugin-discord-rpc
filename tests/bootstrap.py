"""Check discovery and environment through dyld's actual injection entry point."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="discord-bootstrap-") as tmp:
    root = Path(tmp).resolve()
    plugin = root / "plugin with spaces"
    plugin.mkdir()
    library = plugin / "discord-rpc.dylib"
    shutil.copyfile(sys.argv[1], library)
    output = root / "result"
    host = plugin / "host"
    host.write_text(f"""#!{sys.executable}
import os, sys
from pathlib import Path
assert int(sys.argv[1]) == os.getppid()
assert "DYLD_INSERT_LIBRARIES" not in os.environ
assert "NOTPROTON_DISCORD_PLUGIN" not in os.environ
Path(os.environ["RESULT"]).write_text("\\n".join(sys.argv[2:]))
""")
    host.chmod(0o755)
    (plugin / "notproton-discord.exe").touch()
    runner = root / "runner with spaces"
    loader = runner / "lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine"
    loader.parent.mkdir(parents=True)
    source = root / "fixture.c"
    source.write_text("#include <unistd.h>\nint main(void) { sleep(1); return 0; }\n")
    subprocess.run(["cc", str(source), "-o", str(loader)], check=True)
    prefix = root / "prefix"
    prefix.mkdir()
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library), CX_ROOT=str(runner),
               WINEPREFIX=str(prefix), RESULT=str(output), WINESERVER=str(runner / "bin/wineserver"))
    subprocess.run([loader, "0.5"], env=env, check=True)
    assert not output.exists(), "An injection without opt-in started the bridge"
    env["NOTPROTON_DISCORD_PLUGIN"] = "1"
    subprocess.run([loader, "1"], env=env, check=True)
    assert output.read_text().splitlines() == [str(loader), str(plugin / "notproton-discord.exe")]
