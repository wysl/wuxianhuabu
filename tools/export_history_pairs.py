"""Export executed UI→API pairs from `/history` as a regression corpus.

Each record pairs the UI workflow the user saved with the API prompt ComfyUI
actually ran. That is the only objective oracle for the expander: a corpus of
shapes it must reproduce exactly, rather than shapes it merely survives.

Writes tools/fixtures/history/pairs.json:
    [{"id": ..., "workflow": {...}, "executed": {...}}, ...]
"""

import json
import os
import urllib.error
import urllib.request

BASE = "http://180.175.160.80:1234"
KEY = "sk-comfy-9ca9becf1f714013dd8bafc299469f09"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "history")


def get(path):
    request = urllib.request.Request(BASE + path, headers={"X-Api-Key": KEY})
    with urllib.request.urlopen(request, timeout=90) as response:
        return json.loads(response.read())


def main():
    os.makedirs(OUT, exist_ok=True)
    jobs = get("/api/jobs?limit=200&status=completed")
    pairs = []
    seen_workflows = set()

    for job in jobs.get("jobs", []):
        try:
            history = get("/history/" + job["id"])
        except Exception as exc:  # noqa: BLE001 - skip unreadable entries
            print("skip %s: %s" % (job["id"], exc))
            continue
        for prompt_id, entry in history.items():
            if prompt_id.startswith("_"):
                continue
            packed = entry.get("prompt")
            if not isinstance(packed, list) or len(packed) < 4:
                continue
            executed = packed[2]
            workflow = (packed[3].get("extra_pnginfo") or {}).get("workflow")
            if not isinstance(executed, dict) or not executed:
                continue
            if not isinstance(workflow, dict) or not workflow.get("nodes"):
                continue

            # Deduplicate identical UI graphs: the same workflow was run many
            # times and only the parameter values differ.
            signature = json.dumps(
                [
                    (node.get("id"), node.get("type"), node.get("mode", 0))
                    for node in workflow["nodes"]
                ],
                sort_keys=True,
            )
            if signature in seen_workflows:
                continue
            seen_workflows.add(signature)

            pairs.append(
                {
                    "id": prompt_id,
                    "workflow": workflow,
                    "executed": executed,
                }
            )

    target = os.path.join(OUT, "pairs.json")
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(pairs, handle, ensure_ascii=False)
    print("wrote %d distinct pairs to %s" % (len(pairs), target))
    for pair in pairs:
        print(
            "  %-10s ui_nodes=%-3d executed=%-3d"
            % (pair["id"][:8], len(pair["workflow"]["nodes"]), len(pair["executed"]))
        )


if __name__ == "__main__":
    main()
