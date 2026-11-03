#!/usr/bin/env python3
"""The reference's answers for the Dart core's tests; run with -I and the
fixture's environment.

  oracle.py scan              the app list (gnome-launcher parse_desktop_files)
  oracle.py groups < ops.json run group operations, print each result
  oracle.py origins [omarchy] origin of every scanned app, default apps
  oracle.py layout < cases    wide-window sizes (launcher.py) for each case
  oracle.py marks < spec      newapps, update parsing, process names, uninstall plans
  oracle.py facts             details.app_facts of every scanned app
  oracle.py icons < spec      icons.py: index entries, score, search, looks_like, tint
  oracle.py windows < clients the Omarchy plugin: app_window_classes, client_matches_app, lua_string
"""
import json
import sys
from pathlib import Path

REF = Path(__file__).resolve().parent.parent / "reference"
sys.dont_write_bytecode = True


def use(name):
    sys.path.insert(0, str(REF / name))


def run_groups(spec):
    """spec: {"data": raw page or null, "apps": [...], "ops": [[name, args...]]}."""
    import groups
    data = groups._clean_page(spec.get("data"), "apps")
    apps = spec.get("apps", [])
    out = []
    for name, *args in spec["ops"]:
        try:
            if name == "sections":
                result = [[gid, [a["desktop_id"] for a in members]]
                          for gid, members in groups.sections(apps, data)]
            elif name == "group_of":
                result = [groups.group_of(a, data) for a in apps]
            elif name == "place":
                desktop_id, gid, target, after = args
                ids = [a["desktop_id"] for a in dict(groups.sections(apps, data)).get(gid, [])]
                groups.place(data, desktop_id, gid, target, ids, after)
                result = None
            elif name == "clean_name":
                result = groups.clean_name(args[0])
            else:
                result = getattr(groups, name)(data, *args)
        except ValueError as error:
            result = {"error": str(error)}
        out.append(result)
    return {"results": out, "data": data}


def main(argv):
    if argv[1:] == ["scan"]:
        use("gnome-launcher")
        import launcher_core
        print(json.dumps(launcher_core.parse_desktop_files()))
        return 0
    if argv[1:] == ["groups"]:
        use("gnome-launcher")
        print(json.dumps(run_groups(json.load(sys.stdin))))
        return 0
    if argv[1:2] == ["origins"]:
        omarchy = argv[2:] == ["omarchy"]
        use("gnome-launcher")
        import launcher_core
        apps = launcher_core.parse_desktop_files()
        if omarchy:
            sys.path.insert(0, str(REF / "omarchy-plugin"))
            for mod in ("details", "groups", "i18n", "cli_tools", "corners", "desktop"):
                sys.modules.pop(mod, None)
            import details
            index = details.omarchy_index()
            defaults = details.default_desktops()
            origin = {a["desktop_id"]: details.origin_section(a, index, defaults) for a in apps}
        else:
            import details
            defaults = details.default_desktops()
            origin = {a["desktop_id"]: details.origin_section(a, defaults) for a in apps}
        roles = {a["desktop_id"]: details.default_roles(a) for a in apps}
        print(json.dumps({"defaults": sorted(defaults), "origin": origin, "roles": roles}))
        return 0
    if argv[1:] == ["marks"]:
        use("gnome-launcher")
        import newapps, updates, details, launcher_core
        spec = json.load(sys.stdin)
        out = {}
        data = newapps.empty()
        steps = []
        for ids, now, installed in spec["notes"]:
            changed = newapps.note(data, ids, "apps", now=now, installed=installed)
            steps.append([changed, json.loads(json.dumps(data)),
                          {k: newapps.is_new(data, k, now=now) for k in ids}])
        steps.append(newapps.opened(data, spec["opened"]))
        out["notes"] = steps
        out["updates"] = {k: list(v) for k, v in updates.parse_update_lines(spec["update_text"]).items()}
        out["owners"] = updates.parse_owner_lines(spec["owner_text"])
        out["flatpaks"] = updates.parse_flatpak_lines(spec["flatpak_text"])
        apps = launcher_core.parse_desktop_files()
        out["apps"] = {a["desktop_id"]: [launcher_core.terminal_command(dict(a)), launcher_core.app_process_name(a),
                                         list(details.uninstall_plan(a, look_up_package=False) or []) or None]
                       for a in apps}
        print(json.dumps(out))
        return 0
    if argv[1:] == ["windows"]:
        use("gnome-launcher")
        import launcher_core as glc
        apps = glc.parse_desktop_files()
        sys.path.insert(0, str(REF / "omarchy-plugin"))
        for mod in ("launcher_core", "i18n", "cli_tools", "corners", "desktop", "shortcuts"):
            sys.modules.pop(mod, None)
        import desktop_omarchy
        sys.modules["desktop_omarchy"] = desktop_omarchy
        import launcher_core as olc
        clients = json.load(sys.stdin)
        print(json.dumps({
            "classes": {a["desktop_id"]: sorted(c.casefold() for c in olc.app_window_classes(a) if c) for a in apps},
            "matches": {a["desktop_id"]: [bool(olc.client_matches_app(c, a)) for c in clients] for a in apps},
            "lua": [desktop_omarchy.lua_string(t) for t in ["a", "x\"); os.exit(\"", "ü\n"]],
        }))
        return 0
    if argv[1:] == ["icons"]:
        use("gnome-launcher")
        import icons
        spec = json.load(sys.stdin)
        entries = []
        for key, data in spec["indexes"].items():
            entries += icons.index_entries(key, data)
        print(json.dumps({
            "entries": [[c, s, u, k, n] for c, s, u, k, n in entries],
            "search": [[list(x) for x in icons.search(q, cmd, entries)] for q, cmd in spec["queries"]],
            "scores": [icons.score(q, names) for q, names in spec["scores"]],
            "looks": [icons.looks_like(bytes(d, "latin-1"), k) for d, k in spec["looks"]],
            "tint": icons.tint(b'<svg viewBox="0 0 1 1"><path/></svg>', "#aabbcc").decode(),
        }))
        return 0
    if argv[1:] == ["facts"]:
        use("gnome-launcher")
        import details, launcher_core
        print(json.dumps({a["desktop_id"]: details.app_facts(a) for a in launcher_core.parse_desktop_files()}))
        return 0
    if argv[1:] == ["layout"]:
        use("gnome-launcher")
        import launcher as L
        out = []
        for count, width, height, icon, percent in json.load(sys.stdin):
            columns, fitted = L.folder_fit(count, width, height)
            out.append([L.grid_columns(width), L.icon_columns(width, icon), L.folder_columns(width),
                        [columns, fitted], L.folder_icons_height(count, columns, fitted, height),
                        L.folder_app_icon(fitted, percent), list(L.folder_tile_size(fitted))])
        print(json.dumps(out))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
