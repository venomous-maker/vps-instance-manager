#!/bin/bash
# add_user.sh - Script to add users to the container (idempotent)

set -euo pipefail

USERNAME=${1:-}
PASSWORD=${2:-"defaultpassword"}

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username> [password]" >&2
    exit 1
fi

if id -u "$USERNAME" >/dev/null 2>&1; then
    echo "User $USERNAME already exists; ensuring settings..."
else
    # Create user with home directory and bash shell
    useradd -m -s /bin/bash "$USERNAME"
fi

# Ensure home directory exists and ownership is correct
HOME_DIR="/home/$USERNAME"
mkdir -p "$HOME_DIR"
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"

# Set/refresh password
if [ -n "$PASSWORD" ]; then
  echo "$USERNAME:$PASSWORD" | chpasswd
fi

# Add user to sudo group (optional)
if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "$USERNAME" || true
fi

# Create user's workspace directory
mkdir -p "$HOME_DIR/workspace"
chown "$USERNAME:$USERNAME" "$HOME_DIR/workspace"

echo "User $USERNAME is ensured and ready for SSH."
