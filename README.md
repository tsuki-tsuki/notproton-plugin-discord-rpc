# NotProton Discord RPC

An opt-in plugin that forwards Discord Rich Presence from Windows games running
under NotProton to the macOS Discord desktop app. It bridges Discord's Windows
named pipe to Discord's local Unix socket. The game supplies its own Discord
application ID and activity, so there is no plugin-wide application ID or token.

This package targets the proposed NotProton `session_helper` descriptor field.
It requires a NotProton build implementing that contract. NotProton 1.2.4 and
upstream main at `d69a6b5` reject the new field. For those builds, use the
Rosetta-only injection package from commit `6db6ecf`.

Games need to implement Discord's local RPC protocol for the bridge to show
activity.

## Install

Quit Steam. Extract the release ZIP **into** `~/Library/Application Support/notproton`
so that the archive's `plugins/` and `integrations/` directories merge into the
existing ones. For example, from the download directory run:

```sh
unzip -o notproton-plugin-discord-rpc-session-helper.zip -d "$HOME/Library/Application Support/notproton"
```

1. Open Discord on macOS and enable activity sharing if you want your activity visible.
2. Open Steam, then open the game's **Properties → Compatibility**.
3. Select a NotProton Rosetta or FEX tool and enable **Discord Rich Presence** in the
   Developer section. The toggle sets `NOTPROTON_DISCORD_BRIDGE=1` for that game.
4. Launch the game. The helper starts alongside Wine and closes when the NotProton
   session owner exits. Games that attempt RPC during a cold start may need to retry
   the connection while the helper starts.

To uninstall, quit Steam and remove `plugins/discord-rpc.conf` and
`integrations/discord-rpc/` from the NotProton support directory.

## Build and verify

Use macOS with Xcode Command Line Tools, MinGW-w64, and Python 3. On Homebrew,
the cross compiler is provided by `mingw-w64`.

```sh
make test
make release
```

The archive is `dist/notproton-plugin-discord-rpc-session-helper.zip`. Set
`CX_ROOT` to the runner's CrossOver directory and set `DISCORD_TEST_WINE` and
`DISCORD_TEST_WINESERVER` to the matching runner executables. Run `make wine-test`
to exercise the helper with 32-bit and 64-bit clients in a disposable prefix
against a mock Discord socket. Run once with each runner to cover both.

## Session helper contract

NotProton starts the descriptor's executable as a direct child of the game
session owner, using the same runner environment as the game, with arguments
`SESSION_OWNER_PID WINE_LOADER WINE_PREFIX`. The loader must be the original
runner executable. The loader and prefix paths are absolute and the prefix
must already exist. Start the helper asynchronously before launching the
game. On game exit, launch failure, or cancellation, send SIGTERM and reap the
helper. It also shuts down if its session owner exits unexpectedly.

## Credits

The bridge and transport tests are adapted from [NotProton PR #273](https://github.com/NotProtonNot/NotProton/pull/273),
which rebased the original bridge from PR #119. See [NOTICE](NOTICE) and [LICENSE](LICENSE).
