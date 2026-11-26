#!/bin/sh
# Runs all tests in order. PeTTa's `test` exits with code 1 on a failure.
#   sh tests/run_tests.sh
# The live Gemini test runs only when GEMINI_API_KEY is set in this shell.
cd "$(dirname "$0")/.." || exit 1
export PAGENT_NO_DOTENV=1        # never pick up API keys from .env in tests
python3 -m unittest discover -s tests -p 'test_regressions.py' || exit 1
rm -f data/test_kb.metta data/test_schema_kb.metta data/test_memory_kb.metta data/test_cli_kb.metta data/audit.jsonl

run() {  # run [ENV-PREFIX...] FILE
    t=$(eval echo \${$#})
    echo "== $t"
    out=$("$@" 2>&1); status=$?
    echo "$out" | grep -v '^true$'
    if [ $status -ne 0 ]; then echo "FAILED: $t (exit $status)"; exit 1; fi
}

# order matters: each *_reload / *_persist test reads what the previous one saved
run sh ./run.sh tests/test_bridge.metta
run sh ./run.sh tests/test_persist.metta
run sh ./run.sh tests/test_schema.metta
run sh ./run.sh tests/test_schema_reload.metta
run env -u GEMINI_API_KEY sh ./run.sh tests/test_llm_offline.metta
run env GEMINI_API_KEY=invalid-test-key sh ./run.sh tests/test_llm_badkey.metta
# agent loop: stdin answers its questions in order (deny, approve, ask-user answer)
printf 'n\ny\nblue\n' > data/test_agent_stdin.txt
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_agent.metta < data/test_agent_stdin.txt'
# tool gates: "y" approves the single approval request
run sh -c 'echo y | env -u GEMINI_API_KEY sh ./run.sh tests/test_tools.metta'
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_skills.metta < /dev/null'
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_skill_folders.metta < /dev/null'
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_memory.metta < /dev/null'
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_memory_reload.metta < /dev/null'
run sh -c 'echo y | env -u GEMINI_API_KEY sh ./run.sh tests/test_recovery.metta'
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_verify.metta < /dev/null'
run sh -c 'echo y | env -u GEMINI_API_KEY sh ./run.sh tests/test_integration.metta'
run sh -c 'env -u GEMINI_API_KEY -u OPENAI_API_KEY sh ./run.sh tests/test_providers.metta < /dev/null'
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_context.metta < /dev/null'
# capabilities: "y" approves write-file, "n" refuses run-python
rm -rf data/test_workspace
run sh -c 'printf "y\nn\n" | env -u GEMINI_API_KEY sh ./run.sh tests/test_capabilities.metta'

# the five required tools + "errors are text, never a crash"
rm -rf data/test_tools_ws
printf 'y\n  green  \n\nteal\n' > data/test_agent_tools_stdin.txt
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_agent_tools.metta < data/test_agent_tools_stdin.txt'

# the turn loop on a 27-turn task: batches, unknown tools, recovery, context
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_long_task.metta < /dev/null'

# sub-agents (delegate) and web-search parsing
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_subagent.metta < /dev/null'

# no unnecessary steps: fast plans, batched task-done, proven answers, retries, recoveries
run sh -c 'env -u GEMINI_API_KEY sh ./run.sh tests/test_efficiency.metta < /dev/null'

# safety and honest completion: shell options, multiline input, notebook, evidence,
# no guessing, gated memory, dependency cycles, bounded prompts (stdin: no answers)
rm -rf data/test_safety_ws
run sh -c 'env -u GEMINI_API_KEY PAGENT_WORKSPACE=data/test_safety_ws sh ./run.sh tests/test_safety.metta < /dev/null'

# the real CLI (main.metta): commands, two goals in ONE session (no restart),
# the stuck report, the session history, the transcript log, clean quit
echo "== CLI (main.metta)"
rm -rf data/test_logs
cli=$(printf 'help\ntools\nmemory\nwhat is 2+2\nhistory\nand what is 3+3\nhistory\nquit\n' | env -u GEMINI_API_KEY -u OPENAI_API_KEY PAGENT_KB=data/test_cli_kb.metta PAGENT_LOG_DIR=data/test_logs sh ./run.sh main.metta 2>&1)
for expect in "P-agent" "no LLM configured" "type c + Enter to cancel" \
              "Tools (name description permission)" "Stats" "stopped:" \
              "task 1" "task 2" "I'm stuck" "could not be reached" \
              "task 2: goal: and what is 3+3" "bye"; do
    case "$cli" in *"$expect"*) echo "  ✅ shows: $expect" ;;
                   *) echo "  ❌ missing: $expect"; echo "$cli"; exit 1 ;; esac
done
case "$cli" in *"ERROR"*|*"Warning"*) echo "  ❌ error in CLI output"; echo "$cli"; exit 1 ;; esac
case "$(echo "$cli" | tail -1)" in *bye) echo "  ✅ exits cleanly after bye" ;;
     *) echo "  ❌ output after bye"; echo "$cli" | tail -3; exit 1 ;; esac
log=$(cat data/test_logs/session-*.log 2>/dev/null)
for expect in "P-agent session started" "you> what is 2+2" "you> and what is 3+3" "I'm stuck" "bye"; do
    case "$log" in *"$expect"*) echo "  ✅ transcript has: $expect" ;;
                   *) echo "  ❌ transcript missing: $expect"; echo "$log"; exit 1 ;; esac
done

if [ -n "$GEMINI_API_KEY" ]; then
    run sh ./run.sh tests/test_llm_live.metta
else
    echo "== tests/test_llm_live.metta SKIPPED (GEMINI_API_KEY not set)"
fi
echo "ALL TESTS PASSED"
