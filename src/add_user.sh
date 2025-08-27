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

---

#!/bin/bash
# startup.sh - Container startup script

# Start SSH service
service ssh start

# Check if USERS environment variable is set and create users
if [ ! -z "$USERS" ]; then
    IFS=',' read -ra USER_ARRAY <<< "$USERS"
    for user_info in "${USER_ARRAY[@]}"; do
        IFS=':' read -ra USER_PASS <<< "$user_info"
        username=${USER_PASS[0]}
        password=${USER_PASS[1]:-"defaultpass"}
        /usr/local/bin/add_user.sh "$username" "$password"
    done
fi

# Keep container running
tail -f /dev/null