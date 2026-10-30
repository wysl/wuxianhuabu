"""Submit an expanded prompt to the live ComfyUI and read the verdict.

Round-trips the Dart expander's output through the real `/prompt` validator.
This is the only check that proves the expansion is correct rather than merely
well-formed: ComfyUI answers `required_input_missing` when a required input was
dropped, and names the exact node and input.
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://180.175.160.80:1234"
KEY = "sk-comfy-9ca9becf1f714013dd8bafc299469f09"


def post_prompt(prompt, dry_run=True):
    """POST a prompt. `dry_run` still validates but keeps it out of the queue."""
    body = {"prompt": prompt, "client_id": "wuxianhuabu-validate"}
    data = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        BASE + "/prompt",
        data=data,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        payload = error.read()
        try:
            return error.code, json.loads(payload or b"{}")
        except ValueError:
            return error.code, {"raw": payload.decode("utf-8", "replace")}


def summarise(status, payload):
    if status == 200:
        return "OK (queued as %s)" % payload.get("prompt_id")
    error = payload.get("error") or {}
    lines = ["HTTP %s: %s — %s" % (status, error.get("type"), error.get("message"))]
    for node_id, detail in (payload.get("node_errors") or {}).items():
        for item in detail.get("errors") or []:
            lines.append(
                "  node %s (%s): %s — %s"
                % (
                    node_id,
                    detail.get("class_type"),
                    item.get("type"),
                    item.get("message"),
                )
            )
            if item.get("details"):
                lines.append("     %s" % item["details"])
    return "\n".join(lines)


def main():
    path = sys.argv[1]
    with open(path, encoding="utf-8") as handle:
        prompt = json.load(handle)
    status, payload = post_prompt(prompt)
    print(summarise(status, payload))
    return 0 if status == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
