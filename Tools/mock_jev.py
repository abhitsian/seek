"""A stand-in for TypeSafe's /v1/systemone, for testing Seek without a key.

It rejects any request that breaks the documented schema (422), and answers with simple
word-overlap guesses so the ranking code has something realistic to sort.

    python3 Tools/mock_jev.py 8765
    TYPESAFE_ENDPOINT=http://127.0.0.1:8765 TYPESAFE_API_KEY=test build/Seek.app/Contents/MacOS/Seek --search "..."
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

FILLER = {"pdf", "pdfs", "from", "march", "last", "month", "week", "yesterday", "screenshots", "i", "downloaded", "in"}


def check(body):
    assert isinstance(body.get("model"), str), "model must be a string"
    assert "state" in body, "state is required"
    questions = body.get("questions")
    assert isinstance(questions, dict) and questions, "questions must be a nonempty map"
    for qid, q in questions.items():
        assert q.get("type") in ("noul", "choice", "score"), f"{qid}: bad type"
        assert isinstance(q.get("instructions"), (str, dict, list)), f"{qid}: instructions required"
        criteria = q.get("criteria")
        if q["type"] == "choice":
            assert isinstance(criteria, dict) and 1 <= len(criteria) <= 255, f"{qid}: choice needs 1-255 options"
            assert all(v is None or isinstance(v, (str, dict, list)) for v in criteria.values()), f"{qid}: bad option"
        elif q["type"] == "score":
            assert isinstance(criteria, list) and 2 <= len(criteria) <= 10, f"{qid}: score needs 2-10 levels"
        elif criteria is not None:
            assert set(criteria) <= {"true", "false"}, f"{qid}: noul criteria are true/false"


def words(text):
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def answer(qid, q, state):
    query = state.get("query") or state.get("search") or ""
    wanted = words(query) - FILLER
    if q["type"] == "noul":
        if qid.startswith("word"):
            word = re.search(r'the word "([^"]+)"', q["instructions"]).group(1).lower()
            return {"type": "noul", "noul": 0.1 if word in FILLER else 0.93}
        if qid.startswith("fit_"):
            line = state["files"][qid[4:]]
            overlap = len(wanted & words(line)) / max(1, len(wanted))
            return {"type": "noul", "noul": round(0.05 + 0.9 * overlap, 3)}
        return {"type": "noul", "noul": 0.88}
    options = list(q["criteria"])
    if qid == "kind" and "pdf" in query.lower():
        pick = "pdf"
    elif qid == "month" and "march" in query.lower():
        pick = "march"
    elif qid == "pick":
        scores = {k: len(wanted & words(state["files"][k])) for k in options if k in state.get("files", {})}
        pick = max(scores, key=scores.get) if scores else options[0]
    else:
        pick = next((o for o in options if o in ("any", "none", "anywhere", "best")), options[0])
    probabilities = {o: (0.9 if o == pick else 0.1 / max(1, len(options) - 1)) for o in options}
    return {"type": "choice", "choice": pick, "probabilities": probabilities, "confidence": 0.8}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        try:
            check(body)
        except AssertionError as error:
            self.reply(422, {"detail": [{"loc": ["body", "questions"], "msg": str(error)}]})
            return
        state = body["state"] if isinstance(body["state"], dict) else {"query": body["state"]}
        answers = {qid: answer(qid, q, state) for qid, q in body["questions"].items()}
        tokens = len(raw) // 4
        print(f"{len(body['questions'])} questions, ~{tokens} tokens", file=sys.stderr)
        self.reply(200, {"model": "jev-mock", "answers": answers, "usage": {"input_tokens": tokens, "output_tokens": 0}})

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8765), Handler).serve_forever()
