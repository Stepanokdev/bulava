#!/bin/bash
#
# Copies the work engine into the built app, and stamps it with this build's number.
#
# The app looks for `engine/install.sh` inside its own Resources (OrchestratorHome.bundled) and
# installs that copy into ~/Library/Application Support/Bulava/engine on first launch. Without
# this phase the app builds but ships no engine, and every launch reports "not installed".
#
# Run as the target's last build phase, after Resources, so nothing else overwrites what it wrote.
set -euo pipefail

SRC="${SRCROOT:?}/engine"
DEST="${BUILT_PRODUCTS_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/engine"

if [ ! -f "$SRC/install.sh" ]; then
  echo "error: no engine at $SRC — the app would ship without one." >&2
  exit 1
fi

mkdir -p "$DEST"

# `--delete` so that a file removed from the repository also leaves the bundle: an incremental
# build otherwise keeps a script the engine no longer has, and the installer copies it onward.
# Executable bits travel with `-a`; the engine is a tree of shell scripts and they must stay so.
/usr/bin/rsync -a --delete \
  --exclude '.DS_Store' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.git/' \
  "$SRC/" "$DEST/"

# The version the app compares against what is installed (OrchestratorHome.installedIsStale reads
# it as an integer). It is written here rather than committed, so the number always matches the
# build the engine actually shipped in.
printf '%s\n' "${CURRENT_PROJECT_VERSION:-0}" > "$DEST/.engine-version"
