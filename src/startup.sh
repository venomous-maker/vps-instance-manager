#!/bin/bash
# startup.sh - Container startup script

set -euo pipefail

echo "Starting SSH container..."

# Ensure runtime dirs exist (tmpfs may override image contents)
mkdir -p /run/sshd /var/run/sshd
chmod 755 /run/sshd /var/run/sshd

# Create users from USERS env before starting sshd (idempotent)
if [ -n "${USERS:-}" ]; then
    echo "Creating users from USERS environment variable..."
    IFS=',' read -ra USER_ARRAY <<< "${USERS}"
    for user_info in "${USER_ARRAY[@]}"; do
        [ -z "$user_info" ] && continue
        IFS=':' read -ra USER_PASS <<< "$user_info"
        username=${USER_PASS[0]:-}
        password=${USER_PASS[1]:-"defaultpass"}
        if [ -z "$username" ]; then
            echo "Skipping empty username entry"
            continue
        fi
        echo "Ensuring user exists: $username"
        /usr/local/bin/add_user.sh "$username" "$password"
    done
    echo "User creation completed"
else
    echo "No USERS environment variable found - skipping user creation"
fi

# Start SSH service in foreground
echo "Starting SSH daemon..."
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# Simple readiness check
for i in {1..10}; do
  if pgrep sshd >/dev/null; then
    echo "SSH daemon started successfully"
    break
  fi
  echo "Waiting for sshd to be ready... ($i)"
  sleep 1
  if [ $i -eq 10 ]; then
    echo "ERROR: SSH daemon failed to start" >&2
    exit 1
  fi
done

# Display container information
echo "=================================="
echo "Container startup completed"
echo "SSH is running on port 22"
printf "Available users:\n"
grep "/home" /etc/passwd | cut -d: -f1 | grep -vE '^(root|sshd)$' || echo "  No regular users found"
echo "=================================="

# Hand over to sshd as PID 1
wait "$SSHD_PID"
