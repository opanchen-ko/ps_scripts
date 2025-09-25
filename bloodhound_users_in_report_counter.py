#!/usr/bin/env python3
"""
count_bloodhound.py

Рахує кількість користувачів і груп у звітах BloodHound (підтримує .json, .json.gz, .zip та директорії).

Приклад:
    python count_bloodhound.py users.json
    python count_bloodhound.py /path/to/reports --csv summary.csv
"""

import json
import os
import sys
import argparse
import gzip
import zipfile
from collections import Counter, defaultdict
from typing import Any, Dict, Iterable, List, Tuple

def load_json_from_path(path: str) -> Iterable[Any]:
    """Yield parsed JSON top-level objects from a file (handles .json, .json.gz, .zip)."""
    if os.path.isdir(path):
        # yield from each file in dir
        for fname in sorted(os.listdir(path)):
            fpath = os.path.join(path, fname)
            yield from load_json_from_path(fpath)
        return

    if path.lower().endswith(".gz"):
        with gzip.open(path, "rt", encoding="utf-8") as f:
            yield json.load(f)
    elif path.lower().endswith(".zip"):
        with zipfile.ZipFile(path, "r") as z:
            for name in z.namelist():
                if name.lower().endswith(".json"):
                    with z.open(name) as f:
                        text = f.read().decode("utf-8")
                        yield json.loads(text)
    else:
        # assume json
        with open(path, "r", encoding="utf-8") as f:
            try:
                yield json.load(f)
            except json.JSONDecodeError as e:
                # try to be tolerant: maybe file contains multiple JSON objects per line
                f.seek(0)
                objs = []
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        objs.append(json.loads(line))
                    except Exception:
                        # fallback: skip
                        pass
                if objs:
                    for o in objs:
                        yield o
                else:
                    raise e

def iter_nodes_from_parsed(obj: Any) -> Iterable[Dict]:
    """
    Given a parsed JSON object try to iterate over 'nodes'/'data'/top-level list etc.
    Yield individual node dicts.
    """
    if isinstance(obj, list):
        for item in obj:
            if isinstance(item, dict):
                yield item
    elif isinstance(obj, dict):
        # common BloodHound exports use 'nodes' or 'data'
        for key in ("nodes", "data", "objects", "entries", "Items"):
            if key in obj and isinstance(obj[key], list):
                for item in obj[key]:
                    yield item
                return
        # Some exports wrap nodes in nested structure: {"graph": {"nodes": [...]}}
        # try to find first list of dicts in values
        for v in obj.values():
            if isinstance(v, list) and v and isinstance(v[0], dict):
                for item in v:
                    yield item
                return
        # if dict itself looks like a single node
        yield obj
    else:
        return

def detect_type(node: Dict) -> str:
    """
    Heuristics to determine whether node is 'user', 'group', or 'other'.
    Returns lowercase 'user'|'group'|'other'.
    """
    # normalize keys to lower for checks
    keys = {k.lower(): k for k in node.keys()}

    # 1) explicit type fields
    for type_field in ("type", "objecttype", "object_type", "label", "labels"):
        if type_field in keys:
            val = node[keys[type_field]]
            # labels may be a list
            if isinstance(val, list):
                vstr = " ".join(map(str, val)).lower()
            else:
                vstr = str(val).lower()
            if "user" in vstr:
                return "user"
            if "group" in vstr:
                return "group"

    # 2) objectClass / objectclass
    for oc in ("objectclass", "objectClass", "object_class"):
        if oc in node:
            v = node[oc]
            if isinstance(v, list):
                v = " ".join(v).lower()
            else:
                v = str(v).lower()
            if "group" in v:
                return "group"
            if "user" in v:
                return "user"

    # 3) properties sub-dict (BloodHound style uses 'Properties' or 'properties')
    props = None
    for pkey in ("Properties", "properties", "props"):
        if pkey in node:
            props = node[pkey]
            break
    if isinstance(props, dict):
        pl = {k.lower(): v for k, v in props.items()}

        # common user attributes
        user_indicators = ("samaccountname", "mail", "email", "displayname", "userprincipalname", "pwdlastset")
        for u in user_indicators:
            if u in pl:
                return "user"

        # group indicators
        group_indicators = ("groupType", "grouptype", "memberof", "member", "members", "primarygroupid")
        for g in group_indicators:
            if g.lower() in pl:
                return "group"

        # distinguishedname - try parse CN value
        dn = pl.get("distinguishedname") or pl.get("distinguishedName") or pl.get("dn")
        if isinstance(dn, str):
            # CN=Something,OU=...
            if dn.lower().find("cn=") >= 0:
                # take CN value after CN=
                first = dn.split(",")[0]
                if "=" in first:
                    cn_val = first.split("=", 1)[1].strip().lower()
                    # heuristics: group names often include 'group' or 'grp' or end with 'g_'
                    if "group" in cn_val or cn_val.startswith("g-") or cn_val.endswith("group") or cn_val.endswith("grp") or cn_val.endswith("_g"):
                        return "group"
                    # else likely user
                    return "user"

    # 4) serviceprincipalnames -> usually for service accounts (users)
    if "serviceprincipalnames" in keys or "serviceprincipalname" in keys or "serviceprincipalnames" in (k.lower() for k in node.keys()):
        return "user"

    # 5) samaccounttype (if present, numeric)
    for sat in ("samaccounttype", "samAccountType"):
        if sat in node:
            try:
                v = int(node[sat])
                # SAM account type constants (some common): 268435456 (SAM_DOMAIN_OBJECT) etc.
                # Users/groups values vary; heuristic: 268435456..? skip reliable mapping
            except Exception:
                pass

    # fallback: look at name-like fields
    name_fields = []
    for k in ("name", "Name", "properties", "label"):
        if k in node and isinstance(node[k], (str,)):
            name_fields.append(node[k])
    # if we've seen 'members' key, treat group
    for k in node.keys():
        if k.lower().startswith("member"):
            return "group"

    # last resort: try to decide from "id" or "objectidentifier" containing "S-1-5-21" suffix and common RIDs:
    oid = node.get("ObjectIdentifier") or node.get("objectidentifier") or node.get("objectId") or node.get("objectid")
    if isinstance(oid, str) and oid.startswith("S-1-5-21-"):
        # can't reliably say; return other
        return "other"

    return "other"

def extract_name(node: Dict) -> str:
    """Extract best-effort readable name for display."""
    for key in ("Name", "name", "properties", "Properties", "label", "displayName", "displayname", "samaccountname", "sAMAccountName"):
        if key in node:
            val = node[key]
            if isinstance(val, str):
                return val
            if isinstance(val, dict):
                # prefer common props
                for sub in ("displayName", "displayname", "name", "distinguishedname", "sAMAccountName"):
                    if sub in val:
                        return str(val[sub])
    # try object identifier
    for key in ("ObjectIdentifier", "objectidentifier", "objectId"):
        if key in node:
            return str(node[key])
    # fallback: entire json snippet truncated
    try:
        return json.dumps(node)[:80].replace("\n", " ")
    except Exception:
        return "<unknown>"

def process_paths(paths: List[str]) -> Tuple[Counter, Dict[str, List[str]]]:
    counts = Counter()
    examples = defaultdict(list)  # type -> list of names
    for path in paths:
        if not os.path.exists(path):
            print(f"Warning: path not found: {path}", file=sys.stderr)
            continue
        for parsed in load_json_from_path(path):
            for node in iter_nodes_from_parsed(parsed):
                if not isinstance(node, dict):
                    continue
                typ = detect_type(node)
                if typ not in ("user", "group"):
                    # some BloodHound exports store nodes as {"labels": ["User"], "properties": {...}}
                    # try alternate: if labels exist and contain 'user' or 'group' - handled earlier.
                    # ignore 'other'
                    continue
                counts[typ] += 1
                if len(examples[typ]) < 10:
                    examples[typ].append(extract_name(node))
    return counts, examples

def main():
    p = argparse.ArgumentParser(description="Count users and groups in BloodHound JSON exports.")
    p.add_argument("paths", nargs="+", help="File or directory paths (json, .json.gz, .zip supported).")
    p.add_argument("--csv", help="Write simple CSV summary: path,count_users,count_groups")
    args = p.parse_args()

    counts, examples = process_paths(args.paths)

    users = counts.get("user", 0)
    groups = counts.get("group", 0)

    print("==== Summary ====")
    print(f"Files scanned: {len(args.paths)}")
    print(f"Users found : {users}")
    print(f"Groups found: {groups}")
    print()
    if examples.get("user"):
        print("Example users:")
        for e in examples["user"]:
            print("  -", e)
    if examples.get("group"):
        print("Example groups:")
        for e in examples["group"]:
            print("  -", e)

    if args.csv:
        import csv
        with open(args.csv, "w", newline="", encoding="utf-8") as cf:
            w = csv.writer(cf)
            w.writerow(["path", "users", "groups"])
            # simple: for each provided path call process_paths individually (so file-level counts)
            for pth in args.paths:
                cts, _ex = process_paths([pth])
                w.writerow([pth, cts.get("user", 0), cts.get("group", 0)])
        print(f"\nWrote CSV summary to {args.csv}")

if __name__ == "__main__":
    main()
