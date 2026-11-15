#!/usr/bin/env python3
"""Show the desktop's file chooser (via the xdg desktop portal) and print the chosen paths.

Used by the juxtopposed menus: "Open File(s)" and "Open Folder". Prints one local path per line;
prints nothing if the user cancels or no portal answers.

Usage: juxt-pick-file.py file|folder
"""
import sys
import urllib.parse

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "file"
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    options = {"multiple": GLib.Variant("b", mode == "file")}
    if mode == "folder":
        options["directory"] = GLib.Variant("b", True)
    title = "Open folder" if mode == "folder" else "Open file"
    reply = bus.call_sync(
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.FileChooser", "OpenFile",
        GLib.Variant("(ssa{sv})", ("", title, options)),
        GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None)
    handle = reply.unpack()[0]

    loop = GLib.MainLoop()
    result = {"uris": None}

    def on_response(_conn, _sender, _path, _iface, _signal, params, _data=None):
        code, results = params.unpack()
        if code == 0:
            result["uris"] = results.get("uris", [])
        loop.quit()

    bus.signal_subscribe(None, "org.freedesktop.portal.Request", "Response",
                         handle, None, Gio.DBusSignalFlags.NONE, on_response, None)
    # give up after 10 minutes so a missing portal does not hang mpv forever
    GLib.timeout_add_seconds(600, lambda: (loop.quit(), False)[1])
    loop.run()

    for uri in result["uris"] or []:
        parsed = urllib.parse.urlparse(uri)
        if parsed.scheme == "file":
            print(urllib.parse.unquote(parsed.path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
