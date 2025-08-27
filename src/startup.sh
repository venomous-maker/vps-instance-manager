#!/bin/bash
# startup.sh - Container startup script

echo "Starting SSH container..."

# Start SSH service
echo "Starting SSH daemon..."
service ssh start

# Check if SSH started successfully
if ! pgrep sshd > /dev/null; then
    echo "ERROR: SSH daemon failed to start"
    exit 1
fi

echo "SSH daemon started successfully"

# Check if USERS environment variable is set and create users
if [ ! -z "$USERS" ]; then
    echo "Creating users from USERS environment variable..."
    IFS=',' read -ra USER_ARRAY <<< "$USERS"
    for user_info in "${USER_ARRAY[@]}"; do
        IFS=':' read -ra USER_PASS <<< "$user_info"
        username=${USER_PASS[0]}
        password=${USER_PASS[1]:-"defaultpass"}

        echo "Creating user: $username"
        /usr/local/bin/add_user.sh "$username" "$password"
    done
    echo "User creation completed"
else
    echo "No USERS environment variable found - skipping user creation"
fi

# Display container information
echo "=================================="
echo "Container startup completed"
echo "SSH is running on port 22"
echo "Available users:"
grep "/home" /etc/passwd | cut -d: -f1 | grep -v root || echo "  No regular users found"
echo "=================================="

# Keep container running by tailing a log file
echo "Container is ready. Keeping alive..."
tail -f /var/log/auth.log