swaylock(1)

# NAME

swaylock - screen locker for Wayland (swaylock-authd; with authd support)

# SYNOPSIS

_swaylock_ [options...]

# DESCRIPTION

swaylock locks a Wayland session by acquiring an exclusive lock surface on
every output via the ext-session-lock-v1 protocol. The session remains locked
until the correct password is entered. Any compositor that implements
ext-session-lock-v1 is supported.

On startup, swaylock reads a configuration file (if one exists), then applies
any command-line arguments on top. Command-line arguments always win.

# AUTHD

swaylock supports Ubuntu authd as an alternative authentication backend. If
_/run/authd.sock_ exists when swaylock starts, the PAM child process
advertises the GDM PAM extension JSON protocol
(_com.ubuntu.authd.gdm_, version 1) to the loaded PAM modules. The authd
PAM module then drives authentication through that protocol instead of the
standard PAM conversation.

When authd is active, the lock screen presents a multi-stage UI:

*Broker selection*
	A scrollable list of available authentication brokers is shown in
	place of the ring indicator. Use the arrow keys to move the selection
	and Enter to confirm. Up to eight entries are visible at once.

*Authentication mode selection*
	After a broker is chosen, its supported authentication modes are
	listed in the same way.

*Challenge*
	The challenge stage replaces the list with the normal ring
	indicator or one of the following authd-specific layouts:

	_form_ – A text entry field. The _entry_ hint from the broker
	determines the accepted input type: _chars_, _chars\_password_,
	_digits_, or _digits\_password_.

	_newpassword_ – A two-field password-change form.

	_qrcode_ – A QR code is rendered on screen (requires the binary to
	be built with *-Dqrencode=true*). A human-readable fallback string
	is shown beneath the image when provided by the broker.

If _/run/authd.sock_ is absent, swaylock falls back to a plain PAM
conversation with no broker or mode selection.

# GENERAL OPTIONS

*-h, --help*
	Print a usage summary and exit.

*-v, --version*
	Print the version string and exit.

*-C, --config* <path>
	Read configuration from <path> instead of the default locations.

*-d, --debug*
	Enable verbose debug logging.

*-e, --ignore-empty-password*
	Skip password validation when the input is empty.

*-F, --show-failed-attempts*
	Show the running count of failed attempts on the indicator.

*-f, --daemonize*
	Fork into the background after the session is confirmed locked. The
	parent process waits for the child to signal readiness, then exits.
	stdout and stderr are redirected to _/dev/null_ in the child.

*-R, --ready-fd* <fd>
	Write a single newline byte to <fd> once the compositor has confirmed
	that the session is locked and no sensitive content remains visible.
	The fd is closed immediately afterwards.

*--steal-unlock*
	Attempt to seize the ext-session-lock from a previously crashed
	swaylock instance. If successful, the session is immediately unlocked
	and swaylock exits. If another locker is still attached, the
	compositor will refuse the lock and swaylock exits with an error.

# BACKGROUND

*-i, --image* [[<output>]:]<path>
	Load an image from <path> and use it as the background. If an output
	name is given before the colon, the image is applied to that output
	only; otherwise it becomes the default for all outputs. This option
	may be given multiple times. If the image path itself contains a
	colon, prepend an extra colon to prevent the output-name prefix from
	being parsed.

*-c, --color* <rrggbb[aa]>
	Fill the background with a solid colour. When *-i* is also given,
	this colour appears behind the image. Defaults to _A3A3A3_ (light
	grey).

*-s, --scaling* <mode>
	How to scale the background image to fit each output. Accepted
	values: _stretch_, _fill_, _fit_, _center_, _tile_, _solid_color_.
	Specifying _solid_color_ suppresses the image entirely and shows only
	the background colour. Defaults to _fill_.

*-t, --tiling*
	Shorthand for *--scaling=tile*.

# INDICATOR

The indicator is a circular widget drawn on every output. Its ring, fill, and
text change colour to reflect the current authentication state.

*-u, --no-unlock-indicator*
	Do not draw the indicator at all.

*--indicator-idle-visible*
	Keep the indicator visible even when there is no keyboard activity.
	By default it is hidden while idle.

*--indicator-radius* <r>
	Outer radius of the indicator in pixels. Defaults to _50_.

*--indicator-thickness* <t>
	Thickness of the ring in pixels. Defaults to _10_.

*--indicator-x-position* <x>
	Pin the horizontal centre of the indicator to <x> pixels from the
	left edge of the output. Without this option, the indicator is
	centred automatically.

*--indicator-y-position* <y>
	Pin the vertical centre of the indicator to <y> pixels from the top
	edge of the output. Without this option, the indicator is centred
	automatically.

*--font* <name>
	Pango font description used for all indicator text. Defaults to
	_sans-serif_.

*--font-size* <pt>
	Force the indicator text to a fixed point size. When absent or zero
	the size is chosen automatically based on the indicator radius.

*-k, --show-keyboard-layout*
	Display the active xkb layout name below the indicator while typing.

*-K, --hide-keyboard-layout*
	Always hide the layout name, even when more than one layout is
	configured or *--show-keyboard-layout* is set.

*-L, --disable-caps-lock-text*
	Do not show the "Caps Lock" label on the indicator.

*-l, --indicator-caps-lock*
	Tint the indicator ring and fill using the Caps Lock colour set when
	Caps Lock is active, so its state is visible at a glance.

# COLOURS

All colour options accept a hex value in _rrggbb_ or _rrggbbaa_ form. The
alpha component defaults to _ff_ when omitted.

The indicator has five states that drive colour selection:

- *input* – the user is typing a password
- *cleared* – the input buffer has just been cleared
- *caps-lock* – Caps Lock is active (requires *-l*)
- *verifying* – password verification is in progress
- *wrong* – the last attempt was rejected

## Key highlights

Arc segments appear on the ring as keys are pressed or deleted.

*--key-hl-color* <color>
	Colour of key-press arcs. Defaults to _33DB00FF_.

*--bs-hl-color* <color>
	Colour of backspace arcs. Defaults to _DB3300FF_.

*--caps-lock-key-hl-color* <color>
	Colour of key-press arcs when Caps Lock is active. Defaults to
	_33DB00FF_.

*--caps-lock-bs-hl-color* <color>
	Colour of backspace arcs when Caps Lock is active. Defaults to
	_DB3300FF_.

*--separator-color* <color>
	Colour of the lines between arc segments. Defaults to _000000FF_.

## Inside fill

*--inside-color* <color>
	Input state. Defaults to _000000C0_.

*--inside-clear-color* <color>
	Cleared state. Defaults to _E5A445C0_.

*--inside-caps-lock-color* <color>
	Caps Lock state. Defaults to _000000C0_.

*--inside-ver-color* <color>
	Verifying state. Defaults to _0072FFC0_.

*--inside-wrong-color* <color>
	Wrong state. Defaults to _FA0000C0_.

## Dividing line

The line sits between the inside fill and the outer ring.

*--line-color* <color>
	Input state. Defaults to _000000FF_.

*--line-clear-color* <color>
	Cleared state. Defaults to _000000FF_.

*--line-caps-lock-color* <color>
	Caps Lock state. Defaults to _000000FF_.

*--line-ver-color* <color>
	Verifying state. Defaults to _000000FF_.

*--line-wrong-color* <color>
	Wrong state. Defaults to _000000FF_.

*-n, --line-uses-inside*
	Instead of the line colours above, always use the current inside fill
	colour for the line.

*-r, --line-uses-ring*
	Instead of the line colours above, always use the current ring colour
	for the line.

## Ring

*--ring-color* <color>
	Input state. Defaults to _337D00FF_.

*--ring-clear-color* <color>
	Cleared state. Defaults to _E5A445FF_.

*--ring-caps-lock-color* <color>
	Caps Lock state. Defaults to _E5A445FF_.

*--ring-ver-color* <color>
	Verifying state. Defaults to _3300FFFF_.

*--ring-wrong-color* <color>
	Wrong state. Defaults to _7D3300FF_.

## Text

*--text-color* <color>
	Input state. Defaults to _E5A445FF_.

*--text-clear-color* <color>
	Cleared state. Defaults to _000000FF_.

*--text-caps-lock-color* <color>
	Caps Lock state. Defaults to _E5A445FF_.

*--text-ver-color* <color>
	Verifying state. Defaults to _000000FF_.

*--text-wrong-color* <color>
	Wrong state. Defaults to _000000FF_.

## Keyboard layout label

*--layout-bg-color* <color>
	Background fill of the layout label box. Defaults to _000000C0_.

*--layout-border-color* <color>
	Border of the layout label box. Defaults to _00000000_ (transparent).

*--layout-text-color* <color>
	Text inside the layout label box. Defaults to _FFFFFFFF_.

# CONFIGURATION FILE

swaylock searches the following paths in order and reads the first file it
finds:

. _$HOME/.swaylock/config_
. _$XDG_CONFIG_HOME/swaylock/config_ — or _$HOME/.config/swaylock/config_
  when XDG_CONFIG_HOME is unset or empty
. _SYSCONFDIR/swaylock/config_ (typically _/etc/swaylock/config_)

A different path can be forced with *-C*.

Each non-empty line that does not begin with *#* is treated as a single
long-form option. Strip the leading dashes, and append *=<value>* for
options that take a value. Boolean flags need no value at all. Example:

```
# background
image=/usr/share/backgrounds/default.png
scaling=fill

# indicator colours
ring-color=3300ffff
text-color=ffffffff

# behaviour
show-failed-attempts
ignore-empty-password
```

Command-line arguments are processed after the configuration file and
override any conflicting values.

# SIGNALS

*SIGUSR1*
	Unlock the session and exit cleanly.

# ACKNOWLEDGEMENTS

swaylock-authd is a derivative work of the original swaylock, written by Drew
DeVault and contributors. The original source is available at
https://github.com/swaywm/swaylock and this project is at
https://github.com/hpidcock/swaylock-authd. Both are released under the MIT
licence.

# SEE ALSO

sway(1), xkbcommon(3)
