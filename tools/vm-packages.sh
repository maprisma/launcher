# Maprisma Launcher's packages in a throwaway Omarchy VM (runs inside it over ssh, see tools/vm-packages):
# the AUR package installed, started, toggled through the plugin's script, removed; the AppImage started.
set -u
echo omarchy | sudo -S mkdir -p /mnt/dist 2>/dev/null
echo omarchy | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro dist /mnt/dist 2>&1 | tail -1
D=/mnt/dist
ls "$D" | tr '\n' ' '; echo
export XDG_RUNTIME_DIR=/run/user/$(id -u)
# The desktop may still be starting: wait for its Wayland socket and Hyprland (up to 90 s).
for _ in $(seq 1 90); do
  ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -q '^wayland-[0-9]*$' && ls "$XDG_RUNTIME_DIR/hypr" >/dev/null 2>&1 && break
  sleep 1
done
sleep 5
export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -m1 '^wayland-[0-9]*$')
export HYPRLAND_INSTANCE_SIGNATURE=$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)
window() { hyprctl clients -j 2>/dev/null | python3 -c 'import json,sys
for c in json.load(sys.stdin):
    if c.get("class") == "com.maprisma.Launcher":
        print("class", c["class"], "floating", c.get("floating"), "at", c.get("at"), "size", c.get("size"), "hidden", c.get("hidden"))'
  hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print("monitor", m["width"], m["height"], "scale", m["scale"], "reserved", m["reserved"])'; }

echo "== A the AUR package (pacman -U)"
pkg=$(ls "$D"/maprisma-launcher-bin-*.pkg.tar.zst | head -1)
echo omarchy | sudo -S pacman -U --noconfirm "$pkg" 2>&1 | grep -E "error|warning|installing|missing" | head -8
pacman -Qi maprisma-launcher-bin | grep -E "^(Name|Version|Installed Size)"
ls -l /usr/bin/maprisma-launcher
for f in /usr/lib/maprisma-launcher/maprisma-launcher /usr/lib/maprisma-launcher/lib/*.so; do
  ldd "$f" | grep "not found" | sed "s|^|$(basename "$f"): |"
done
echo "-- desktop entry: $(grep -c . /usr/share/applications/com.maprisma.Launcher.desktop) lines"

echo "== B the plugin's toggle script (as a bar click)"
mkdir -p ~/.config/omarchy/plugins && cp -r "$D/plugin" ~/.config/omarchy/plugins/ubruckhaus.maprisma-launcher
toggle=~/.config/omarchy/plugins/ubruckhaus.maprisma-launcher/maprisma-launcher-toggle
setsid "$toggle" >/tmp/app.out 2>&1 &
sleep 12
echo "-- after the first click: $(pgrep -x maprisma-launch >/dev/null || pgrep -f /usr/lib/maprisma-launcher/maprisma-launcher >/dev/null && echo running || echo 'not running')"
window
grim /tmp/pkg.png 2>&1 | head -2
"$toggle"; sleep 3
echo "-- after the second click (hides a shown, focused window):"; window
"$toggle"; sleep 3
echo "-- after the third click (shows it again):"; window
echo "-- config written: $(ls ~/.config/maprisma-launcher 2>/dev/null | tr '\n' ' ')"
echo "-- app output"; head -c 1200 /tmp/app.out; echo
pkill -f /usr/lib/maprisma-launcher/maprisma-launcher; sleep 2

echo "== C the package removed"
echo omarchy | sudo -S pacman -R --noconfirm maprisma-launcher-bin 2>&1 | grep -E "error|removing" | head -3
ls /usr/lib/maprisma-launcher 2>&1 | head -1
echo "-- the toggle without the app: $("$toggle" 2>&1; echo "exit $?")"

echo "== D the AppImage"
cp "$D"/Maprisma-Launcher-*-x86_64.AppImage /tmp/ML.AppImage && chmod +x /tmp/ML.AppImage
rm -rf ~/.config/maprisma-launcher
setsid /tmp/ML.AppImage >/tmp/appimage.out 2>&1 &
sleep 15
window
grim /tmp/appimage.png 2>&1 | head -2
echo "-- output"; head -c 800 /tmp/appimage.out; echo
pkill -f ML.AppImage; pkill -f maprisma-launcher
echo "== SHOT pkg"; base64 -w0 /tmp/pkg.png 2>/dev/null; echo
echo "== SHOT appimage"; base64 -w0 /tmp/appimage.png 2>/dev/null; echo
echo "== END"
