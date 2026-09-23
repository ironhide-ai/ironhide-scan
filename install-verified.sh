#!/usr/bin/env bash
# Download data, verify the release digest, then make the CLI executable.
set -euo pipefail
if [[ ! "${CLI_SHA256:-}" =~ ^[a-fA-F0-9]{64}$ ]]; then
  echo '::error::Set cli_sha256 to the SHA-256 from the approved CLI release.'
  exit 2
fi
install_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ironhide-cli.XXXXXX")"
trap 'rm -rf "$install_dir"' ERR
# CRU-139: fetch from an IMMUTABLE artifact, never a live server path. The
# server route serves mcp-gym/cli/ironhide.py off disk, so its bytes change on
# every Ironhide deploy -- a digest pinned against it would fail closed for
# every customer on each release. The default cli_url is the release asset
# published alongside this Action tag, so the pin holds for the life of the tag.
: "${CLI_URL:?cli_url is unset; it must name the CLI artifact this Action pins}"
curl -fsSL "$CLI_URL" -o "$install_dir/ironhide.py"
python3 - "$install_dir/ironhide.py" "$CLI_SHA256" <<'PY'
import hashlib
from pathlib import Path
import sys
if hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2].lower():
    sys.exit('CLI SHA-256 mismatch; refusing to execute the download')
PY
printf '#!/bin/sh\nexec python3 "%s/ironhide.py" "$@"\n' "$install_dir" > "$install_dir/ironhide"
chmod +x "$install_dir/ironhide"
echo "$install_dir" >> "$GITHUB_PATH"
