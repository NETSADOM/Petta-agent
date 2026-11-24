"""Error classification + backoff sleep for core/recovery.metta."""
import re
import time

# Failures that may succeed if tried again later. Everything else is permanent:
# retrying invalid input, a denied permission or a bad key can never help.
TEMPORARY = re.compile(
    r"(?i)timeout|timed out|unavailable|temporar|rate.?limit|too many requests|"
    r"\b429\b|\b50[0234]\b|connection (reset|refused|aborted)|network|try again|busy")


def classify(text):
    return "temporary" if TEMPORARY.search(str(text)) else "permanent"


def sleep(seconds):
    s = float(seconds)
    if s > 0:
        time.sleep(min(s, 30.0))      # never block longer than 30s
    return True
