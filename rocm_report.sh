#!/usr/bin/env bash
# =============================================================================
# rocm_report.sh – Parse ROCm setup logs and print a human-readable summary
#
# Usage:
#   ./rocm_report.sh [LOG_DIR]
#
#   LOG_DIR defaults to ./logs
# =============================================================================
set -euo pipefail

LOG_DIR="${1:-./logs}"

if [[ ! -d "$LOG_DIR" ]]; then
    echo "Log directory not found: $LOG_DIR"
    exit 1
fi

echo ""
echo "============================================================"
echo "  ROCm Setup Report"
echo "  Log directory: $LOG_DIR"
echo "  Generated    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# Latest summary file
SUMMARY=$(ls -t "$LOG_DIR"/summary_*.txt 2>/dev/null | head -1 || true)
if [[ -n "$SUMMARY" ]]; then
    echo ""
    echo "--- Latest Summary ---"
    cat "$SUMMARY"
fi

# Per-version test logs
echo ""
echo "--- Test Results Per Version ---"
for test_log in "$LOG_DIR"/test_*.log; do
    [[ -f "$test_log" ]] || continue
    version=$(basename "$test_log" .log | sed 's/^test_//')
    pass_count=$(grep -c "✅ PASS" "$test_log" 2>/dev/null || echo 0)
    fail_count=$(grep -c "❌ FAIL" "$test_log" 2>/dev/null || echo 0)
    printf "  %-10s  PASS: %-3s  FAIL: %s\n" "$version" "$pass_count" "$fail_count"
done

# Master log tail
MASTER=$(ls -t "$LOG_DIR"/rocm_setup_*.log 2>/dev/null | head -1 || true)
if [[ -n "$MASTER" ]]; then
    echo ""
    echo "--- Last 20 lines of master log ---"
    tail -20 "$MASTER"
fi

echo ""
echo "============================================================"
echo "  Full logs: $LOG_DIR/"
echo "============================================================"
