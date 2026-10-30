"""Check SetNode/GetNode pairing in every real workflow fixture.

SetGet nodes are *frontend* virtual nodes: they never reach the server. A
GetNode resolves to the SetNode carrying the same `Constant` name in the same
graph scope. If a Get has no matching Set the workflow cannot be expanded, so
this script reports the pairing per workflow and per subgraph scope.
"""

import glob
import json
import sys

SET_TYPES = {"SetNode"}
GET_TYPES = {"GetNode"}


def constant_name(node):
    named = node.get("widgets_values_named")
    if isinstance(named, dict):
        value = named.get("Constant")
        if value is not None:
            return str(value)
    values = node.get("widgets_values")
    if isinstance(values, list) and values:
        return str(values[0])
    return None


def check_scope(label, nodes):
    sets = {}
    gets = []
    for node in nodes:
        kind = node.get("type")
        name = constant_name(node)
        if kind in SET_TYPES and name:
            sets.setdefault(name, []).append(node.get("id"))
        elif kind in GET_TYPES and name:
            gets.append((node.get("id"), name))

    missing = [(gid, name) for gid, name in gets if name not in sets]
    duplicated = {name: ids for name, ids in sets.items() if len(ids) > 1}
    unused = [name for name in sets if name not in {n for _, n in gets}]
    print(
        "  %-28s sets=%-3d gets=%-3d missing=%-2d dup=%-2d unused=%s"
        % (label, len(sets), len(gets), len(missing), len(duplicated), unused[:3])
    )
    for gid, name in missing[:5]:
        print("      MISSING set for Get id=%s name=%r" % (gid, name))
    for name, ids in list(duplicated.items())[:3]:
        print("      DUP set name=%r ids=%s" % (name, ids))
    return len(missing), len(duplicated)


def main():
    total_missing = 0
    for path in sorted(glob.glob("*.json")):
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        print(path)
        missing, _ = check_scope("root", data.get("nodes") or [])
        total_missing += missing
        for sub in (data.get("definitions") or {}).get("subgraphs") or []:
            label = "subgraph:" + str(sub.get("id"))[:8]
            missing, _ = check_scope(label, sub.get("nodes") or [])
            total_missing += missing
    print()
    print("TOTAL unresolved GetNode targets:", total_missing)
    return 0 if total_missing == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
