# NotProton Discord RPC

An opt-in plugin that forwards Discord Rich Presence from Windows games running
under NotProton to the macOS Discord desktop app. It bridges Discord's Windows
named pipe to Discord's local Unix socket. The game supplies its own Discord
application ID and activity for relay mode. The optional basic activity uses
the bundled Discord Application ID.

Choose one ZIP for your NotProton build. Both install the same per-game toggle.

| Archive | Compatibility |
| --- | --- |
| `notproton-plugin-discord-rpc.zip` | NotProton 1.2.4 or its plugin preview on supported Rosetta tools |
| `notproton-plugin-discord-rpc-session-helper.zip` | Rosetta and FEX on a NotProton build implementing the proposed `session_helper` field |

Games need to implement Discord's local RPC protocol for the bridge to show
activity.

## Install

Quit Steam. Extract the matching ZIP **into** `~/Library/Application Support/notproton`
so that the archive's `plugins/` and `integrations/` directories merge into the
existing ones. For example, to install the Rosetta injection build from the download directory:

```sh
unzip -o notproton-plugin-discord-rpc.zip -d "$HOME/Library/Application Support/notproton"
```

1. Open Discord on macOS and enable activity sharing if you want your activity visible.
2. Open Steam, then open the game's **Properties → Compatibility**.
3. Select a compatible NotProton tool and enable **Discord Rich Presence** in the
   Developer section. The toggle sets `NOTPROTON_DISCORD_BRIDGE=1` for that game.
4. Launch the game. The bridge runs alongside Wine and shuts down with the session. Games that attempt RPC during a cold start may need to retry
   the connection while the helper starts.

To uninstall, quit Steam and remove `plugins/discord-rpc.conf` and
`integrations/discord-rpc/` from the NotProton support directory.

## Optional basic activity

With the main **Discord Rich Presence** toggle enabled, turn on **Show basic
Discord activity** in the game's Compatibility settings. It defaults to off
and uses the bundled Application ID `1569701971353534514`.

To override the ID, put your numeric Discord Application ID in a plain-text
file named `activity-client-id` alongside the installed `host` at
`~/Library/Application Support/notproton/integrations/discord-rpc/`.

The plugin sends the Steam game or shortcut title as both the activity name and
details, with an elapsed timer. Some Discord clients may use the registered
application name as the card heading. If you own the application, a short name
such as **NotProton** gives that heading a readable fallback. When Steam metadata
is unavailable, the plugin uses the install-folder name. Basic activity yields
while a game has a Discord RPC connection and clears when the session ends.
The configuration is local to your install and persists when you extract an
updated ZIP over it.

### Game artwork

Basic activity looks for a Steam-hosted icon using Steam's local artwork cache.
Without an available icon, Discord uses the registered application's icon.
To set artwork explicitly, create an `activity-icons` directory next to the
installed `host`. Create a file named after the Steam app ID or NotProton's
numeric shortcut prefix ID, with no extension. Put one public HTTPS image URL
or Discord asset key in the file. For example, `activity-icons/3081447869`
would set the artwork for a shortcut using prefix `3081447869`.

## Build and verify

Use macOS with Xcode Command Line Tools, MinGW-w64, and Python 3. On Homebrew,
the cross compiler is provided by `mingw-w64`.

```sh
make test
make release
```

Both archives are written to `dist/`. Set
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
