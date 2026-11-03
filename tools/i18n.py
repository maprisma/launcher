#!/usr/bin/env python3
"""Build flutter_app/assets/translations/<code>.json.

Keys: every tr('…') / trf('…', …) / trn('one', 'other', …) text in
flutter_app/lib, plus the texts the core sends in English (DYNAMIC).
Translations: the Omarchy plugin's built-in tables (reference/omarchy-plugin/
i18n.py, made with ~/Projects/omarchy-plugin-i18n), then i18n/extra.json for
texts only App Manager has (it wins). Prints what is still missing; exit 1
when anything is (or with --check, when the files are not up to date).

  tools/i18n.py           write the files
  tools/i18n.py --check   compare only
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "flutter_app" / "lib"
OUT = ROOT / "flutter_app" / "assets" / "translations"
EXTRA = ROOT / "i18n" / "extra.json"
LANGS = ("de", "fr", "es", "it", "pt", "nl", "pl")
PLURAL = "\x04"

# Texts the core sends (English) or the UI picks from a table.
DYNAMIC = [
    "Office", "Internet", "Media", "Graphics", "Development", "Games", "System", "Utilities",
    "Your default apps", "Flatpak", "Your own", "Comes with Omarchy", "Other",
    "Command-line tool, opens in a terminal",
    "Enter a name.", "A group with this name exists already.", "That is the most groups there can be.",
    "Too many entries.",
]

_STR = r"""(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")"""
_TR = re.compile(r"\btrf?\(\s*" + _STR)
_TRN = re.compile(r"\btrn\(\s*" + _STR + r"\s*,\s*" + _STR)


def _unescape(text):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text)


def keys():
    plain, plural = set(DYNAMIC), set()
    for path in sorted(LIB.glob("*.dart")):
        source = path.read_text(encoding="utf-8")
        for m in _TR.finditer(source):
            plain.add(_unescape(m.group(1) if m.group(1) is not None else m.group(2)))
        for m in _TRN.finditer(source):
            plural.add(_unescape(m.group(1) if m.group(1) is not None else m.group(2)))
    return sorted(plain), sorted(plural)


def tables():
    sys.path.insert(0, str(ROOT / "reference" / "omarchy-plugin"))
    import i18n  # the plugin's tables; plain data, no side effects
    base = {lang: dict(i18n.STRINGS.get(lang, {})) for lang in LANGS}
    extra = json.loads(EXTRA.read_text(encoding="utf-8")) if EXTRA.exists() else {}
    for lang in LANGS:
        base[lang].update(extra.get(lang, {}))
    return base


def placeholders(text):
    return sorted(re.findall(r"\{\d+\}", text))


def build():
    plain, plural = keys()
    found = tables()
    files, missing = {}, {}
    for lang in LANGS:
        table, out, lost = found[lang], {}, []
        for key in plain:
            value = table.get(key)
            if isinstance(value, str) and placeholders(value) == placeholders(key):
                out[key] = value
            else:
                lost.append(key)
        for one in plural:
            forms = table.get(PLURAL + one)
            want = 3 if lang == "pl" else 2
            if isinstance(forms, list) and len(forms) == want and all(placeholders(f) == placeholders(one) for f in forms):
                out[PLURAL + one] = forms
            else:
                lost.append("[plural] " + one)
        files[lang] = out
        missing[lang] = lost
    return files, missing


def main(argv):
    files, missing = build()
    stale = []
    for lang, table in files.items():
        text = json.dumps(table, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
        path = OUT / f"{lang}.json"
        if "--check" in argv:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(lang)
        else:
            OUT.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    total = sum(len(v) for v in missing.values())
    for lang, lost in missing.items():
        for key in lost:
            print(f"missing {lang}: {key}")
    if stale:
        print("not up to date:", ", ".join(stale))
    print(f"{len(files['de'])} texts per language, {total} missing")
    return 1 if total or stale else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
