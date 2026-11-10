# NotProton Discord RPC

An opt-in plugin that forwards Discord Rich Presence from Windows games running
under NotProton to the macOS Discord desktop app. It bridges Discord's Windows
named pipe to Discord's local Unix socket. The game supplies its own Discord
application ID and activity, so there is no plugin-wide application ID or token.

Targets NotProton's plugin developer preview on upstream main at
[`d69a6b5`](https://github.com/NotProtonNot/NotProton/commit/d69a6b56a9e4527bfa0bbb73ef438d82e3081994).
The descriptor exposes the toggle on the named Rosetta tools. The FEX loader
does not activate this plugin through the preview's dylib injection path. Games
need to implement Discord's local RPC protocol for the bridge to show activity.

## Install

Quit Steam. Extract the release ZIP **into** `~/Library/Application Support/notproton`
so that the archive's `plugins/` and `integrations/` directories merge into the
existing ones. For example, from the download directory run:

```sh
unzip -o notproton-plugin-discord-rpc.zip -d "$HOME/Library/Application Support/notproton"
```

1. Open Discord on macOS and enable activity sharing if you want your activity visible.
2. Open Steam, then open the game's **Properties → Compatibility**.
3. Select a NotProton Rosetta tool and enable **Discord Rich Presence** in the
   Developer section. The toggle sets `NOTPROTON_DISCORD_BRIDGE=1` for that game.
4. Launch the game. The helper starts alongside Wine and closes when its Wine
   parent exits. Games that attempt RPC during a cold start may need to retry
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

The installable archive is `dist/notproton-plugin-discord-rpc.zip`. For the Wine
integration test, set `CX_ROOT` to a CrossOver runner's `CrossOver` directory,
`DISCORD_TEST_WINE` to its `lib/wine/x86_64-unix/wine`, and
`DISCORD_TEST_WINESERVER` to the matching `bin/wineserver` or `bin/wineserver-x86`.
Run `make wine-test` to exercise 32-bit and 64-bit clients in a disposable prefix
against a mock Discord socket, including a Wine launch that loads the plugin.

## Credits

The bridge and transport tests are adapted from [NotProton PR #273](https://github.com/NotProtonNot/NotProton/pull/273),
which rebased the original bridge from PR #119. See [NOTICE](NOTICE) and [LICENSE](LICENSE).
