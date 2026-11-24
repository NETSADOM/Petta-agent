"""Collects evaluation results (eval/results_*.jsonl) and writes eval/report.md."""
import json
import os
import sys
import time
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))


def _path(track):
    return os.path.join(HERE, f"results_{track}.jsonl")


def reset(track):
    p = _path(str(track))
    if os.path.exists(p):
        os.remove(p)
    return True


def record(track, category, name, passed, detail=""):
    entry = {"category": str(category), "name": str(name),
             "passed": passed is True or str(passed).lower() == "true",
             "detail": str(detail)[:300], "time": time.strftime("%H:%M:%S")}
    with open(_path(str(track)), "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")
    return entry["passed"]


def record_live(case, category, outcome, passed, steps, llm_calls, seconds, answer):
    entry = {"category": str(category), "name": str(case), "passed": passed is True or str(passed).lower() == "true",
             "outcome": str(outcome), "steps": int(steps), "llm_calls": int(llm_calls),
             "seconds": round(float(seconds), 1), "detail": str(answer)[:200]}
    with open(_path("live"), "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")
    return entry["passed"]


def _load(track):
    p = _path(track)
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def _section(title, rows, live=False):
    out = [f"## {title}", ""]
    if not rows:
        return out + ["_not run_", ""]
    cats = OrderedDict()
    for r in rows:
        cats.setdefault(r["category"], []).append(r)
    out += ["| Category | Passed | Rate |", "|---|---|---|"]
    for c, rs in cats.items():
        ok = sum(r["passed"] for r in rs)
        out.append(f"| {c} | {ok}/{len(rs)} | {100 * ok // len(rs)}% |")
    total = sum(r["passed"] for r in rows)
    out += [f"| **all** | **{total}/{len(rows)}** | **{100 * total // len(rows)}%** |", ""]
    if live:
        out += ["| Case | Outcome | Passed | Steps | Gemini calls | Seconds |", "|---|---|---|---|---|---|"]
        runs = [r for r in rows if "outcome" in r]        # extra checks have no run metrics
        for r in runs:
            out.append(f"| {r['name']} | {r['outcome']} | {'✅' if r['passed'] else '❌'} | "
                       f"{r['steps']} | {r['llm_calls']} | {r['seconds']} |")
        if runs:
            n = len(runs)
            out.append(f"| **average** | {sum(r['outcome'] == 'done' for r in runs)}/{n} verified | | "
                       f"{sum(r['steps'] for r in runs) / n:.1f} | {sum(r['llm_calls'] for r in runs) / n:.1f} | "
                       f"{sum(r['seconds'] for r in runs) / n:.1f} |")
        out.append("")
    out += ["<details><summary>All results</summary>", "",
            "| Category | Check | Result | Detail |", "|---|---|---|---|"]
    for r in rows:
        out.append(f"| {r['category']} | {r['name']} | {'✅' if r['passed'] else '❌'} | "
                   f"{r['detail'].replace('|', '/')} |")
    return out + ["", "</details>", ""]


def write_report(_=None):
    lines = ["# P-agent evaluation report", "",
             f"Generated {time.strftime('%Y-%m-%d %H:%M')}. "
             "Offline = PeTTa's rules under a scripted, adversarial Gemini. "
             "Live = real Gemini on fixed tasks with eval-only tools.", ""]
    lines += _section("Offline evaluation (safety, robustness, memory)", _load("offline"))
    lines += _section("Live evaluation (real Gemini)", _load("live"), live=True)
    path = os.path.join(HERE, "report.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return path


if __name__ == "__main__":
    print(write_report())
    rows = _load(sys.argv[1]) if len(sys.argv) > 1 else _load("offline")
    failed = [r for r in rows if not r["passed"]]
    print(f"{len(rows) - len(failed)}/{len(rows)} passed")
    for r in failed:
        print("  FAILED:", r["category"], r["name"], r["detail"])
