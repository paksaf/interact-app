#!/usr/bin/env bash
# Unblocks :livekit_client:compileReleaseKotlin on Kotlin 2.2 —
# Visualizer.bands had no initializer, so the class failed to compile in
# release and other files reported Unresolved reference 'Visualizer'.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIS="$(find "$HOME/.pub-cache/hosted" -path '*/livekit_client-2.8.1/android/src/main/kotlin/io/livekit/plugin/Visualizer.kt' 2>/dev/null | head -1)"
if [[ -z "${VIS}" ]]; then
  echo "livekit_client 2.8.1 Visualizer.kt not in pub-cache — run flutter pub get first" >&2
  exit 1
fi
python3 - <<PY
from pathlib import Path
p = Path(r"""${VIS}""")
t = p.read_text()
old = "    private var bands: FloatArray\n"
new = "    private var bands: FloatArray = FloatArray(0)\n"
if old in t:
    p.write_text(t.replace(old, new, 1))
    print(f"patched {p}")
elif "private var bands: FloatArray = FloatArray(0)" in t:
    print(f"already patched {p}")
else:
    raise SystemExit(f"unexpected Visualizer.kt shape: {p}")
PY
