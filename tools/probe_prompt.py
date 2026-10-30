"""Prove how a GetNode with no matching SetNode resolves.

Hypothesis under test
---------------------
ComfyUI's frontend drops SetNode/GetNode from the prompt. A GetNode resolves
to the producer of the input its matching SetNode is fed from. The Qwen
workflows on the remote instance contain GetNode(CLIP), GetNode(模型) and
GetNode(VAE) with **no** SetNode of those names anywhere in the file, while
subgraph 867 exposes CLIP / VAE / MODEL as its three outputs.

If the frontend drops virtual nodes and lets ComfyUI's `/prompt` validation
decide, submitting the *unresolved* prompt must fail with a node_errors entry
naming those consumers. That distinguishes "resolution is purely a frontend
concern" from "the server also understands these nodes".
"""

import json
import urllib.error
import urllib.request

BASE = "http://180.175.160.80:1234"
KEY = "sk-comfy-9ca9becf1f714013dd8bafc299469f09"


def post_prompt(prompt, extra=None):
    body = {"prompt": prompt, "client_id": "wuxianhuabu-probe"}
    if extra:
        body.update(extra)
    data = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        BASE + "/prompt",
        data=data,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        payload = error.read()
        try:
            return error.code, json.loads(payload or b"{}")
        except ValueError:
            return error.code, {"raw": payload.decode("utf-8", "replace")}


def main():
    # A deliberately tiny graph: one producer and one consumer that we keep
    # dangling, to read the validator's error shape.
    dangling = {
        "1": {
            "class_type": "EmptyLatentImage",
            "inputs": {"width": 64, "height": 64, "batch_size": 1},
        },
        "2": {
            "class_type": "PreviewImage",
            "inputs": {"images": ["999", 0]},
        },
    }
    status, payload = post_prompt(dangling)
    print("dangling link =>", status)
    print(json.dumps(payload, ensure_ascii=False)[:900])

    # Does the server accept a class_type it has never heard of? If yes, then a
    # virtual node left in the prompt would be a silent no-op rather than an
    # error, which changes how strict the expander must be.
    unknown = {
        "1": {"class_type": "GetNode", "inputs": {"Constant": "CLIP"}},
    }
    status, payload = post_prompt(unknown)
    print()
    print("unknown class_type =>", status)
    print(json.dumps(payload, ensure_ascii=False)[:900])


if __name__ == "__main__":
    main()
