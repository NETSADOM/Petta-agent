#!/bin/sh
# P-agent evaluation.  sh eval/run_eval.sh          (Ubuntu Bash)
#   offline: always (no Gemini needed)
#   live:    only when GEMINI_API_KEY is set (makes real Gemini calls, ~50-150)
# Every approval request is answered "n". Report: eval/report.md
cd "$(dirname "$0")/.." || exit 1

echo "== offline evaluation"
yes n | env -u GEMINI_API_KEY sh ./run.sh eval/offline.metta > eval/offline.log 2>&1 \
    || { echo "offline run crashed, see eval/offline.log"; exit 1; }
python3 eval/eval_log.py offline

if [ -n "$GEMINI_API_KEY" ]; then
    echo "== live evaluation (real Gemini — this takes a few minutes)"
    yes n | sh ./run.sh eval/live.metta 2>&1 | tee eval/live.log | grep -E "eval-case|verified|stopped|NOT"
    python3 eval/eval_log.py live
else
    echo "== live evaluation SKIPPED (GEMINI_API_KEY not set)"
fi
echo "report: eval/report.md"
