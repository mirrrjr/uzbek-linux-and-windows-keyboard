#!/bin/bash
set -uo pipefail

# Get absolute path of the install script
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# Define the custom layout name and description
LAYOUT_NAME="uz"
DESCRIPTION="Uzbek"
SYMBOLS_FILE="$SCRIPT_DIR/uz"
PATCH_FILE="$SCRIPT_DIR/evdev_patch.patch"

# Define the paths (same across all major distros — shipped by xkeyboard-config)
SYMBOLS_DIR="/usr/share/X11/xkb/symbols/"
RULES_FILE="/usr/share/X11/xkb/rules/evdev.xml"

# String to check in evdev.xml to see if the layout is already installed
CHECK_STRING="<description>Uzbek (US)</description>"

# --- Root check -------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit 1
fi

# When run with sudo, $SUDO_USER is the real (non-root) user who invoked it.
# We need this later to talk to that user's session (gsettings, kwriteconfig,
# DBus, etc.) since root has no desktop session of its own.
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  # Fallback: try to guess the user who owns the active graphical session
  REAL_USER=$(logname 2>/dev/null || who | awk '{print $1; exit}')
fi

run_as_user() {
  local uid
  uid=$(id -u "$REAL_USER" 2>/dev/null) || return 1
  sudo -u "$REAL_USER" \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    "$@"
}

# --- Distro detection ---------------------------------------------------------
# Determine the package-manager family so we know how to auto-install
# dependencies and which post-install cache step (if any) applies.
DISTRO_FAMILY="unknown"
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ID_STRING="${ID:-} ${ID_LIKE:-}"
  case "$ID_STRING" in
    *arch*|*manjaro*|*endeavouros*)
      DISTRO_FAMILY="arch" ;;
    *debian*|*ubuntu*)
      DISTRO_FAMILY="debian" ;;
    *fedora*|*rhel*)
      DISTRO_FAMILY="fedora" ;;
    *)
      DISTRO_FAMILY="unknown" ;;
  esac
fi
echo "Detected distro family: $DISTRO_FAMILY"

# --- Dependency checks (portable across distros) -----------------------------
if ! command -v patch &> /dev/null; then
  echo "'patch' is not installed."
  case "$DISTRO_FAMILY" in
    arch)
      echo "Installing 'patch' via pacman..."
      pacman -Sy --noconfirm patch
      ;;
    debian)
      echo "Installing 'patch' via apt..."
      apt-get update && apt-get install -y patch
      ;;
    fedora)
      echo "Installing 'patch' via dnf..."
      dnf install -y patch
      ;;
    *)
      echo "✘ Error: could not auto-detect your package manager. Install 'patch' manually, e.g.:"
      echo "   Arch:   sudo pacman -S patch"
      echo "   Debian: sudo apt install patch"
      echo "   Fedora: sudo dnf install patch"
      exit 1
      ;;
  esac
  if ! command -v patch &> /dev/null; then
    echo "✘ Error: 'patch' installation failed. Please install it manually and re-run this script."
    exit 1
  fi
fi

# Check for patch file existence
if [ ! -f "$PATCH_FILE" ]; then
    echo "✘ Error: Patch file '$PATCH_FILE' not found in the current directory. Aborting."
    exit 1
fi

if [ ! -f "$SYMBOLS_FILE" ]; then
    echo "✘ Error: Symbols file '$SYMBOLS_FILE' not found. Aborting."
    exit 1
fi

# --- Patch evdev.xml if needed ------------------------------------------------
echo "Checking for previous installation in $RULES_FILE..."

if grep -q "$CHECK_STRING" "$RULES_FILE"; then
  echo "✔ Layout '$DESCRIPTION' found in $RULES_FILE. Skipping patch."
  echo "   -> Updating symbols file only to ensure latest version is installed."
else
  echo "   -> Layout not found. Proceeding with full installation."
  echo "Applying patch to $RULES_FILE using '$PATCH_FILE'..."
  patch "$RULES_FILE" < "$PATCH_FILE"
  PATCH_EXIT_CODE=$?

  if [ $PATCH_EXIT_CODE -eq 0 ]; then
    echo "✔ Successfully applied patch to $RULES_FILE."
  elif [ $PATCH_EXIT_CODE -eq 1 ]; then
    echo "⚠ Warning: Patch applied with minor errors or fuzz. This is often safe if the entry was added."
  else
    echo "✘ Fatal Error: Patch failed completely. The file may be too different from the one the patch was created against. Aborting."
    exit 1
  fi
fi

# --- Copy the symbols file ----------------------------------------------------
echo "Copying $SYMBOLS_FILE to $SYMBOLS_DIR..."
cp "$SYMBOLS_FILE" "$SYMBOLS_DIR"
if [ $? -eq 0 ]; then
  echo "✔ Successfully copied $SYMBOLS_FILE."
else
  echo "✘ Failed to copy $SYMBOLS_FILE. Aborting."
  exit 1
fi

# --- Rebuild caches -----------------------------------------------------------
# Debian/Ubuntu ship a debconf-driven xkb-data package that keeps its own
# cache; Arch/Fedora read the symbols/rules files directly so no equivalent
# step is required there.
case "$DISTRO_FAMILY" in
  debian)
    if command -v dpkg-reconfigure &> /dev/null; then
      echo "Reconfiguring XKB data (Debian/Ubuntu)..."
      dpkg-reconfigure xkb-data
    fi
    ;;
  *)
    : # No cache rebuild needed on Arch/Fedora
    ;;
esac

# KDE keeps its own sycoca cache of things like the keyboard-layout KCM list;
# rebuild it if kbuildsycoca is present, regardless of distro.
if command -v kbuildsycoca6 &> /dev/null; then
  run_as_user kbuildsycoca6 --noincremental &> /dev/null || true
elif command -v kbuildsycoca5 &> /dev/null; then
  run_as_user kbuildsycoca5 --noincremental &> /dev/null || true
fi

echo "Installation complete. You may need to log out and log back in for changes to take full effect."

# --- Apply the layout to the CURRENT session ---------------------------------
# setxkbmap only works on X11 (or Xwayland clients specifically) — it does
# NOT affect native Wayland clients under GNOME/Mutter, KDE/KWin, Sway, etc.
# So we detect the session type and desktop and use the right mechanism.

SESSION_TYPE=$(run_as_user sh -c 'echo $XDG_SESSION_TYPE' 2>/dev/null || echo "unknown")
DESKTOP_ENV=$(run_as_user sh -c 'echo $XDG_CURRENT_DESKTOP' 2>/dev/null || echo "unknown")

echo "Detected session type: ${SESSION_TYPE:-unknown}, desktop: ${DESKTOP_ENV:-unknown}"

apply_gnome_layout() {
  if ! run_as_user gsettings get org.gnome.desktop.input-sources sources &> /dev/null; then
    return 1
  fi

  local current inner new
  current=$(run_as_user gsettings get org.gnome.desktop.input-sources sources)

  if [[ "$current" == *"'$LAYOUT_NAME'"* ]]; then
    echo "✔ GNOME input source '$LAYOUT_NAME' is already configured."
    return 0
  fi

  inner=$(echo "$current" | sed -e "s/^\[//" -e "s/\]\$//")
  if [ -z "$inner" ]; then
    new="[('xkb', '$LAYOUT_NAME')]"
  else
    new="[$inner, ('xkb', '$LAYOUT_NAME')]"
  fi

  run_as_user gsettings set org.gnome.desktop.input-sources sources "$new"
  echo "✔ Added '$LAYOUT_NAME' to GNOME input sources."
  echo "   -> Switch to it via the top-bar input indicator, or Settings > Keyboard > Input Sources."
  return 0
}

apply_kde_layout() {
  local kwriteconfig
  if command -v kwriteconfig6 &> /dev/null; then
    kwriteconfig="kwriteconfig6"
  elif command -v kwriteconfig5 &> /dev/null; then
    kwriteconfig="kwriteconfig5"
  else
    return 1
  fi

  local current new
  current=$(run_as_user kreadconfig5 --file kxkbrc --group Layout --key LayoutList 2>/dev/null || \
            run_as_user kreadconfig6 --file kxkbrc --group Layout --key LayoutList 2>/dev/null)

  if [[ ",$current," == *",$LAYOUT_NAME,"* ]]; then
    echo "✔ KDE layout '$LAYOUT_NAME' is already configured."
  else
    if [ -z "$current" ]; then
      new="$LAYOUT_NAME"
    else
      new="$current,$LAYOUT_NAME"
    fi
    run_as_user "$kwriteconfig" --file kxkbrc --group Layout --key LayoutList "$new"
    run_as_user "$kwriteconfig" --file kxkbrc --group Layout --key Use true
    echo "✔ Added '$LAYOUT_NAME' to KDE (kxkbrc) input sources."
  fi

  # Ask a running KWin (Wayland or X11) to reload its keyboard config.
  run_as_user qdbus org.kde.keyboard /Layouts reloadConfig &> /dev/null || \
  run_as_user qdbus6 org.kde.keyboard /Layouts reloadConfig &> /dev/null || true
  echo "   -> If it doesn't switch immediately, use the layout indicator or System Settings > Input Devices > Keyboard > Layouts."
  return 0
}

if [[ "$DESKTOP_ENV" == *GNOME* ]]; then
  apply_gnome_layout || echo "⚠ Could not reach GNOME settings automatically. Add '$DESCRIPTION' manually via Settings > Keyboard > Input Sources."
elif [[ "$DESKTOP_ENV" == *KDE* ]]; then
  apply_kde_layout || echo "⚠ Could not reach KDE settings automatically. Add '$DESCRIPTION' manually via System Settings > Input Devices > Keyboard > Layouts."
elif [ "$SESSION_TYPE" = "x11" ]; then
  # Covers any other X11 window manager (i3, dwm, Xfce, LXQt, etc.)
  echo "Setting keyboard layout for the current X11 session..."
  run_as_user setxkbmap -layout "$LAYOUT_NAME" && echo "✔ Layout is now set to $DESCRIPTION."
elif [ "$SESSION_TYPE" = "wayland" ]; then
  # Other Wayland compositors (Sway, Hyprland, wlroots-based, etc.) manage
  # their own keyboard config files and don't expose a common D-Bus/CLI API.
  echo "⚠ Wayland session detected on '$DESKTOP_ENV' (not GNOME or KDE)."
  echo "   'setxkbmap' cannot apply layouts to native Wayland clients here."
  echo "   Add '$LAYOUT_NAME' through your compositor's own config, e.g.:"
  echo "     Sway/Hyprland: xkb_layout \"$LAYOUT_NAME\" in your input config, then reload."
else
  echo "⚠ Could not determine session type/desktop automatically."
  echo "   Please add '$DESCRIPTION' through your desktop's own keyboard/input settings."
fi
