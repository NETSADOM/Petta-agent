"""Drive ONE P-agent CLI session from a script, for recording logs.

    python3 scripts/drive_session.py GOALS.txt [--answers ANSWERS.txt] [--approve y|n]

GOALS.txt    one goal per line, typed at "you>" in order; then "quit".
ANSWERS.txt  one line per question the agent asks (ask-user), in order.
             When they run out, the driver answers with an empty line.
--approve    what to type at every "[y/N]" approval prompt (default y).

It plays the user at the keyboard: it waits for the agent's prompts and types
the next line, exactly as a person would. Everything it types appears in the
session transcript (logs/session-*.log) after the prompt it answered, so the
log shows who decided what. It never edits the agent's output.
"""
import argparse
import os
import subprocess
import sys

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def lines(path):
    if not path:
        return []
    with open(path, encoding="utf-8") as f:
        return [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("goals")
    ap.add_argument("--answers")
    ap.add_argument("--approve", default="y", choices=["y", "n"])
    args = ap.parse_args()
    goals, answers = lines(args.goals), lines(args.answers)

    p = subprocess.Popen(["sh", "run.sh", "main.metta"], cwd=PROJECT,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, bufsize=0)
    buf = ""

    def send(text):
        p.stdin.write((text + "\n").encode("utf-8"))
        p.stdin.flush()

    while True:
        b = p.stdout.read(1)
        if not b:
            break
        ch = b.decode("utf-8", errors="replace") if b < b"\x80" else None
        if ch is None:                              # multi-byte UTF-8 character
            rest = b
            while True:
                try:
                    ch = rest.decode("utf-8")
                    break
                except UnicodeDecodeError:
                    more = p.stdout.read(1)
                    if not more:
                        ch = rest.decode("utf-8", errors="replace")
                        break
                    rest += more
        sys.stdout.write(ch)
        sys.stdout.flush()
        buf = (buf + ch)[-400:]
        if buf.endswith("you> "):
            goal = goals.pop(0) if goals else "quit"
            sys.stdout.write(goal + "\n")
            send(goal)
            buf = ""
        elif buf.endswith("[y/N] "):
            sys.stdout.write(args.approve + "\n")
            send(args.approve)
            buf = ""
        elif buf.endswith("\n> ") and "the agent asks:" in buf:
            answer = answers.pop(0) if answers else ""
            sys.stdout.write(answer + "\n")
            send(answer)
            buf = ""
    return p.wait()


if __name__ == "__main__":
    sys.exit(main())
