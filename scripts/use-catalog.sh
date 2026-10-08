#!/usr/bin/env bash
# Switch the demo's catalog: activates one "# >>> catalog: NAME" block in
# .env and comments out the others. Then `demo/run-stage.sh reset` and re-run
# the stages (the Spark image rebuilds against the new catalog on its own).
#
#   scripts/use-catalog.sh polaris|lakekeeper|rest
#   scripts/use-catalog.sh            # show the active one
set -euo pipefail
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [[ $# -eq 0 ]]; then
  awk '/^# >>> catalog: /{name=$4} /^CATALOG_URI=/{print "active catalog: " name}' "${ENV_FILE}"
  exit 0
fi
case "$1" in polaris|lakekeeper|rest) ;; *) echo "usage: $0 polaris|lakekeeper|rest" >&2; exit 1 ;; esac
python3 - "${ENV_FILE}" "$1" <<'PY'
import sys
path, want = sys.argv[1], sys.argv[2]
out, block = [], None
for line in open(path).read().split("\n"):
    if line.startswith("# >>> catalog: "):
        block = line.split(": ", 1)[1].strip(); out.append(line); continue
    if line.startswith("# <<< catalog: "):
        block = None; out.append(line); continue
    if block is not None:
        bare = line[2:] if line.startswith("# ") else line
        out.append(bare if block == want else "# " + bare)
    else:
        out.append(line)
open(path, "w").write("\n".join(out))
PY
echo "active catalog: $1 -- now run: demo/run-stage.sh reset"
