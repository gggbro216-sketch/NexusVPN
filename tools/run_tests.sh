#!/usr/bin/env bash
# Runs the headless GDScript test suite.
#   GODOT=godot (4.7.x)  NEXUS_SINGBOX_BIN=<sing-box 1.14 binary> (optional, enables core checks)
#   NEXUS_TEST_FILTER=<substring> (optional)
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
# Refresh the global class cache (new class_name scripts) before running.
"$GODOT" --headless --path . --editor --quit >/dev/null 2>&1 || true
"$GODOT" --headless --path . res://tests/run_tests.tscn
