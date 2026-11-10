"""Check fallback activity and game priority through a mock Discord socket."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile


def read_exact(peer, length):
    data = bytearray()
    while len(data) < length:
        chunk = peer.recv(length - len(data))
        if not chunk:
            raise EOFError
        data.extend(chunk)
    return data


def receive(peer):
    opcode, length = struct.unpack("<II", read_exact(peer, 8))
    return opcode, json.loads(read_exact(peer, length))


def send(peer, opcode, body):
    payload = json.dumps(body).encode()
    peer.sendall(struct.pack("<II", opcode, len(payload)) + payload)


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="np-activity-", dir="/tmp") as directory:
    root = Path(directory)
    host = root / "host"
    host.symlink_to(binary)
    (root / "appmanifest_42.acf").write_text('"AppState"\n{\n "name" "Game title"\n}\n')
    fixture = root / "wine"
    fixture.write_text(f"""#!{sys.executable}
import json, os, socket, sys
from pathlib import Path
port = int(os.environ['NOTPROTON_DISCORD_PORT'])
token = os.environ['NOTPROTON_DISCORD_TOKEN']
with socket.create_connection(('127.0.0.1', port)) as control:
    control.sendall(token.encode() + bytes([0]))
    Path(sys.argv[1]).write_text(json.dumps([port, token]))
    control.recv(1)
""")
    fixture.chmod(0o755)
    endpoint = root / "endpoint"
    with socket.socket(socket.AF_UNIX) as discord:
        discord.bind(str(root / "discord-ipc-0"))
        discord.listen()
        env = dict(os.environ, NOTPROTON_DISCORD_SOCKET_DIR=directory, SteamAppId="42",
                   STEAM_COMPAT_INSTALL_PATH=str(root / "common" / "Game folder"))
        args = [str(host), str(os.getpid()), str(fixture), str(endpoint)]
        for enabled in ("0", "1"):
            with subprocess.Popen(args, env=dict(env, NOTPROTON_DISCORD_BASIC_ACTIVITY=enabled),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                try:
                    assert process.stdout.readline() == b"ready\n"
                    discord.settimeout(3)
                    if enabled == "0":
                        discord.settimeout(1)
                        try:
                            peer, _ = discord.accept()
                        except TimeoutError:
                            continue
                        peer.close()
                        raise AssertionError("fallback started while disabled")

                    def accept_fallback():
                        peer, _ = discord.accept()
                        peer.settimeout(3)
                        assert receive(peer) == (0, {"v": 1, "client_id": "1569701971353534514"})
                        send(peer, 1, {"cmd": "DISPATCH", "evt": "READY"})
                        opcode, activity = receive(peer)
                        assert opcode == 1 and activity["cmd"] == "SET_ACTIVITY"
                        assert activity["args"]["activity"]["details"] == "Game title"
                        return peer, activity["args"]["activity"]["timestamps"]["start"]

                    fallback, started = accept_fallback()
                    with fallback:
                        port, token = json.loads(endpoint.read_text())
                        with socket.create_connection(("127.0.0.1", port)) as game:
                            game.sendall(token.encode() + bytes([1]))
                            peer, _ = discord.accept()
                            with peer:
                                assert receive(fallback)[1]["args"]["activity"] is None
                                assert fallback.recv(1) == b""
                                send(game, 0, {"v": 1, "client_id": "game"})
                                assert receive(peer)[1]["client_id"] == "game"
                    fallback, resumed = accept_fallback()
                    with fallback:
                        assert started == resumed
                        process.terminate()
                        assert receive(fallback)[1]["args"]["activity"] is None
                        assert process.wait(timeout=8) == 0
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=8)
print("==> Basic activity is opt-in, yields to game RPC, resumes and clears on exit")
