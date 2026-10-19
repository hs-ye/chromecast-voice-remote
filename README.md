# voice-remote

Hold the **voice button** on a Chromecast Voice Remote and have the words typed into
whatever window has focus on Linux — no keyboard, no laptop shortcut.

```
Chromecast Remote --BLE/ATVV--> atvvoice --PCM--> null sink --> monitor
    --> module-remap-source "atvvoice-chromecast-remote"
    --> Handy (Whisper) --> xdotool paste
                     ^
   press/release also runs: handy-remote-trigger (idempotent start/stop)
```

Tested on **Pop!_OS 22.04 (X11 GNOME)**, PipeWire 1.0.2, BlueZ 5.64, Rust 1.92, with a
**Chromecast Voice Remote (G9N9N, Google `18d1:9450`)**. The audio path should work with
other ATVV remotes, but the button remap in `files/90-chromecast-remote.hwdb` is specific
to this remote's scancodes.

## Requirements

- Linux with **PipeWire** and **pipewire-pulse** (`pactl`, `pw-cat`)
- **BlueZ** (`bluetoothctl`)
- **Rust** (`cargo`) — install from <https://rustup.rs>
- **Handy** for speech-to-text — <https://handy.computer> (not bundled)
- `xdotool` (Handy pastes with it on X11)
- A paired and trusted remote

## Quick start

### 1. Pair the remote

```bash
bluetoothctl
> scan on
# hold Back + Home (or the pairing combo for your remote) until it appears
> pair 47:54:51:48:DA:A1
> trust 47:54:51:48:DA:A1
> connect 47:54:51:48:DA:A1
> quit
```

The address is your remote's; the installer auto-detects a device named
`Chromecast Remote` or takes `--mac`.

### 2. Review, then install

```bash
git clone <this-repo> ~/GitRepos/voice-remote
cd ~/GitRepos/voice-remote
./install.sh --dry-run              # prints every command, changes nothing
./install.sh --install-deps         # apt deps + build + install
```

`--install-deps` runs `sudo apt-get install` for missing packages and `sudo` for the
udev rule. Read `install.sh` first if you prefer to run those by hand.

Useful flags:

| Flag | Effect |
|---|---|
| `--mac AA:BB:...` | Remote address (default: auto-detect) |
| `--prefix DIR` | Install prefix (default `~/.local`) |
| `--no-hwdb` | Skip the button remap |
| `--no-handy` | Do not touch Handy's settings |
| `--set-default` | Make the virtual mic the system default input |
| `--dry-run` | Print commands without running them |
| `--force` | Proceed despite a missing remote or running Handy |

You can also copy `voice-remote.env.example` to `voice-remote.env` and edit it.

### 3. Install Handy

Install Handy from <https://handy.computer>, open it once, and download the
**whisper-small.en** model. Then quit Handy and re-run:

```bash
./install.sh --no-hwdb        # merge the Handy settings
```

The settings the installer applies are in `files/handy-settings.json`:
`always_on_microphone: true`, `vad_enabled: true`, `vad_backend: "silero"`,
`selected_microphone: "pipewire"`, `paste_method: "direct"`. If Handy is running, the
installer skips this step so the app cannot overwrite it on exit.

### 4. Route the virtual mic

```bash
pactl set-default-source atvvoice-chromecast-remote
```

Handy records only the **system default input**, so this is required. It also means
every app that does not choose its own input hears silence unless the voice button is
held — that is the trade-off. `--set-default` does this for you.

### 5. Test

Hold the voice button, say something, release. The transcript is pasted into the focused
window. Check:

```bash
systemctl --user status atvvoice
journalctl --user -u atvvoice -f          # trigger(start) / trigger(stop)
pactl list short sources | grep atvvoice
```

## What the installer changes

| Path | Purpose |
|---|---|
| `~/.local/bin/atvvoice` | Patched ATVV daemon |
| `~/.local/bin/handy-remote-trigger` | Idempotent Handy start/stop wrapper |
| `~/.config/systemd/user/atvvoice.service` | User service |
| `/etc/udev/hwdb.d/90-chromecast-remote.hwdb` | Button remap (with `--no-hwdb` skipped) |
| `~/.local/share/com.pais.handy/settings_store.json` | Handy settings (backed up first) |
| `~/.local/share/com.pais.handy/settings_store.json.bak-voice-remote` | Backup for uninstall |

## Button map

The remote's extra buttons emit evdev codes above X11's 255-keycode ceiling, so they look
dead. The hwdb remaps them by scancode, below X:

| Button | Becomes |
|---|---|
| OK | `Enter` |
| Back | `Esc` |
| Home | `Super` (opens the workspace overview) |
| Volume + / − | `PageUp` / `PageDown` |
| YouTube | `/` (slash commands) |
| Netflix | `Backspace` |
| Switch input | `Tab` |
| Mute | `Home` (jump to start of line) |
| D-pad / Power | unchanged (Power suspends) |

Edit `files/90-chromecast-remote.hwdb` and re-run the udev trigger to change them. `hwdb`
maps one keycode to one keycode — no combos.

## Why the patches

Upstream `b0o/atvvoice` at `0e8f641` is the base. `patches/` contains ten commits:

1. **BLE write fallback** — the ATVV TX characteristic is write-without-response only;
   BlueZ rejects a Write Request with `NotPermitted`.
2. **HoldToTalk model** — a HoldToTalk remote re-sends `START_SEARCH` right after
   `AUDIO_START`; stock code treats that as a toggle-off and closes the mic ~30 ms in.
3. **Sink backend** — stock exposes an `Audio/Source` stream that is never scheduled on
   some PipeWire setups (process callback 0 times while reporting `running`). The patch
   plays PCM into a private null sink and republishes its monitor with
   `module-remap-source`, so the graph always has a driver.
4. **Hyphenated label** — pipewire-pulse splits module arguments at whitespace.
5. **14 dB default gain** — 20 dB clipped the remote's signal.
6. **`--trigger-cmd`** — run a command on every Streaming transition.
7. **Trigger logging** — at `info`, so a press is visible in the journal.
8. **Pacing + stop hold** — write PCM to the wall clock, wait 300 ms on stop.
9. **Capped 150 ms lead** — a brief frame gap cannot splice silence into a word.
10. **Phantom-start fix + idempotent trigger** — a late tail frame no longer counts as a
    new press; the direction is passed in `ATVVOICE_TRIGGER`, and the wrapper only toggles
    when Handy's logged state differs.

## Troubleshooting

| Symptom | Cause | Check |
|---|---|---|
| No source, or silence | atvvoice not running / remote not connected | `systemctl --user status atvvoice`; `journalctl --user -u atvvoice -n 50` |
| Audio decodes but capture is silent | `Audio/Source` stream not scheduled | `pw-top` shows `QUANT 0`; use the patched sink backend |
| Handy does not see the mic | Handy only records the system default | `pactl get-default-source` |
| Device name truncated to one word | pipewire-pulse splits arguments on whitespace | use a hyphenated description |
| Audio clips | gain too high | compare peak vs 32768; lower `--gain` |
| Press does nothing | trigger not configured / Handy not running | `journalctl` shows `trigger(start)`; `pgrep -x handy` |
| Text not pasted | no `xdotool`, or a Wayland session | `command -v xdotool`; `echo $XDG_SESSION_TYPE` |
| Buttons unchanged | remote not connected when hwdb was applied | reconnect, then re-run `./install.sh --force` |
| Press/release inverted | stale Handy state | `cat ~/.local/state/handy-remote/state`; the wrapper should self-correct on the next press |

## Uninstall

```bash
./uninstall.sh
```

Stops and removes the service and binaries, removes the hwdb (unless `DO_HWDB=0`), removes
the wrapper state, and restores Handy's settings backup. The default input is left as-is.

## Layout

```
install.sh                  installer
uninstall.sh                remover
voice-remote.env.example    optional defaults
files/
  90-chromecast-remote.hwdb  button remap
  atvvoice.service.in        templated user unit
  handy-settings.json        settings merged into Handy
patches/
  0001..0010                 atvvoice changes, pinned to 0e8f641
```

## Credits

Patches derive from [`b0o/atvvoice`](https://github.com/b0o/atvvoice) (MIT), pinned at
`0e8f641`. Handy is [`cjpais/Handy`](https://github.com/cjpais/Handy). This package is
MIT — see `LICENSE`.

## Known limitations

- The hwdb remap is specific to the Chromecast Voice Remote's scancodes.
- Handy only records the system default input; there is no per-device picker.
- `hwdb` cannot emit key combinations, so `Ctrl+C` etc. need a separate layer (keyd or a
  desktop shortcut).
- Upstream is a third-party repository; the patches are applied locally and never pushed
  to `b0o/atvvoice`.
