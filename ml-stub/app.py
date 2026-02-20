"""
Fake ML inference endpoint: tensor ops stub for Project 5.
POST /infer with JSON body {"input": [1, 2, 3]} returns a dummy "inference" result.
"""
import os
from flask import Flask, request, jsonify

app = Flask(__name__)

try:
    import torch
    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False


@app.route("/healthz")
def healthz():
    return "ok", 200


@app.route("/infer", methods=["POST"])
def infer():
    """Stub: run a tiny tensor op and return a fake result."""
    data = request.get_json(silent=True) or {}
    inp = data.get("input", [1.0, 2.0, 3.0])
    if not isinstance(inp, list):
        inp = [float(inp)]

    if HAS_TORCH:
        t = torch.tensor(inp, dtype=torch.float32)
        # Minimal tensor op (CPU)
        out = t.sum().item()
        device = str(t.device)
    else:
        out = sum(inp)
        device = "cpu (no torch)"

    return jsonify({
        "output": out,
        "device": device,
        "backend": "torch" if HAS_TORCH else "fallback",
    })


@app.route("/")
def index():
    return jsonify({
        "service": "ml-stub",
        "endpoints": ["GET /healthz", "POST /infer"],
        "torch": HAS_TORCH,
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    app.run(host="0.0.0.0", port=port)
