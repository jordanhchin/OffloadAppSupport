#!/bin/bash

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

/bin/bash -n "$ROOT/bin/appoffload" "$ROOT/lib/core.sh" "$ROOT/lib/tui.sh" "$ROOT/tests/test_core.sh" "$ROOT/tests/test_tui_layout.sh"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$ROOT/bin/appoffload" "$ROOT/lib/core.sh" "$ROOT/lib/tui.sh" "$ROOT/tests/test_core.sh" "$ROOT/tests/test_tui_layout.sh"
else
    echo "shellcheck not installed; syntax check completed"
fi
/bin/bash "$ROOT/tests/test_core.sh"
/bin/bash "$ROOT/tests/test_tui_layout.sh"
