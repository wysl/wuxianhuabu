"""Where do the unresolved GetNode targets actually live?

The previous check only looked inside a single scope. ComfyUI's SetNode and
GetNode are *graph-global* by name: a Get resolves to the nearest Set with the
same `Constant`, walking outward through the subgraph scopes. So a Get in the
root graph can legitimately reach a Set nested inside a subgraph, and vice
versa.

This script proves the direction of that resolution for the real fixtures: for
every root-level Get with a missing local Set, it searches the workflow
recursively and reports where the producer lives.
"""

import glob
import json


def constant_name(node):
    named = node.get("widgets_values_named")
    if isinstance(named, dict) and named.get("Constant") is not None:
        return str(named["Constant"])
    values = node.get("widgets_values")
    if isinstance(values, list) and values:
        return str(values[0])
    return None


def collect_sets(data):
    """Map constant name -> list of (scope_label, node)."""
    found = {}

    def walk(label, nodes):
        for node in nodes:
            if node.get("type") == "SetNode":
                name = constant_name(node)
                if name:
                    found.setdefault(name, []).append((label, node))

    walk("root", data.get("nodes") or [])
    for sub in (data.get("definitions") or {}).get("subgraphs") or []:
        walk("sub:" + str(sub.get("id"))[:8], sub.get("nodes") or [])
    return found


def main():
    for path in sorted(glob.glob("*.json")):
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        sets = collect_sets(data)
        root_gets = [
            n
            for n in data.get("nodes") or []
            if n.get("type") == "GetNode"
        ]
        unresolved = []
        for get in root_gets:
            name = constant_name(get)
            if not name:
                continue
            if name not in sets:
                unresolved.append((get.get("id"), name))
                continue
            where = [label for label, _ in sets[name]]
            print(
                "%-28s Get id=%-4s %-10r -> Set in %s"
                % (path[:28], get.get("id"), name, where)
            )
        for gid, name in unresolved:
            print("%-28s Get id=%-4s %-10r -> UNRESOLVED" % (path[:28], gid, name))


if __name__ == "__main__":
    main()
