# The dock in a throwaway Omarchy VM (runs inside it over ssh, see tools/vm-dock).
set -u
echo omarchy | sudo -S mkdir -p /mnt/dist 2>/dev/null
echo omarchy | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro dist /mnt/dist 2>&1 | tail -1
D=/mnt/dist
ls "$D" | tr '\n' ' '; echo
export XDG_RUNTIME_DIR=/run/user/$(id -u)
for _ in $(seq 1 90); do
  ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -q '^wayland-[0-9]*$' && ls "$XDG_RUNTIME_DIR/hypr" >/dev/null 2>&1 && break
  sleep 1
done
sleep 8
export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -m1 '^wayland-[0-9]*$')
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)
cp -r "$D/bundle" /tmp/ml && B=/tmp/ml/maprisma-launcher
cp "$D/vp" /tmp/vp && chmod +x /tmp/vp
CONF=~/.config/maprisma-launcher
mkdir -p "$CONF"

# The monitor's logical size (W H), for the pointer helper and the expected layout.
read -r W H < <(hyprctl monitors -j | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; s=m["scale"]; print(round(m["width"]/s), round(m["height"]/s))')
echo "monitor $W x $H, bar position: $(python3 -c 'import json,os
try: print(json.load(open(os.path.expanduser("~/.config/omarchy/shell.json"))).get("bar",{}).get("position","top (default)"))
except Exception as e: print("top (no shell.json)")')"
layers() {
  hyprctl layers -j | python3 -c 'import json,sys
d=json.load(sys.stdin)
for mon,v in d.items():
    for lvl,ls in v.get("levels",{}).items():
        for l in ls:
            if l["namespace"] in ("maprisma-launcher-dock",) or "bar" in l["namespace"] or "shell" in l["namespace"]:
                print("  layer", mon, "level", lvl, l["namespace"], "x", l["x"], "y", l["y"], "w", l["w"], "h", l["h"])'
  hyprctl monitors -j | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print("  reserved (left, top, right, bottom):", m["reserved"])'
}
dockh() { hyprctl layers -j | python3 -c 'import json,sys
d=json.load(sys.stdin)
found=[l for v in d.values() for ls in v.get("levels",{}).values() for l in ls if l["namespace"]=="maprisma-launcher-dock"]
print(" ".join(str(found[0][k]) for k in ("y","h","x","w")) if found else "none")'; }
shot() { /tmp/vp <<<"size $W $H" >/dev/null 2>&1; grim "/tmp/shot-$1.png" 2>&1 | head -2; SHOTS="$SHOTS $1"; }
SHOTS=""
setting() { python3 - "$CONF/settings.json" "$@" <<'PY'
import json, os, sys
path, *pairs = sys.argv[1:]
try: d = json.load(open(path))
except Exception: d = {}
for pair in pairs:
    k, v = pair.split("=", 1)
    d[k] = json.loads(v)
tmp = path + ".tmp"
json.dump(d, open(tmp, "w"), indent=2)
os.replace(tmp, path)
PY
}
pinned() { python3 -c 'import json; print(json.load(open("'"$CONF"'/settings.json")).get("dock_pinned"))'; }
classes() { hyprctl clients -j | python3 -c 'import json,sys; print(sorted((c["class"], c["focusHistoryID"]) for c in json.load(sys.stdin)))'; }

# Two apps to pin: desktop ids that are there in this image.
P=()
for id in Alacritty org.gnome.Nautilus Typora chromium btop; do
  for dir in ~/.local/share/applications /usr/share/applications; do
    [ -f "$dir/$id.desktop" ] && { P+=("$id"); break; }
  done
  [ ${#P[@]} -ge 2 ] && break
done
echo "pinned apps: ${P[*]}"
setting dock_enabled=true "dock_pinned=[\"${P[0]}\", \"${P[1]}\"]"

echo "== A without gtk-layer-shell"
ls /usr/lib/libgtk-layer-shell.so.0 2>&1 | head -1
timeout 30 "$B" --dock > /tmp/a.out 2>&1; echo "-- exit $?: $(head -c 300 /tmp/a.out)"
echo "-- dock layer: $(dockh)"

echo "== B gtk-layer-shell installed (pacman -U, the package from the folder)"
echo omarchy | sudo -S pacman -U --noconfirm "$D"/gtk-layer-shell-*.pkg.tar.zst 2>&1 | grep -E "error|warning|installing" | head -3
ls -l /usr/lib/libgtk-layer-shell.so.0

echo "== C the dock at the bottom, the bar at the top"
setsid "$B" --dock > /tmp/dock.out 2>&1 < /dev/null &
sleep 12
layers
read -r DY DH DX DW < <(dockh)
echo "-- dock surface y $DY h $DH (expected y $((H - 88)) h 88); exclusive zone: bottom reserved should be 54"
shot c-bottom

# Where things are (dock_geometry: compact, icon 32, spacing 6): manager, separator, two pinned apps.
CONTENT=$((40 + 9 + 40 + 40 + 3 * 6))
START=$(( (W - CONTENT) / 2 ))
P1X=$((START + 40 + 6 + 9 + 6 + 20)); P2X=$((P1X + 46)); MANX=$((START + 20)); IY=$((H - 30))

echo "== D hover (name), click launches, click again focuses"
/tmp/vp <<<"size $W $H
move $P1X $IY
sleep 600"
shot d-hover
before=$(hyprctl clients -j | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
/tmp/vp <<<"size $W $H
move $P1X $IY
click"
sleep 6
echo "-- windows before $before, after: $(classes)"
/tmp/vp <<<"size $W $H
move $P1X $IY
click"
sleep 2
echo "-- active window: $(hyprctl activewindow -j | python3 -c 'import json,sys; print(json.load(sys.stdin).get("class"))')"
/tmp/vp <<<"size $W $H
move $((W / 2)) $((H / 2))
sleep 300"
shot d-running

echo "== E right-click the second pinned app: menu; Unpin from dock"
/tmp/vp <<<"size $W $H
move $P2X $IY
click right
sleep 500"
shot e-menu
# The menu's last entry (not running: … Unpin from dock) sits right above the dock.
MX=$(( P2X - 110 )); [ $MX -lt 4 ] && MX=4
/tmp/vp <<<"size $W $H
move $((MX + 60)) $((H - 60 - 20))
sleep 200
click"
sleep 2
echo "-- pinned now: $(pinned)"
shot e-unpinned

echo "== F Pin a running app through its dock menu, then reorder by dragging"
setting "dock_pinned=[\"${P[0]}\"]"
# Chromium: one desktop entry for its window class (foot has three, which would make two items).
T=${P[1]}
echo "-- running app to pin: $T"
setsid uwsm-app -- "$T.desktop" >/dev/null 2>&1 < /dev/null &
sleep 12
# manager, separator, the pinned app, separator, the running one.
C2=$((40 + 9 + 40 + 9 + 40 + 4 * 6)); S2=$(( (W - C2) / 2 )); TX=$((S2 + 40 + 6 + 9 + 6 + 40 + 6 + 9 + 6 + 20))
/tmp/vp <<<"size $W $H
move $TX $IY
click right
sleep 500"
shot f-menu
MX=$(( TX - 110 )); [ $MX -gt $((W - 224)) ] && MX=$((W - 224))
# Running, not pinned (Chromium has its own New Window): … Pin to dock, Close (the last entry).
/tmp/vp <<<"size $W $H
move $((MX + 60)) $((H - 80 - 29))
sleep 200
click"
sleep 2
echo "-- pinned after Pin to dock: $(pinned)"
# Now both are pinned (manager, separator, two apps): drag the first behind the second.
/tmp/vp <<<"size $W $H
move $P1X $IY
down
glide $((P1X + 20)) $IY 200
glide $((P2X + 15)) $IY 400
sleep 300
up
sleep 300"
sleep 2
echo "-- pinned after the drag: $(pinned)"
shot f-reordered
/tmp/vp <<<"size $W $H
move $P1X $IY
click right
sleep 400"
# The first slot is now Chromium (running): Close is its last entry.
MX=$(( P1X - 110 ))
/tmp/vp <<<"size $W $H
move $((MX + 60)) $((H - 80))
sleep 200
click"
sleep 3
echo "-- after Close: $(classes)"

echo "== G auto-hide (the surface stays, only a 2 px strip takes the pointer)"
setting dock_autohide=true
sleep 3
echo "-- hidden: $(dockh); $(hyprctl monitors -j | python3 -c 'import json,sys; print("reserved", json.load(sys.stdin)[0]["reserved"])')"
shot g-hidden
/tmp/vp <<<"size $W $H
move $((W / 2)) $((H - 40))
sleep 1000"
shot g-over-hidden-area
/tmp/vp <<<"size $W $H
move $((W / 2)) $((H - 1))
sleep 800"
shot g-shown
/tmp/vp <<<"size $W $H
move $((W / 2)) $((H / 2))
sleep 1600"
shot g-hidden-again
setting dock_autohide=false

echo "== H the dock's position: top asked, the bar is there, so it stays at the bottom; left works"
setting 'dock_position="top"'
sleep 3; echo "-- top asked: $(dockh)"
setting 'dock_position="left"'
sleep 3; echo "-- left: $(dockh)"; layers
shot h-left
setting 'dock_position="bottom"'
sleep 2

echo "== I a second start re-reads; the plugin's toggle --dock; switched off it ends"
timeout 20 "$B" --dock; echo "-- second start exit $?; docks running: $(pgrep -fc 'maprisma-launcher --dock')"
mkdir -p ~/.config/omarchy/plugins && cp -r "$D/plugin" /tmp/plugin
mkdir -p /tmp/pbin && ln -sf "$B" /tmp/pbin/maprisma-launcher
PATH=/tmp/pbin:$PATH timeout 20 /tmp/plugin/maprisma-launcher-toggle --dock; echo "-- toggle --dock exit $?; docks: $(pgrep -fc 'maprisma-launcher --dock')"
setting dock_enabled=false
sleep 3
echo "-- after off: docks running $(pgrep -fc 'maprisma-launcher --dock'), layer $(dockh)"
PATH=/tmp/pbin:$PATH timeout 20 /tmp/plugin/maprisma-launcher-toggle --dock; echo "-- toggle --dock while off: exit $?, docks $(pgrep -fc 'maprisma-launcher --dock')"
echo "-- dock output"; head -c 1500 /tmp/dock.out; echo

for s in $SHOTS; do
  echo "== SHOT $s"; base64 -w0 "/tmp/shot-$s.png" 2>/dev/null; echo; echo "== ENDSHOT"
done
echo "== END"
