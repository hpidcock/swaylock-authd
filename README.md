# swaylock-authd

A Wayland session locker. Acquires an exclusive lock surface on every output
using the ext-session-lock-v1 protocol and holds it until the correct password
is authenticated through PAM. The binary is named `swaylock`.

> [!WARNING]
> This software is experimental. Although every effort has been made to ensure
> it is secure, it has not been independently audited. Use at your own risk.

## Building

Requires Zig 0.14.0 or later, plus the following libraries:

| Library | Notes |
|---|---|
| wayland-client | |
| libxkbcommon | |
| cairo | |
| pam | |
| wayland-protocols | build-time |
| wayland-scanner | build-time |
| gdk-pixbuf-2.0 | optional; needed for non-PNG backgrounds |
| libqrencode | optional; needed for QR code rendering |

```sh
zig build -Doptimize=ReleaseSafe
sudo install -m755 zig-out/bin/swaylock /usr/local/bin/swaylock
```

Build options passed with `-D<option>=<value>`:

| Option | Default | Description |
|---|---|---|
| `gdk-pixbuf` | `true` | Enable gdk-pixbuf image loading |
| `qrencode` | `false` | Enable QR code rendering |
| `sysconfdir` | `/etc` | System-wide config directory prefix |
| `wl-proto-dir` | pkg-config | Override wayland-protocols pkgdatadir |

## Configuration

swaylock reads the first config file it finds at these paths, in order:

1. `~/.swaylock/config`
2. `$XDG_CONFIG_HOME/swaylock/config` (falls back to `~/.config/swaylock/config`)
3. `$sysconfdir/swaylock/config`

Each line is a long-form option with leading dashes removed. Boolean flags
stand alone; valued options use `key=value`. Lines beginning with `#` and
blank lines are ignored. A custom path can be given with `-C`.

See `swaylock(1)` for the full option reference.

## authd

swaylock supports [Ubuntu authd](https://github.com/ubuntu/authd) as an
alternative authentication backend. If `/run/authd.sock` exists at startup,
the PAM child process advertises the GDM PAM extension JSON protocol to any
loaded PAM modules. The authd PAM module then takes over and drives a
multi-stage authentication flow:

1. **Broker selection** — a scrollable list of available brokers replaces
   the ring indicator. Arrow keys move the selection; Enter confirms.
2. **Authentication mode selection** — the chosen broker's supported modes
   are presented in the same list format.
3. **Challenge** — the ring indicator or an authd-specific layout is shown:
   - `form` — a text entry field; the broker specifies the accepted input
     type (`chars`, `chars_password`, `digits`, `digits_password`).
   - `newpassword` — a password-change form.
   - `qrcode` — a QR code rendered on screen (requires
     `-Dqrencode=true` at build time), with an optional human-readable
     fallback string below.

If `/run/authd.sock` is absent, swaylock falls back to a plain PAM
conversation.

## Privileges

swaylock spawns a child process to run PAM authentication. That child must
be able to open the PAM service, which on many systems requires elevated
privileges. Install the binary setuid root:

```sh
sudo chmod a+s /usr/local/bin/swaylock
```

Elevated privileges are dropped shortly after startup.

## Acknowledgements

swaylock-authd is a derivative work of the original swaylock, written by Drew
DeVault and contributors. The original project is at
https://github.com/swaywm/swaylock and this project is at
https://github.com/hpidcock/swaylock-authd. Both are released under the MIT
licence.

## AI Disclosure

The refactoring of this project from C into Zig was assisted by AI tooling.