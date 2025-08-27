#!/bin/bash
# manage_containers.sh - Script to manage user containers via generated compose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_COMPOSE="$SCRIPT_DIR/docker-compose.yml"
GEN_COMPOSE="$SCRIPT_DIR/docker-compose.generated.yml"
USERS_CSV="$SCRIPT_DIR/users.csv"

# Detect compose command
compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "Error: docker compose or docker-compose not found" >&2
    exit 1
  fi
}

show_help() {
    cat << EOF
Container Management Script (automated)

Usage: $0 COMMAND [ARGS]

Commands:
  generate                Generate $GEN_COMPOSE from $USERS_CSV
  up                      Generate and start all defined user containers
  add <user> [ssh web pass]
                          Add/update a user row in users.csv and up just that service
  remove <user>           Stop and remove a user's service and volume; delete from users.csv
  start <user>            Start a specific user's container
  stop <user>             Stop a specific user's container
  restart <user>          Restart a specific user's container
  logs <user>             Show logs for a user's container
  shell <user>            Open shell in user's container
  ssh-info <user>         Show SSH connection info for user
  list                    List all user containers
  status                  Show status of all containers
  help                    Show this help

CSV format: user,ssh_port,web_port,password
Example: alice,2222,8001,mysecret
EOF
}

get_container_name() {
    local user=$1
    echo "${user}-ssh"
}

get_ssh_port() {
    local user=$1
    local container_name=$(get_container_name "$user")
    docker port "$container_name" 22 2>/dev/null | cut -d: -f2
}

ensure_users_csv() {
  if [ ! -f "$USERS_CSV" ]; then
    echo "user,ssh_port,web_port,password" > "$USERS_CSV"
  fi
}

generate_compose() {
  ensure_users_csv
  tmp_file=$(mktemp)
  {
    echo "version: '3.8'"
    echo "services:"
    # shellcheck disable=SC2162
    while IFS=, read -r user ssh_port web_port password; do
      # skip header or comments/blank
      [ -z "${user:-}" ] && continue
      case "$user" in \
        \#*|user) continue;; \
      esac
      # defaults
      ssh_port=${ssh_port:-0}
      web_port=${web_port:-0}
      password=${password:-}
      [ -z "$password" ] && password=$(openssl rand -base64 12 | tr -d '=+/\n' | cut -c1-16)
      # write service
      echo "  ${user}-ssh:"
      echo "    extends:"
      echo "      service: ssh-container-template"
      echo "      file: $(basename "$BASE_COMPOSE")"
      echo "    container_name: ${user}-ssh"
      echo "    hostname: ${user}-workspace"
      echo "    environment:"
      echo "      - USERS=${user}:${password}"
      echo "    ports:"
      if [ "$ssh_port" != "0" ]; then
        echo "      - \"${ssh_port}:22\""
      fi
      if [ "$web_port" != "0" ]; then
        echo "      - \"${web_port}:8000\""
      fi
      echo "    volumes:"
      echo "      - ${user}-data:/home"
    done < "$USERS_CSV"
    echo "volumes:"
    # add volumes for each user
    # shellcheck disable=SC2162
    while IFS=, read -r user ssh_port web_port password; do
      [ -z "${user:-}" ] && continue
      case "$user" in \
        \#*|user) continue;; \
      esac
      echo "  ${user}-data:"
    done < "$USERS_CSV"
  } > "$tmp_file"
  mv "$tmp_file" "$GEN_COMPOSE"
  echo "Generated $GEN_COMPOSE"
}

compose_up_all() {
  generate_compose
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" up -d )
}

start_container() {
    local user=$1
    generate_compose
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" up -d "$(get_container_name "$user")" )
}

stop_container() {
    local user=$1
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" stop "$(get_container_name "$user")" )
}

restart_container() {
    local user=$1
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" restart "$(get_container_name "$user")" )
}

show_logs() {
    local user=$1
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" logs -f "$(get_container_name "$user")" )
}

open_shell() {
    local user=$1
    echo "Opening shell in container for user: $user"
    docker exec -it "$(get_container_name "$user")" /bin/bash
}

show_ssh_info() {
    local user=$1
    local container_name=$(get_container_name "$user")
    local ssh_port=$(get_ssh_port "$user")

    if [ -n "$ssh_port" ]; then
        echo "SSH Connection Info for $user:"
        echo "  Host: localhost"
        echo "  Port: $ssh_port"
        echo "  Username: $user"
        echo "  Command: ssh -p $ssh_port $user@localhost"
    else
        echo "Container for user $user is not running or doesn't exist"
    fi
}

list_containers() {
    echo "User Containers:"
    echo "=================="
    docker ps -a --filter "name=-ssh" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

show_status() {
    echo "Container Status Overview:"
    echo "=========================="
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" ps )
}

csv_upsert_user() {
  ensure_users_csv
  local user=$1 ssh_port=${2:-0} web_port=${3:-0} password=${4:-}
  # sanitize ports numeric
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=0
  [[ "$web_port" =~ ^[0-9]+$ ]] || web_port=0
  # remove existing line for user (exact match at start of line)
  if grep -E "^${user}," "$USERS_CSV" >/dev/null 2>&1; then
    tmp=$(mktemp); awk -F, -v u="$user" 'BEGIN{OFS=","} NR==1{print;next} $1!=u{print}' "$USERS_CSV" > "$tmp" && mv "$tmp" "$USERS_CSV"
  fi
  # generate password if empty
  if [ -z "$password" ]; then
    password=$(openssl rand -base64 12 | tr -d '=+/\n' | cut -c1-16)
  fi
  echo "${user},${ssh_port},${web_port},${password}" >> "$USERS_CSV"
  echo "$password"  # echo so caller can capture
}

add_user_service() {
  local user=$1 ssh_port=${2:-0} web_port=${3:-0} password=${4:-}
  local pw
  pw=$(csv_upsert_user "$user" "$ssh_port" "$web_port" "$password")
  start_container "$user"
  echo "User $user added/updated. Password: $pw"
}

remove_user_service() {
  local user=$1
  local cname=$(get_container_name "$user")
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" stop "$cname" || true )
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$BASE_COMPOSE" -f "$GEN_COMPOSE" rm -f "$cname" || true )
  docker volume rm "${user}-data" 2>/dev/null || true
  # remove from CSV
  if [ -f "$USERS_CSV" ]; then
    tmp=$(mktemp); awk -F, -v u="$user" 'BEGIN{OFS=","} NR==1{print;next} $1!=u{print}' "$USERS_CSV" > "$tmp" && mv "$tmp" "$USERS_CSV"
  fi
  # regenerate compose after removal
  generate_compose
  echo "Removed user $user service and data (if any)."
}

case "${1:-}" in
  generate)
    generate_compose
    ;;
  up)
    compose_up_all
    ;;
  add)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    add_user_service "$2" "${3:-0}" "${4:-0}" "${5:-}"
    ;;
  remove)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    remove_user_service "$2"
    ;;
  start)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    start_container "$2"
    ;;
  stop)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    stop_container "$2"
    ;;
  restart)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    restart_container "$2"
    ;;
  logs)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    show_logs "$2"
    ;;
  shell)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    open_shell "$2"
    ;;
  ssh-info)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    show_ssh_info "$2"
    ;;
  list)
    list_containers
    ;;
  status)
    show_status
    ;;
  help|--help|-h|"")
    show_help
    ;;
  *)
    echo "Error: Unknown command '$1'" >&2
    show_help
    exit 1
    ;;
esac

