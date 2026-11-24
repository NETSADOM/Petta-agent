"""TEST FIXTURE: a tiny local OpenAI-compatible server (/v1/chat/completions).

Real HTTP, so the real client (core/openai_compat.py) is exercised end to end.
    model "missing-model" → 404,  "rate" → 429,  "broken" → 500
    model "tool-caller"   → native tool_calls reply
    otherwise             → next queued reply (queue_replies), else "(final \"hi\")"
Requires header  Authorization: Bearer test-key
"""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"queue": [], "requests": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        STATE["requests"].append(req)
        if self.path != "/v1/chat/completions":
            return self._send(404, {"error": {"message": "unknown path"}})
        if self.headers.get("Authorization") != "Bearer test-key":
            return self._send(401, {"error": {"message": "Incorrect API key provided"}})
        model = req.get("model")
        if model == "missing-model":
            return self._send(404, {"error": {"message": "The model does not exist"}})
        if model == "rate":
            return self._send(429, {"error": {"message": "Rate limit reached"}})
        if model == "broken":
            return self._send(500, {"error": {"message": "internal"}})
        if model == "tool-caller":
            msg = {"role": "assistant", "content": None, "tool_calls": [{
                "id": "c1", "type": "function",
                "function": {"name": "calc", "arguments": json.dumps({"expression": "2+3"})}}]}
        else:
            text = STATE["queue"].pop(0) if STATE["queue"] else '(final "hi")'
            msg = {"role": "assistant", "content": text}
        self._send(200, {"choices": [{"index": 0, "message": msg, "finish_reason": "stop"}]})


def start(_=None):
    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    os.environ["OPENAI_BASE_URL"] = f"http://127.0.0.1:{server.server_port}/v1"
    return server.server_port


def queue_replies(replies):
    STATE["queue"] = [str(r) for r in replies]
    return len(STATE["queue"])


def last_request_roles(_=None):
    msgs = STATE["requests"][-1]["messages"]
    return [m["role"] for m in msgs]


def last_system_has(text):
    msgs = STATE["requests"][-1]["messages"]
    return str(text) in msgs[0]["content"]


def set_env(name, value):
    os.environ[str(name)] = str(value)
    return True


def unset_env(name):
    os.environ.pop(str(name), None)
    return True
