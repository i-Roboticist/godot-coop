# Godot Co-op

**Real-time collaboration for the Godot editor.** Several people work on the same Godot project at the same time, each in their own editor. Scene edits, script typing, new files and project settings show up for everyone live, a bit like Google Docs or Roblox Team Create.

It has three parts:

| Part | What it does |
|---|---|
| **Godot Co-op app** (`GodotCoop.exe`) | The Windows app. Host a project, or paste an invite to join one: it downloads the project and the exact Godot version, installs the plugin, and opens the editor already connected. |
| **Editor plugin** (`addons/godot_coop`) | The live part inside Godot: syncs scenes, scripts, files and settings, shows teammates' selections, cursors and cameras, and adds the Co-op dock. It also works without the app. |
| **Relay server** (same exe, `--relay`) | Optional. Lets people connect through any firewall and gives you short codes like `ABCD-EFGH`. Everything it forwards is end-to-end encrypted. |

Requires **Godot 4.4 or newer** (built and tested on **4.7.2**). Everyone in a session must use the same Godot version; the app downloads it for you.

---

## Quick start

### Host
1. Open **Godot Co-op**, then click **Host a project** and pick your project folder.
2. Click **Start hosting**. Godot opens with a **Co-op** dock and an invite code.
3. Send the code or link to your teammate (Discord, email, anything).
4. When they connect, Godot asks you: **Let in as editor**, **as viewer**, or **Deny**.

### Join
1. Open **Godot Co-op**, click **Join a session** and paste the code (or click a `godotcoop://` link).
2. The app shows the project, its size, the Godot version it needs, and any files that can run code in the editor.
3. Click **Download & open in Godot**. When the editor opens, you're in.

### Without the app
Copy `addons/godot_coop` into your project, enable **Godot Co-op** under *Project → Project Settings → Plugins*, and use the Co-op dock:
- **Start hosting**, or
- paste an invite into **Join a session**. Joining makes the folder match the host's project; any of your files that conflict are backed up to `.coop/conflicts/`.

The app can also add the plugin to a project for you:
```bash
GodotCoop.console.exe --headless -- --install-plugin "C:\path\to\MyGame"
```

---

## Features

**Connecting**
- Invite codes (`gdc1.…`), `godotcoop://join/…` links, optional https links via `web/join/index.html`, and short codes when a relay is set.
- The host approves every new person and picks their role. People already admitted reconnect automatically and don't need approval again.
- Connection paths, tried together:
  - LAN and VPN addresses (Tailscale, ZeroTier…),
  - your public address with the router port opened automatically (UPnP),
  - **UDP hole punching** coordinated by the relay,
  - and finally the **relay**, which forwards traffic.
- **End-to-end encryption.** Keys come from a secret in the invite (AES-256-CBC + HMAC-SHA256, replay-protected). A relay can't read or forge traffic.
- **Same version enforced.** A different Godot version is turned away, and the message says which version is needed; the app downloads it.

**Live editing**
- **Scenes:** add, delete, rename, reparent and reorder nodes; properties; sub-resources such as shapes and materials (edited in place); groups and signal connections. Gizmo drags stream live.
- **Scripts:** everyone types in the same file at once (operational transforms, as in Google Docs). Teammates' carets and selections show in their colour.
- **Per-user undo.** Ctrl+Z undoes only your own changes, in scenes and in scripts.
- **Files:** anything added, changed or deleted in the project folder syncs, including from outside Godot (VS Code, Aseprite…). New assets import automatically.
  - Big files stream in chunks with progress and are verified by SHA-256.
  - Conflicts: the host's copy wins, and yours is backed up.
  - Reconnects do a three-way merge.
- **Project settings** sync through Godot's API, so no restart and no overwritten `project.godot`.
- **Scene locks.** Lock a scene to edit it alone; everyone else watches live and can *Request control*.

**Presence**
- People list shows who is where (`level.tscn · 3D`, `player.gd:42`) and their connection type.
- Teammates' selections and 2D mouse cursors are drawn in your viewport. In 3D you see their selections and where their camera is.
- Teammates' selections are highlighted in the Scene dock; files they have open are highlighted in the FileSystem dock.
- **Follow:** your view tracks a teammate's scene, 2D pan/zoom, 3D camera or script.
- **Ping:** right-click a node, a spot in the 2D view, a script line or a file, then **Ping for Everyone**. It flashes for everyone and has a *Jump* button.
- **Activity feed** (click an entry to jump there), e.g. "Cole changed Player.speed 200 → 250". Plus team **chat**.

**Playtesting together**
- **Play for everyone** runs the game on every machine at once.
- For multiplayer games, the instances connect automatically: the host's game is the server, and everyone else's connects through an encrypted tunnel inside the session. Works even through the relay, with no port forwarding:
  ```gdscript
  const CoopPlaytest = preload("res://addons/godot_coop/runtime/coop_playtest.gd")

  func _ready():
      if CoopPlaytest.is_active():
          multiplayer.multiplayer_peer = CoopPlaytest.create_peer()  # server on host, client elsewhere
  ```

**Roles and safety**
- Roles: **host**, **editor**, **viewer** (read-only; edits are undone with a notice), or an editor **limited to folders** (e.g. `res://art`). The host can remove people.
- **Code-running files are held for review**: editor plugins, `@tool` scripts (including ones embedded in scenes), GDExtensions and executables. Accept or reject them in the dock's **Review** tab; the joiner sees the list before downloading. Autoload and plugin changes to project settings wait for approval too.
- Synced paths are validated (no `..`, no absolute paths, no Windows device names). `.godot/` and `.git/` are never synced. Add your own exclusions in `.coopignore` (gitignore-style).

**Git**
- When you join, the plugin compares commits with the host and warns if they differ.
- The app can **clone the host's repo** and check out the same commit before syncing.
- When the session ends, the host can **commit the session's changes with every contributor as a co-author**.

---

## Relay server (optional)

A relay is what makes connections work through any firewall and enables short codes. Run one on any machine with a public UDP port; a cheap VPS is plenty:

```bash
GodotCoop.console.exe --headless -- --relay --port 47600
```

Open **UDP 47600 and 47601** (47601 is used to coordinate hole punching). Then put the relay's address in **Settings** (app) or **Connection settings** (dock). Only the **host** needs it; joiners get the relay from the invite. You can also tick **Run a relay server here** in the app's Settings. On Linux, export the Linux build (`python build.py --linux`).

## Invite web page (optional)

Host `web/join/index.html` anywhere static, e.g. GitHub Pages, and paste its URL into Settings. Invites then become clickable `https://…/join/#gdc1…` links. The code sits after `#`, so it is never sent to the web server. The page opens the app through `godotcoop://`. Click **Register godotcoop:// links** in the app's Settings once; it's per Windows user and needs no admin rights.

---

## Building from source

Needs Python 3 and a Godot 4.7.x editor with export templates.

```bash
python build.py
```

This produces `dist/GodotCoop/GodotCoop.exe` (plus `GodotCoop.console.exe`, the web page and a relay launcher) and `dist/godot_coop_plugin.zip`. Set `GODOT=…` if your editor isn't found. Add `--test` to run all test suites first, `--linux` for a Linux build.

Run the app from source with `Godot --path app`.

## Tests

| Suite | What it covers | Command |
|---|---|---|
| Unit (111 checks) | Text-merge fuzzing incl. 3-client convergence with undo, encryption (tamper/replay/reflection), invites, path safety, sync planner, scene model, value serialization, security scanner | `Godot --headless --path app -s res://tests/unit_tests.gd` |
| App (17) | Plugin installer, `project.godot` editing, Godot version parsing/URLs/zip extraction | `… -s res://tests/app_tests.gd` |
| Network (49) | Relay + host + joiners in one process: approval, direct and relay-only joins, downloads, live file sync, quarantine, roles, concurrent script edits, scene ops and locks, chat, auto-reconnect, version refusal, kick, end | `… -s res://tests/net_tests.gd` |
| Two editors (42) | Two real headless Godot editors: every kind of scene edit, sub-resources, simultaneous typing, per-user undo, stale-buffer protection, file sync, settings, presence, locks, chat, follow, playtest tunnel, ending from the app | `python tests/editor/run_editor_tests.py` |
| End-to-end, windowed | The app hosts → real editor; a second app joins from the invite (download, plugin install, launch) → screenshots of presence, carets, follow mode | `python tests/editor/run_visual_test.py` |

## How it works

```
 Host PC                                           Teammate's PC
┌─────────────────────────────┐                   ┌─────────────────────────────┐
│ Godot editor + plugin       │                   │ Godot editor + plugin       │
│  session (host = referee)   │◄── encrypted ENet ──►│  session (joined)           │
│  • file sync (source of     │   direct / punched  │  • file sync                │
│    truth)                   │   / via relay       │  • scene + script sync      │
│  • scene docs, text docs    │                   │  • presence, follow, pings  │
└─────────────────────────────┘                   └─────────────────────────────┘
            ▲  .coop/launch.json, status.json                  ▲
       Godot Co-op app (host)                         Godot Co-op app (join: download,
                                                      Godot version, plugin, launch)
```

- **Host-authoritative.** The host's files are the source of truth, and the host orders every live edit, so all copies converge. Its own editor is just "peer 1".
- **Scenes.** Every node in an open scene gets a stable id. Local edits are found by diffing the tree against the last synced state, then sent as small ops. Ops from others are applied directly to nodes, outside your undo history. Anything unexpected falls back to a full reconcile against the host's copy.
- **Scripts** use operational transformation (a port of ot.js). Remote edits go into the CodeEdit as minimal inserts and deletes, so your caret stays put.
- **Open files aren't written from sync.** If someone saves a scene or script you have open, the newer file is applied when you close it; your open copy is already live-synced. This avoids Godot's "file changed on disk" prompts.

Code map:

| Path | Contents |
|---|---|
| `app/addons/godot_coop/core/` | Engine-agnostic core: `net.gd`, `session.gd`, `crypto_box.gd`, `file_sync.gd`, `host_docs.gd`, `scene_doc.gd`, `ot.gd`, `ot_client.gd`, `wire.gd`, `invite.gd`, `relay_server.gd`, `security.gd`, `git.gd` |
| `app/addons/godot_coop/editor/` | Editor integration: scene/script/settings sync, presence, playtest, dock |
| `app/src/` | The companion app |
| `examples/demo_game/` | A small 2D + 3D project to try it on |

## Limitations

- **Everyone needs the same Godot version.** This is enforced.
- **Nodes added inside an instanced sub-scene ("editable children")** aren't live-synced. They reach teammates through the saved file, which appears when they reopen the scene. Editing the sub-scene itself is live.
- **C# scripts** sync as files on save, not keystroke by keystroke (they are edited in an external IDE anyway). Text resources and other files also sync on save.
- **If the host leaves, the session ends.** There is no host migration. Unsaved edits stay in each person's editor, so save before ending.
- **3D follow** moves your editor camera directly. It holds until you navigate yourself, which ends following.
- **What I tested and what I didn't:**
  - Tested on loopback and LAN on one Windows PC.
  - NAT hole punching and UPnP are implemented but not tested across real routers.
  - The registry link registration and the full Godot download are implemented but weren't run (the download URL format and the zip extraction are tested).
  - The app is built for Windows; the core and plugin are cross-platform GDScript.
