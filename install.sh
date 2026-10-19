#!/usr/bin/env bash
# voice-remote installer: Chromecast Voice Remote -> PipeWire mic -> Handy.
#
# Builds atvvoice at a pinned upstream commit with the patches in patches/,
# installs the systemd user unit, the idempotent Handy trigger and (optionally)
# the udev button remap.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UPSTREAM="https://github.com/b0o/atvvoice"
BASE_COMMIT="0e8f641"

# Defaults; voice-remote.env overrides them, then command-line flags do.
MAC=""
PREFIX="$HOME/.local"
DO_HWDB=1
DO_HANDY=1
SET_DEFAULT=0
DRY_RUN=0
INSTALL_DEPS=0
FORCE=0

if [[ -f "$REPO_DIR/voice-remote.env" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_DIR/voice-remote.env"
fi

say() { printf '\n==> %s\n' "$*"; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
run() {
    if ((DRY_RUN)); then
        printf '  would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

  --mac AA:BB:CC:DD:EE:FF  Remote address (default: auto-detect)
  --prefix DIR             Install prefix (default: ~/.local)
  --no-hwdb                Do not install the udev button remap
  --no-handy               Do not touch Handy's settings
  --set-default            Make the virtual mic the system default input
  --install-deps           Install missing apt packages (Debian/Ubuntu)
  --dry-run                Print what would happen, change nothing
  --force                  Proceed despite a missing remote or running Handy
  -h, --help               Show this help

You can also copy voice-remote.env.example to voice-remote.env and edit it.
EOF
}

while (($#)); do
    case "$1" in
        --mac)
            MAC=${2:?--mac needs an address}
            shift 2
            ;;
        --prefix)
            PREFIX=${2:?--prefix needs a directory}
            shift 2
            ;;
        --no-hwdb)
            DO_HWDB=0
            shift
            ;;
        --no-handy)
            DO_HANDY=0
            shift
            ;;
        --set-default)
            SET_DEFAULT=1
            shift
            ;;
        --install-deps)
            INSTALL_DEPS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
done

command -v git >/dev/null || die "git is required"
command -v cargo >/dev/null || die "cargo is required: install Rust from https://rustup.rs"
command -v python3 >/dev/null || die "python3 is required"

# --- remote address -------------------------------------------------------
if [[ -z "$MAC" ]] && command -v bluetoothctl >/dev/null; then
    MAC=$(bluetoothctl devices 2>/dev/null | awk '/Chromecast Remote/ {print $2; exit}')
fi
if [[ -z "$MAC" ]]; then
    die "could not find a paired 'Chromecast Remote'. Pair it first, or pass --mac."
fi
if command -v bluetoothctl >/dev/null &&
    ! bluetoothctl info "$MAC" 2>/dev/null | grep -q 'Paired: yes'; then
    say "warning: $MAC does not look paired. Run: bluetoothctl pair $MAC && bluetoothctl trust $MAC"
fi

# --- dependencies ---------------------------------------------------------
missing=()
command -v pkg-config >/dev/null || missing+=(pkg-config)
command -v cc >/dev/null || missing+=(build-essential)
pkg-config --exists libpipewire-0.3 2>/dev/null || missing+=(libpipewire-0.3-dev)
pkg-config --exists dbus-1 2>/dev/null || missing+=(libdbus-1-dev)
ldconfig -p 2>/dev/null | grep -q libclang || missing+=(libclang-dev)
command -v pw-cat >/dev/null || missing+=(pipewire-bin)
command -v pactl >/dev/null || missing+=(pulseaudio-utils)
command -v bluetoothctl >/dev/null || missing+=(bluez)
command -v xdotool >/dev/null || missing+=(xdotool)

if ((${#missing[@]})); then
    say "missing dependencies: ${missing[*]}"
    if ((INSTALL_DEPS)); then
        command -v apt-get >/dev/null || die "automatic install supports apt-get only"
        run sudo apt-get update
        run sudo apt-get install -y "${missing[@]}"
    else
        cat <<EOF
Install them first, then re-run:
  sudo apt-get install -y ${missing[*]}
Or re-run this script with --install-deps.
EOF
        exit 1
    fi
fi

# --- build ----------------------------------------------------------------
PATCHES=("$REPO_DIR"/patches/*.patch)
[[ -e "${PATCHES[0]}" ]] || die "no patches found in $REPO_DIR/patches"
say "building atvvoice $BASE_COMMIT with ${#PATCHES[@]} patches"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
run git clone --quiet "$UPSTREAM" "$WORK/atvvoice"
run git -C "$WORK/atvvoice" checkout --quiet "$BASE_COMMIT"
for p in "${PATCHES[@]}"; do
    run git -C "$WORK/atvvoice" apply "$p"
done
run cargo build --release --manifest-path "$WORK/atvvoice/Cargo.toml"

# --- install binaries -----------------------------------------------------
say "installing binaries to $PREFIX/bin"
run install -Dm755 "$WORK/atvvoice/target/release/atvvoice" "$PREFIX/bin/atvvoice"
run install -Dm755 "$WORK/atvvoice/contrib/handy-remote-trigger" "$PREFIX/bin/handy-remote-trigger"

# --- systemd user unit ----------------------------------------------------
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
say "writing $UNIT_DIR/atvvoice.service"
run mkdir -p "$UNIT_DIR"
if ((DRY_RUN)); then
    printf '  would render the unit with MAC=%s and trigger=%s\n' \
        "$MAC" "$PREFIX/bin/handy-remote-trigger"
else
    sed -e "s|@BIN@|$PREFIX/bin/atvvoice|g" \
        -e "s|@MAC@|$MAC|g" \
        -e "s|@TRIGGER@|$PREFIX/bin/handy-remote-trigger|g" \
        "$REPO_DIR/files/atvvoice.service.in" >"$UNIT_DIR/atvvoice.service"
fi
run systemctl --user daemon-reload
run systemctl --user enable --now atvvoice

# --- udev button remap ----------------------------------------------------
if ((DO_HWDB)); then
    MODALIAS=$(grep -l 'b0005v18D1p9450' /sys/class/input/*/device/modalias 2>/dev/null | head -1 || true)
    if [[ -n "$MODALIAS" ]] || ((FORCE)); then
        EV=$(printf '%s\n' "$MODALIAS" | sed 's|^/sys/class/input/\([^/]*\)/.*|/sys/class/input/\1|')
        say "installing the button remap"
        run sudo install -Dm644 "$REPO_DIR/files/90-chromecast-remote.hwdb" \
            /etc/udev/hwdb.d/90-chromecast-remote.hwdb
        run sudo systemd-hwdb update
        if [[ -n "$EV" ]]; then
            run sudo udevadm trigger --action=change "$EV"
        else
            run sudo udevadm trigger --action=change --subsystem-match=input
        fi
    else
        say "Chromecast remote not connected; skipping the hwdb remap (reconnect and re-run, or use --force)"
    fi
fi

# --- Handy settings -------------------------------------------------------
if ((DO_HANDY)); then
    if ! command -v handy >/dev/null; then
        say "Handy not found; install it from https://handy.computer (see README)"
    elif pgrep -x handy >/dev/null && ((!FORCE)); then
        say "Handy is running; quit it and re-run to merge settings (or use --force)"
    elif ((DRY_RUN)); then
        say "would merge files/handy-settings.json into Handy's settings"
    else
        say "merging Handy settings"
        python3 - "$REPO_DIR/files/handy-settings.json" <<'PY'
import json, os, shutil, sys
src = json.load(open(sys.argv[1]))
path = os.path.expanduser("~/.local/share/com.pais.handy/settings_store.json")
if not os.path.exists(path):
    print("Handy settings file not found; run Handy once, then re-run.")
    sys.exit(0)
backup = path + ".bak-voice-remote"
if not os.path.exists(backup):
    shutil.copy2(path, backup)
with open(path) as fh:
    data = json.load(fh)
data.setdefault("settings", {}).update(src)
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
print("merged; backup at", backup)
PY
    fi
fi

# --- default source -------------------------------------------------------
if ((SET_DEFAULT)); then
    say "making atvvoice-chromecast-remote the default input"
    run pactl set-default-source atvvoice-chromecast-remote
fi

cat <<EOF

Done.

Next steps:
  1. Install Handy (https://handy.computer) and download whisper-small.en.
  2. Point dictation at the virtual mic:
       pactl set-default-source atvvoice-chromecast-remote
     (or re-run with --set-default)
  3. Hold the remote's voice button and speak; release to transcribe and paste.

Check:
  systemctl --user status atvvoice
  journalctl --user -u atvvoice -f
  pactl list short sources | grep atvvoice

Undo: ./uninstall.sh
EOF
