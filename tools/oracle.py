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
  oracle.py plugins           the Omarchy plugin's parse_plugins on this machine (reads only)
  oracle.py admin             gnome-launcher's admin_command for every scanned app
  oracle.py shortcuts < spec  both shortcuts.py: combos, states, COSMIC file, GNOME and Hyprland bindings
  oracle.py tray < spec       the Omarchy plugin's tray.py: menu nodes, find_quit, item_key, titles, labels
  oracle.py dock < spec       the Omarchy plugin's dock_core.py: settings, edge, sizes, dock_rect, inside,
                              indicator_color, split_events, pinned operations, dropped_id, items, bar_position
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


def load_module(name, path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeGSettings:
    """gnome-launcher's GSettings over a dict: {"bindings": {schema: {key:
    [accels]}}, "custom": {path: {name, command, binding}}, "paths": [...]}."""

    def __init__(self, db):
        self.db = db

    def available(self):
        return True

    def binding_keys(self):
        return [(schema, key, key, list(accels)) for schema, keys in self.db["bindings"].items()
                for key, accels in keys.items()]

    def get_strv(self, schema, key):
        return list(self.db["bindings"].get(schema, {}).get(key, []))

    def set_strv(self, schema, key, values):
        self.db["bindings"].setdefault(schema, {})[key] = list(values)

    def custom_paths(self):
        return list(self.db["paths"])

    def set_custom_paths(self, paths):
        self.db["paths"] = list(paths)

    def read_custom(self, path):
        values = self.db["custom"].get(path, {})
        return {k: values.get(k, "") for k in ("name", "command", "binding")}

    def write_custom(self, path, values):
        self.db["custom"].setdefault(path, {}).update(values)

    def reset_custom(self, path):
        self.db["custom"].pop(path, None)

    def sync(self):
        pass


def run_shortcuts(spec):
    import shlex
    import tempfile
    gl = load_module("gl_shortcuts", REF / "gnome-launcher/shortcuts.py")
    om = load_module("om_shortcuts", REF / "omarchy-plugin/shortcuts.py")
    # The Python launch helper has no Dart twin: both sides write the argv.
    gl.shortcut_command = lambda launch, action="": shlex.join([*launch, *([action] if action else [])])
    out = {}
    c = spec["combos"]
    out["make"] = [[gl.make_combo(m, k), om.make_combo(m, k, t)] for m, k, t in c["make"]]
    out["accels"] = [[(p := gl.parse_accelerator(t)), p and gl.accelerator(p), p and gl.combo_label(p),
                      p and list(gl.combo_id(p))] for t in c["accels"]]
    out["hypr"] = [[(p := om.parse_combo(t)), p and om.combo_string(p), p and om.combo_label(p)] for t in c["hypr"]]
    # The Omarchy plugin's key_label lacks GNOME's Page Up/Down and Above Tab.
    gnome_only = ("PAGE_UP", "PAGE_DOWN", "ABOVE_TAB")
    out["labels"] = [[gl.key_label(k), gl.key_label(k) if k.upper() in gnome_only else om.key_label(k)]
                     for k in c["keys"]]
    out["collides"] = [om.collides(a, b) for a, b in c["pairs"]]
    out["private"] = [om.private_action(a) for a in spec["apps"]]

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        path = tmp / "state.json"
        out["gnome_states"] = []
        for data in spec["gnome_states"]:
            path.write_text(json.dumps(data))
            out["gnome_states"].append(gl.load_state(path))
        om.STATE_FILE = path
        out["hypr_states"] = []
        for data in spec["hypr_states"]:
            path.write_text(json.dumps(data))
            out["hypr_states"].append(om.load_state())

        # COSMIC: parsing, then saves through CosmicSettings, file by file.
        parsed = []
        for text in spec["cosmic_texts"]:
            try:
                head, entries, tail = gl.parse_cosmic_shortcuts(text)
                parsed.append([head, [{k: e[k] for k in ("gap", "raw", "combo", "action", "description")}
                                      for e in entries], tail])
            except ValueError as error:
                parsed.append({"error": str(error)})
        out["cosmic_parse"] = parsed
        cosmic = spec["cosmic"]
        config = tmp / "cosmic"
        config.mkdir()
        if cosmic["custom"] is not None:
            (config / "custom").write_text(cosmic["custom"])
        (tmp / "defaults").write_text(cosmic["defaults"])
        gl.COSMIC_OWN_TAG = " (Launcher)"
        state_file = tmp / "cosmic-state.json"
        steps = []
        for state in cosmic["states"]:
            settings = gl.CosmicSettings(config_dir=config, defaults_file=tmp / "defaults", taken_file=tmp / "taken.json")
            desktop = gl.read_desktop_binds(settings)
            custom = gl.read_custom_binds(settings)
            gl.save_and_apply(state, settings=settings, path=state_file)
            steps.append({"desktop": desktop, "custom": custom, "file": (config / "custom").read_text(),
                          "taken": json.loads((tmp / "taken.json").read_text()),
                          "state": json.loads(state_file.read_text())})
        out["cosmic_steps"] = steps

        # GNOME: bindings and saves on a fake GSettings.
        g = spec["gnome"]
        fake = FakeGSettings(json.loads(json.dumps(g["db"])))
        gnome_file = tmp / "gnome-state.json"
        gsteps = []
        for state in g["states"]:
            clean = gl.load_state(gnome_file)
            bindings = gl.Bindings(clean, desktop=gl.read_desktop_binds(fake), custom=gl.read_custom_binds(fake),
                                   favorites=g["favorites"], main_mods=g["main_mods"])
            gsteps.append(bindings_answers(bindings, spec["apps"], spec["queries"], gl))
            gl.save_and_apply(state, settings=fake, path=gnome_file)
            gsteps.append({"db": json.loads(json.dumps(fake.db)), "state": json.loads(gnome_file.read_text())})
        out["gnome_steps"] = gsteps

        # Hyprland: binds, files, bindings, the generated module.
        h = spec["hypr"]
        out["live"] = om.parse_live_binds(h["live"])

        def files(pairs, name):
            folder = tmp / name
            folder.mkdir()
            for file_name, text in pairs:
                (folder / file_name).write_text(text)
            return sorted(folder.glob("*.lua"))

        user = om.parse_user_binds(files(h["user"], "user"))
        defaults = om.parse_user_binds(files(h["defaults"], "omarchy-defaults"))[0]
        out["user"] = [user[0], sorted([list(x) for x in user[1]])]
        out["defaults"] = defaults
        out["strip"] = [om._strip_lua_comment(line) for line in h["lines"]]
        out["hypr_bindings"] = []
        for data in h["states"]:
            path.write_text(json.dumps(data))
            state = om.load_state()
            bindings = om.Bindings(state, live=out["live"], user=user, defaults=defaults,
                                   main_mods=h["main_mods"], default_apps=h["default_apps"])
            out["hypr_bindings"].append(bindings_answers(bindings, spec["apps"], spec["queries"], om))
            out["hypr_bindings"].append(om.render_lua(state))
    return out


def bindings_answers(bindings, apps, queries, module):
    """classify / external_shortcuts / suggestions of one snapshot."""
    return {
        "classify": [list(bindings.classify(combo, app_id, app=apps[index] if index is not None else None,
                                            action=action))
                     for combo, app_id, index, action in queries],
        "external": [bindings.external_shortcuts(app) for app in apps],
        "suggest": [[bindings.suggestions(app, module.app_key(app), mods) for mods in (None, ["SUPER", "ALT"])]
                    for app in apps],
        "taken_from": [bindings.taken_from(combo) for combo, *_ in queries] if hasattr(bindings, "taken_from")
        else None,
    }


def run_dock(spec):
    """dock_core's pure functions; the file operations on a temporary settings.json."""
    import tempfile
    sys.path.insert(0, str(REF / "omarchy-plugin"))
    import dock_core as d
    out = {}
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "settings.json"

        def settings_of(raw):
            path.write_text(json.dumps(raw))
            return d.settings(path)
        out["settings"] = [settings_of(raw) for raw in spec["settings"]]
        path.write_text(json.dumps(spec["file_start"]))
        steps = []
        for name, *args in spec["file_ops"]:
            try:
                if name == "set":
                    d.set_setting(args[0], args[1], path)
                elif name == "reset":
                    d.reset(path)
                elif name == "pin":
                    d.pin(args[0], path)
                elif name == "unpin":
                    d.unpin(args[0], path)
                elif name == "set_pinned":
                    d.set_pinned(args[0], path)
                error = None
            except (KeyError, ValueError) as e:
                error = type(e).__name__
            steps.append([error, d.settings(path), json.loads(path.read_text())])
        out["file_ops"] = steps
        shell = Path(tmp) / "shell.json"
        bars = []
        for text in spec["bars"]:
            if text is None:
                shell.unlink(missing_ok=True)
            else:
                shell.write_text(text)
            bars.append(d.bar_position(shell))
        out["bars"] = bars
    out["edges"] = [d.edge({"dock_position": pos}, bar) for pos, bar in spec["edges"]]
    out["sizes"] = [list(d.sizes({**d.DEFAULTS, **dock})) for dock in spec["sizes"]]
    out["rects"] = [(lambda r: [list(r[0]), list(r[1])] if r else None)(d.dock_rect(layers, monitors))
                    for layers, monitors in spec["rects"]]
    out["inside"] = [bool(d.inside(point, tuple(rect))) for point, rect in spec["inside"]]
    out["colors"] = [d.indicator_color(dock, colors) for dock, colors in spec["colors"]]
    out["new_window"] = [d.has_new_window_action(app) for app in spec["new_window"]]
    events = []
    for chunks, limit in spec["events"]:
        buffer, skipping, lines = b"", False, []
        for chunk in chunks:
            got, buffer, skipping = d.split_events(buffer, bytes(chunk), skipping, limit)
            lines.append(got)
        events.append([lines, list(buffer), skipping])
    out["events"] = events
    out["moves"] = [d.move_pinned(ids, i, t, a) for ids, i, t, a in spec["moves"]]
    out["inserts"] = [d.insert_pinned(ids, i, t, a) for ids, i, t, a in spec["inserts"]]
    out["drops"] = [d.dropped_id(bytes(x) if isinstance(x, list) else x) for x in spec["drops"]]
    items = spec["items"]
    out["clients"] = [c.get("address") for c in d.clients(run=lambda *a, **k: json.dumps(items["clients"]))]
    clients = d.clients(run=lambda *a, **k: json.dumps(items["clients"]))
    out["items"] = [[app["desktop_id"], [w.get("address") for w in windows], pinned]
                    for app, windows, pinned in d.items(items["apps"], items["pinned"], clients)]
    return out


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
    if argv[1:] == ["admin"]:
        use("gnome-launcher")
        import launcher_core
        print(json.dumps({a["desktop_id"]: launcher_core.admin_command(dict(a)) for a in launcher_core.parse_desktop_files()}))
        return 0
    if argv[1:] == ["plugins"]:
        sys.path.insert(0, str(REF / "omarchy-plugin"))
        import launcher_core as olc
        print(json.dumps([{k: p.get(k) for k in ("plugin_id", "name", "description", "bar_widget", "in_bar",
                                                  "openable", "removable", "category", "plugin_dir", "bar_section")}
                          for p in olc.parse_plugins() if not p.get("self_launcher")]))
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
    if argv[1:] == ["tray"]:
        sys.path.insert(0, str(REF / "omarchy-plugin"))
        import tray
        spec = json.load(sys.stdin)
        menus = [tray._menu_nodes(children) for children in spec["layouts"]]
        print(json.dumps({
            "menus": menus,
            "quit": [(tray.find_quit(m) or {}).get("id") for m in menus],
            "keys": [tray.item_key(raw, title, set(taken)) for raw, title, taken in spec["keys"]],
            "titles": [tray._title(props) for props in spec["titles"]],
            "labels": [tray.clean_label(x) for x in spec["labels"]],
        }))
        return 0
    if argv[1:] == ["dock"]:
        print(json.dumps(run_dock(json.load(sys.stdin))))
        return 0
    if argv[1:] == ["shortcuts"]:
        print(json.dumps(run_shortcuts(json.load(sys.stdin))))
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
