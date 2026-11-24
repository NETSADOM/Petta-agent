#!/bin/sh
# Record the three task logs in ONE CLI session:
#   sh scripts/record_logs.sh
# Needs an LLM (GEMINI_API_KEY or OPENAI_* in the shell or in .env).
# Fresh workspace (logs/run-workspace) and fresh memory for every recording;
# the transcript lands in logs/session-*.log, the files the agent made in
# logs/run-workspace/.
cd "$(dirname "$0")/.." || exit 1
rm -rf logs/run-workspace logs/audit.jsonl data/record_kb.metta
mkdir -p logs/run-workspace
cp logs/sales.csv logs/run-workspace/sales.csv
# logs/audit.jsonl: every tool call and approval of the recorded session (JSON lines)
PAGENT_WORKSPACE=logs/run-workspace PAGENT_KB=data/record_kb.metta PAGENT_LOG_DIR=logs \
PAGENT_AUDIT=logs/audit.jsonl \
    python3 scripts/drive_session.py logs/goals.txt --answers logs/answers.txt --approve y
