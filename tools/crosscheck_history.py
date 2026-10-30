"""Cross-check the expander against prompts ComfyUI actually executed.

`/history` keeps, for every finished job, the exact API prompt it ran and the
UI workflow it came from:

    prompt[2]           -> {execId: {class_type, inputs}}  (the true expansion)
    prompt[3].extra_pnginfo.workflow -> the UI graph that produced it

Those two together are ground truth for the expander. This script replays the
saved UI graph through our own client (the Dart expander is exercised by
`test/real_workflows_test.dart`) and reports where the two disagree, which is
the only way to catch a rule that is subtly wrong rather than merely crashing.

Usage:  py tools/crosscheck_history.py [--limit N]
"""

import json
import sys
import urllib.error
import urllib.request

BASE = "http://180.175.160.80:1234"
KEY = "sk-comfy-9ca9becf1f714013dd8bafc299469f09"

VIRTUAL = {
    "SetNode",
    "GetNode",
    "Reroute",
    "PrimitiveNode",
    "Note",
    "MarkdownNote",
}


def get(path):
    request = urllib.request.Request(BASE + path, headers={"X-Api-Key": KEY})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        return {"_status": error.code, "_body": error.read().decode("utf-8", "replace")}


def main():
    limit = 20
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    jobs = get("/api/jobs?limit=%d&status=completed" % limit)
    ids = [job["id"] for job in jobs.get("jobs", [])]
    print("inspecting %d completed jobs" % len(ids))

    interesting = 0
    for job_id in ids:
        history = get("/history/" + job_id)
        for prompt_id, entry in history.items():
            if prompt_id.startswith("_"):
                continue
            packed = entry.get("prompt")
            if not isinstance(packed, list) or len(packed) < 4:
                continue
            executed = packed[2]
            if not isinstance(executed, dict) or not executed:
                continue
            workflow = (packed[3].get("extra_pnginfo") or {}).get("workflow")
            if not isinstance(workflow, dict):
                continue

            classes = {node.get("class_type") for node in executed.values()}
            leaked = classes & VIRTUAL
            nodes = workflow.get("nodes") or []
            subgraphs = (workflow.get("definitions") or {}).get("subgraphs") or []

            interesting += 1
            print(
                "\n%s  ui_nodes=%-3d subgraphs=%-2d executed=%-3d leaked_virtual=%s"
                % (prompt_id[:8], len(nodes), len(subgraphs), len(executed), leaked or "-")
            )
            for exec_id, node in sorted(executed.items()):
                for name, value in sorted((node.get("inputs") or {}).items()):
                    if isinstance(value, list) and len(value) == 2:
                        target = str(value[0])
                        if target not in executed:
                            print(
                                "    %s.%s -> %s MISSING (class %s)"
                                % (exec_id, name, target, node.get("class_type"))
                            )
            # Show which classes the UI graph declares but the prompt lacks.
            ui_classes = {node.get("type") for node in nodes}
            print("    ui classes: %s" % sorted(c for c in ui_classes if c))

    print("\n%d jobs carried both a prompt and its workflow" % interesting)


if __name__ == "__main__":
    main()
