#!/bin/bash
# add_user.sh - Script to add users to the container

USERNAME=$1
PASSWORD=${2:-"defaultpassword"}

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 <username> [password]"
    exit 1
fi

# Create user with home directory
useradd -m -s /bin/bash "$USERNAME"

# Set password
echo "$USERNAME:$PASSWORD" | chpasswd

# Add user to sudo group (optional)
usermod -aG sudo "$USERNAME"

# Create user's workspace directory
mkdir -p "/home/$USERNAME/workspace"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/workspace"

echo "User $USERNAME created successfully with password: $PASSWORD"
echo "User can SSH to this container and has sudo privileges"