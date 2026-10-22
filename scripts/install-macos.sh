#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseFast
bundle="zig-out/ArpStick.clap"
codesign --force --sign - "$bundle"
destination="$HOME/Library/Audio/Plug-Ins/CLAP"
mkdir -p "$destination"
ditto "$bundle" "$destination/ArpStick.clap"
printf 'Installed %s/ArpStick.clap\nRestart REAPER or rescan CLAP plugins, then search for Arp Stick.\n' "$destination"
