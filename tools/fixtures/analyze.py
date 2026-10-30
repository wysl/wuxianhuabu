import json
import glob
import sys

for path in sorted(glob.glob("*.json")):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    nodes = data.get("nodes") or []
    subgraphs = (data.get("definitions") or {}).get("subgraphs") or []
    named = sum(1 for node in nodes if isinstance(node.get("widgets_values_named"), dict))
    modes = {}
    for node in nodes:
        mode = node.get("mode", 0)
        modes[mode] = modes.get(mode, 0) + 1
    titled = sum(1 for node in nodes if node.get("title"))
    print(
        "%-34s nodes=%-4d subgraphs=%-2d named=%-3d title=%-3d modes=%s"
        % (path[:34], len(nodes), len(subgraphs), named, titled, modes)
    )
