#!/bin/sh
# Installs Nunki, the hall announcer, on a Linux box - a small PC or a
# Raspberry Pi in the hall with speakers on it - as a service that starts
# with the machine.
#
#   curl -fsSL https://github.com/teapot-chess/Nunki/releases/latest/download/install.sh | sudo sh
#
# or, in a hall without internet, from a release unpacked on a stick:
#
#   tar -xzf nunki-linux-x86_64.tar.gz && sudo sh nunki/install.sh
#
# Options (after `sh -s --` when piped):
#   --lan             let other machines in the hall reach the pages (a box
#                     without a screen). They are asked for the access PIN,
#                     which this script prints when it is done and which
#                     stays in /var/lib/nunki/access-pin.
#   --version X.Y.Z   that release instead of the latest
#
# What it does, and nothing more:
#   /opt/nunki            the program, owned by root; replaced by updates
#   /var/lib/nunki        the data, owned by the user "nunki"; never
#                          replaced, never removed - not by an update, not by
#                          uninstall.sh
#   /etc/nunki/nunki.env the two settings of the service (port, network);
#                          written once and then left to you
#   a system user "nunki" in the group "audio" (the sound card)
#   nunki.service, nunki-update.path, nunki-update.service
#
# Run it again to repair an installation; it changes no setting and no data.
#
# Needs: a 64-bit system (x86_64 or arm64) with systemd and glibc 2.35 or
# newer - Debian 12, Ubuntu 22.04, Raspberry Pi OS (64-bit) "Bookworm", or
# later. The runtime is inside; nothing else is installed.

set -eu

REPO="teapot-chess/Nunki"
INSTALL_DIR="/opt/nunki"
DATA_DIR="/var/lib/nunki"
CONF_DIR="/etc/nunki"
SERVICE_USER="nunki"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "install.sh: $*" >&2; exit 1; }

main() {
    lan=0
    wanted=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --lan) lan=1; shift ;;
            --version) wanted="$2"; shift 2 ;;
            -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    [ "$(id -u)" = 0 ] || die "run this as root (sudo)."
    [ "$(uname -s)" = Linux ] || die "this installs on Linux. For Windows there is Nunki-Setup.exe."
    command -v systemctl >/dev/null 2>&1 || die "this needs systemd, and found none."

    for tool in curl tar sha256sum getent useradd; do
        command -v "$tool" >/dev/null 2>&1 || die "this needs '$tool', which is not installed."
    done

    case "$(uname -m)" in
        x86_64 | amd64) cpu=x86_64 ;;
        aarch64 | arm64) cpu=aarch64 ;;
        armv7l | armv6l) die "this is a 32-bit system ($(uname -m)). Nunki is built for 64-bit only: install the 64-bit Raspberry Pi OS." ;;
        *) die "there is no build for this processor ($(uname -m))." ;;
    esac

    # The runtime inside the release was built against glibc 2.35. On an
    # older system it dies at start with a line about GLIBC_2.3x; better to
    # say so here, in words.
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -n "$libc" ]; then
        major=${libc%%.*}
        minor=${libc#*.}
        minor=${minor%%.*}
        if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
            die "this system's C library is glibc $libc; Nunki needs 2.35 or newer (Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm)."
        fi
    else
        die "this system does not use glibc (Alpine?). There is no build for it."
    fi

    # A release this script stands in, or one to fetch.
    here=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")
    tmp=""
    trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT

    if [ -z "$wanted" ] && [ -n "$here" ] && [ -x "$here/bin/nunki" ] && [ -r "$here/VERSION" ]; then
        src="$here"
        say "Installing the release in $src."
    else
        file="nunki-linux-$cpu.tar.gz"
        if [ -n "$wanted" ]; then
            base="https://github.com/$REPO/releases/download/v$wanted"
        else
            base="https://github.com/$REPO/releases/latest/download"
        fi

        tmp=$(mktemp -d /tmp/nunki-install.XXXXXX)
        say "Downloading $base/$file"
        curl -fsSL --retry 2 -o "$tmp/$file" "$base/$file" || die "the download did not succeed."
        curl -fsSL --retry 2 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "the checksums could not be downloaded."
        (cd "$tmp" && grep " $file\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1) ||
            die "the download does not match its checksum."
        tar -xzf "$tmp/$file" -C "$tmp"
        src="$tmp/nunki"
    fi

    [ -x "$src/bin/nunki" ] || die "that is not a Nunki release: no bin/nunki in it."

    # The user the service runs as. No shell, no password; its home is the
    # data directory.
    if ! getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --user-group --home-dir "$DATA_DIR" --no-create-home \
            --shell /usr/sbin/nologin "$SERVICE_USER"
    fi

    # The sound card. On a box without a desktop (ALSA straight to the
    # card) this is all it takes. On a desktop with PipeWire or PulseAudio
    # the sound server belongs to the person signed in, and a system service
    # may not reach it at all: README, "Linux and sound".
    if getent group audio >/dev/null 2>&1; then
        usermod -aG audio "$SERVICE_USER"
    else
        say "Note: this system has no group 'audio'. Give the user '$SERVICE_USER' access to the sound card yourself."
    fi

    if ! command -v espeak-ng >/dev/null 2>&1 && ! command -v spd-say >/dev/null 2>&1; then
        say "Note: there is no espeak-ng on this system, so Nunki has no voice yet."
        say "      Debian, Ubuntu, Raspberry Pi OS: sudo apt install espeak-ng"
    fi

    install -d -o root -g root -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/releases" "$CONF_DIR"
    install -d -o root -g root -m 0755 /var/lib/nunki-update
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR"
    # Where the Setup page leaves its request for an update.
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR/update"

    # Written once. An installation that is repaired or updated keeps what
    # the arbiter made of it.
    if [ ! -e "$CONF_DIR/nunki.env" ]; then
        {
            echo "# Settings of the Nunki service. Restart it after a change:"
            echo "#   sudo systemctl restart nunki"
            echo "PORT=4062"
            echo ""
            echo "# Who may open the pages. Without this line only this machine;"
            echo "# with it, the hall's network as well, which then asks for the PIN:"
            echo "#   sudo cat $DATA_DIR/access-pin"
            if [ "$lan" = 1 ]; then
                echo "NUNKI_LISTEN=lan"
            else
                echo "#NUNKI_LISTEN=lan"
            fi
            echo ""
            echo "# A name the hall's router gives this box (nunki.venue.lan) is refused"
            echo "# until it is listed here:"
            echo "#PHX_HOST=nunki.venue.lan"
        } >"$CONF_DIR/nunki.env"
        chmod 0644 "$CONF_DIR/nunki.env"
    fi

    # The release, the units and the two scripts: update.sh knows how, and
    # is how it is done every time after this one.
    sh "$src/update.sh" --from "$src" --no-restart

    systemctl daemon-reload
    systemctl enable nunki.service nunki-update.path >/dev/null 2>&1
    systemctl restart nunki-update.path
    systemctl restart nunki.service

    version=$(tr -d ' \t\r\n' <"$src/VERSION")
    say ""
    say "Nunki $version is installed and running."
    say "  The pages:   http://localhost:4062 on this box"
    if [ "$lan" = 1 ]; then
        say "               and http://<this box's address>:4062 from the hall's network."
        say "               Those computers are asked for the access PIN (see below)."
    else
        say "               (NUNKI_LISTEN=lan in $CONF_DIR/nunki.env opens them to the hall's network.)"
    fi
    # There is always a PIN, and a box without a screen has nowhere to show
    # it but here: Nunki makes it when it starts, so give it a moment.
    pin=""
    waited=0
    while [ "$waited" -lt 20 ]; do
        if [ -r "$DATA_DIR/access-pin" ]; then
            pin=$(head -n 1 "$DATA_DIR/access-pin" | sed 's/[[:space:]]*$//')
            [ -n "$pin" ] && break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if [ -n "$pin" ]; then
        say "  Access PIN:  $pin"
    else
        say "  Access PIN:  not made yet; once Nunki has started: sudo cat $DATA_DIR/access-pin"
    fi
    say "               Kept in $DATA_DIR/access-pin; change it on the control page,"
    say "               or before a start with a pin-request file (README)."
    say "  The data:    $DATA_DIR"
    say "  The program: $INSTALL_DIR"
    say "  Its log:     journalctl -u nunki"
    say "  Update:      on the control page, or: sudo $INSTALL_DIR/update.sh"
    say "  Remove:      sudo $INSTALL_DIR/uninstall.sh   (keeps the data)"
}

main "$@"
