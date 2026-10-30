import json, os, sys, urllib.parse, urllib.request

BASE = "http://180.175.160.80:1234"
KEY = "sk-comfy-9ca9becf1f714013dd8bafc299469f09"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def get(path, params=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"X-Api-Key": KEY})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def listdir(rel):
    raw = get("/v2/userdata", {"path": rel})
    return json.loads(raw)


def walk(rel="workflows"):
    found = []
    for entry in listdir(rel):
        if entry["type"] == "directory":
            found.extend(walk(entry["path"]))
        elif entry["name"].lower().endswith(".json") and not entry["name"].startswith("."):
            found.append(entry)
    return found


def download(entry):
    rel = entry["path"]
    encoded = urllib.parse.quote(rel, safe="")
    data = get("/userdata/" + encoded)
    name = os.path.basename(rel)
    safe = name.replace(" ", "_")
    target = os.path.join(OUT, safe)
    with open(target, "wb") as handle:
        handle.write(data)
    return safe, len(data)


if __name__ == "__main__":
    entries = walk()
    print("found %d workflows" % len(entries))
    for entry in entries:
        try:
            name, size = download(entry)
            print("  %-46s %7d  <- %s" % (name, size, entry["path"]))
        except Exception as exc:
            print("  FAIL %s: %s" % (entry["path"], exc))
