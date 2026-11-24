#!/bin/sh
# Run one or more .metta files with the installed PeTTa, quietly.
#   sh run.sh main.metta                 the agent
#   sh run.sh tests/test_bridge.metta    one test
# Set PETTA_HOME if PeTTa is not at ~/PeTTa.
# API keys may live in .env next to this file (KEY=value lines; git-ignored).
# Variables already set in your shell win over .env; PAGENT_NO_DOTENV=1 skips
# it (the test suite does, so tests never call a real model by accident).
DOTENV="$(dirname "$0")/.env"
if [ -f "$DOTENV" ] && [ -z "$PAGENT_NO_DOTENV" ]; then
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in ''|\#*) continue ;; esac
        case "$key" in *[!A-Za-z0-9_]*) continue ;; esac     # only plain NAME=value lines
        value=${value%"${value##*[! ]}"}; value=${value%\"}; value=${value#\"}; value=${value%\'}; value=${value#\'}
        eval "current=\${$key:-}"
        [ -z "$current" ] && export "$key=$value"
    done < "$DOTENV"
fi
PETTA_HOME=${PETTA_HOME:-$HOME/PeTTa}
exec sh "$PETTA_HOME/run.sh" "$@" --silent
