# Projector kiosk mode

This kiosk opens the locally hosted SongRec dashboard in Chromium full-screen
when the Raspberry Pi's graphical desktop starts. Chromium is restarted if it
closes or crashes, so the projector returns to the public display.

Copy these two files to the Pi and run the installer from the same directory as
the desktop user that should automatically log in:

```sh
chmod +x install-songrec-kiosk.sh
./install-songrec-kiosk.sh
```

The default dashboard address is `http://127.0.0.1:8080/`. To display a
dashboard hosted by another machine, pass its address:

```sh
./install-songrec-kiosk.sh http://192.168.39.18:8080/
```

The installer installs Chromium if needed and explicitly configures LightDM
Desktop Autologin for the account that runs the installer. It registers a
small dedicated X11 session named `songrec-station-kiosk`, which runs Chromium
through the lightweight Openbox window manager. This works on Raspberry Pi OS
Lite too; no LXDE or labwc desktop is needed. It does not change the SongRec
or web server services.

The kiosk also runs `unclutter-xfixes`, which hides the mouse pointer after
0.2 seconds without movement. Moving the mouse briefly reveals it for
maintenance, then it hides again.

On X11, the launcher selects the primary HDMI output at its native mode and
turns off other connected outputs. This prevents Chromium kiosk from occupying
only one half of a combined desktop. The detected layout is saved in
`~/.local/state/songrec-station-kiosk/xrandr.log`.

If the projector is not the selected output, set its X11 connector explicitly
before launching the kiosk, for example `SONGREC_KIOSK_OUTPUT=HDMI-1`. Obtain
the connector name from the `xrandr.log` file above.

## If the login screen still appears

Copy the updated two kiosk scripts to the Pi and run the installer again as
the intended desktop user (not with `sudo`):

```sh
./install-songrec-kiosk.sh
sudo reboot
```

If LightDM logs in and then immediately returns to its login screen, install
the current kiosk scripts and run the installer again. It creates
`/usr/share/xsessions/songrec-station-kiosk.desktop`, so a full desktop is not
required:

```sh
./install-songrec-kiosk.sh
sudo reboot
```

It writes `/etc/lightdm/lightdm.conf.d/99-songrec-station-kiosk.conf` and, on
older images, corrects any matching setting in `/etc/lightdm/lightdm.conf`.
It also adds the desktop account to the system's `autologin` and
`nopasswdlogin` groups when Raspberry Pi OS has them, which LightDM requires
before it will accept a password-less graphical login.
Verify that it names the expected user:

```sh
sudo cat /etc/lightdm/lightdm.conf.d/99-songrec-station-kiosk.conf
sudo grep -E '^(autologin-user|autologin-session)' /etc/lightdm/lightdm.conf 2>/dev/null || true
```

For an immediate manual repair, replace `YOUR_USER` with the desktop account:

```sh
sudo install -d -m 0755 /etc/lightdm/lightdm.conf.d
printf '[Seat:*]\nautologin-user=YOUR_USER\nautologin-user-timeout=0\n' | \
  sudo tee /etc/lightdm/lightdm.conf.d/99-songrec-station-kiosk.conf >/dev/null
sudo systemctl set-default graphical.target
sudo reboot
```

If that still shows a login screen, collect the active display-manager and
autologin diagnostics after boot:

```sh
systemctl status display-manager --no-pager
sudo journalctl -b -u lightdm --no-pager | tail -80
getent group autologin nopasswdlogin
id "$(whoami)"
```

Before the public event, disable screen blanking in:

```text
raspi-config → Display Options → Screen Blanking → No
```

Then reboot. To stop the kiosk temporarily over SSH, run:

```sh
pkill -f songrec-station-kiosk
```

It starts again at the next desktop login or reboot.
