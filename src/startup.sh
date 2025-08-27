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