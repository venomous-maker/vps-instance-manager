#!/bin/bash
# manage_containers.sh - Script to manage user containers via generated compose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
GEN_COMPOSE="$SCRIPT_DIR/docker-compose.generated.yml"
USERS_CSV="$SCRIPT_DIR/users.csv"
STORAGE_DIR="$SCRIPT_DIR/storage"

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

# Generate a reasonable random password (16 chars alnum)
gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '=+/' | tr -dc 'A-Za-z0-9' | head -c 16
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
  fi
}

# Validate username for service/container naming
validate_user() {
  local u=${1:-}
  if [ -z "$u" ]; then
    echo "Error: username is required" >&2; exit 1
  fi
  case "$u" in
    -*) echo "Error: username cannot start with '-'
" >&2; exit 1;;
  esac
  if ! echo "$u" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'; then
    echo "Error: invalid username '$u'. Allowed: alnum, dot, underscore, dash; must start with alnum; max 63 chars." >&2
    exit 1
  fi
}

# Print available usernames based on generated services
print_available_users() {
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" config --services 2>/dev/null | sed 's/-ssh$//' | awk 'NF{print "  - "$0}' ) || true
}

show_help() {
    cat << EOF
Container Management Script (automated)

Usage: $0 COMMAND [ARGS]

Commands:
  generate                          Generate $GEN_COMPOSE from $USERS_CSV (self-contained)
  up                                Generate and start all defined user containers
  add <user> [ssh web pass cpus mem storage]
                                    Add/update a user row in users.csv and up just that service
  remove <user>                     Stop and remove a user's service and volume; delete from users.csv
  start <user>                      Start a specific user's container
  stop <user>                       Stop a specific user's container
  restart <user>                    Restart a specific user's container
  recreate <user>                   Force-recreate a specific user's container with current config
  resources <user>                  Show configured and runtime CPU/RAM limits for a user's container
  logs <user>                       Show logs for a user's container
  shell <user>                      Open shell in user's container
  ssh-info <user>                   Show SSH connection info for user
  config                            Show services from generated compose
  doctor <user>                     Run diagnostics for a user (CSV/compose/service)
  list                              List all user containers
  status                            Show status of all containers
  help                              Show this help

CSV format (backward compatible):
  user,ssh_port,web_port,password,cpus,memory,storage
  - cpus: number of CPU cores (e.g. 0.5, 1, 2)
  - memory: RAM limit (e.g. 512m, 1g)
  - storage: persistent home size (e.g. 5G, 20G). Creates a loopback ext4 volume mounted to /home
Example: alice,2222,8001,mysecret,1,512m,10G
EOF
}

get_container_name() {
    local user=$1
    echo "${user}-ssh"
}

get_ssh_port() {
    local user=$1
    validate_user "$user"
    local container_name
    container_name=$(get_container_name "$user")
    docker port -- "$container_name" 22 2>/dev/null | cut -d: -f2
}

ensure_users_csv() {
  if [ ! -f "$USERS_CSV" ]; then
    echo "user,ssh_port,web_port,password,cpus,memory,storage" > "$USERS_CSV"
  fi
}

sanitize_user() {
  # trim whitespace and CRs
  echo "$1" | tr -d '\r' | sed -e 's/^\s\+//' -e 's/\s\+$//'
}

# Convert sizes like 10G/512M to bytes (best effort)
size_to_bytes() {
  local s="$1"
  case "$s" in
    *[!0-9mMgGkK]) echo 0; return;;
  esac
  local num unit
  num=$(echo "$s" | sed -E 's/([0-9]+).*/\1/')
  unit=$(echo "$s" | sed -E 's/[0-9]+(.*)/\1/' | tr '[:upper:]' '[:lower:]')
  case "$unit" in
    g|gb) echo $(( num * 1024 * 1024 * 1024 ));;
    m|mb) echo $(( num * 1024 * 1024 ));;
    k|kb) echo $(( num * 1024 ));;
    "") echo "$num";;
    *) echo 0;;
  esac
}

# Ensure loopback-backed storage mounted at $STORAGE_DIR/<user>
ensure_storage() {
  local user=$1 size=${2:-}
  [ -z "$size" ] && return 0
  mkdir -p "$STORAGE_DIR"
  local img="$STORAGE_DIR/${user}.img" mnt="$STORAGE_DIR/${user}"
  local want_bytes cur_bytes
  want_bytes=$(size_to_bytes "$size")
  if [ "$want_bytes" -le 0 ]; then
    echo "Warning: invalid storage size '$size' for user '$user'; skipping dedicated storage." >&2
    return 0
  fi
  if [ ! -f "$img" ]; then
    echo "Creating storage image for $user: $size"
    truncate -s "$size" "$img"
    mkfs.ext4 -F "$img" >/dev/null 2>&1
  else
    cur_bytes=$(stat -c%s "$img" 2>/dev/null || echo 0)
    if [ "$cur_bytes" -lt "$want_bytes" ]; then
      echo "Expanding storage image for $user to $size"
      truncate -s "$size" "$img"
      e2fsck -p -f "$img" >/dev/null 2>&1 || true
      resize2fs -f "$img" >/dev/null 2>&1 || true
    fi
  fi
  mkdir -p "$mnt"
  # mount if not mounted
  if ! mountpoint -q "$mnt"; then
    mount -o loop,noatime,nodiratime "$img" "$mnt"
  fi
}

# Generate compose from CSV
generate_compose() {
  ensure_users_csv
  tmp_file=$(mktemp)
  {
    echo "# This file is generated. Do not edit manually."
    echo "# Source CSV: $(basename "$USERS_CSV")"
    echo "services:"
    # Use distinct local variables to avoid clobbering outer scope
    local u ssh_p web_p pass cpus_v mem_v storage_v
    # shellcheck disable=SC2162
    while IFS=, read -r u ssh_p web_p pass cpus_v mem_v storage_v; do
      # skip header or comments/blank
      [ -z "${u:-}" ] && continue
      case "$u" in \
        \#*|user) continue;; \
      esac
      u=$(sanitize_user "$u")
      [ -z "$u" ] && continue
      # defaults
      ssh_p=${ssh_p:-0}
      web_p=${web_p:-0}
      pass=${pass:-}
      cpus_v=${cpus_v:-}
      mem_v=${mem_v:-}
      storage_v=${storage_v:-}
      [ -z "$pass" ] && pass=$(gen_password)
      # service
      echo "  ${u}-ssh:"
      echo "    build: ."
      echo "    container_name: ${u}-ssh"
      echo "    hostname: ${u}-workspace"
      echo "    restart: unless-stopped"
      echo "    labels:"
      echo "      - managed-by=manage_container.sh"
      echo "      - user=${u}"
      # Removed no-new-privileges to allow sudo within the container
      echo "    tmpfs: [ \"/tmp:rw,noexec,nosuid\", \"/run:rw\", \"/var/run:rw\" ]"
      echo "    volumes:"
      if [ -n "$storage_v" ]; then
        echo "      - ./storage/${u}:/home"
      else
        echo "      - ${u}-data:/home"
      fi
      echo "    environment:"
      echo "      - USERS=${u}:${pass}"
      echo "    healthcheck:"
      echo "      test: [\"CMD-SHELL\", \"pgrep -x sshd >/dev/null 2>&1\"]"
      echo "      interval: 10s"
      echo "      timeout: 3s"
      echo "      retries: 5"
      echo "      start_period: 5s"
      echo "    networks: [ user-network ]"
      # Resource limits
      if [ -n "$cpus_v" ]; then
        echo "    cpus: \"$cpus_v\""
      fi
      if [ -n "$mem_v" ]; then
        echo "    mem_limit: \"$mem_v\""
        echo "    mem_reservation: \"$mem_v\""
      fi
      if [ -n "$cpus_v" ] || [ -n "$mem_v" ]; then
        echo "    deploy:"
        echo "      resources:"
        echo "        limits:"
        [ -n "$cpus_v" ] && echo "          cpus: \"$cpus_v\""
        [ -n "$mem_v" ] && echo "          memory: \"$mem_v\""
      fi
      echo "    ports:"
      if [ "$ssh_p" != "0" ]; then
        echo "      - \"${ssh_p}:22\""
      fi
      if [ "$web_p" != "0" ]; then
        echo "      - \"${web_p}:8000\""
      fi
    done < "$USERS_CSV"
    echo "volumes:"
    # shellcheck disable=SC2162
    local uv sv wv pv cv mv storv
    while IFS=, read -r uv sv wv pv cv mv storv; do
      [ -z "${uv:-}" ] && continue
      case "$uv" in \
        \#*|user) continue;; \
      esac
      uv=$(sanitize_user "$uv")
      [ -z "$uv" ] && continue
      # Only define named volume when storage not set
      if [ -z "${storv:-}" ]; then
        echo "  ${uv}-data:"
      fi
    done < "$USERS_CSV"
    echo "networks:"
    echo "  user-network:"
    echo "    driver: bridge"
  } > "$tmp_file"
  mv "$tmp_file" "$GEN_COMPOSE"
  echo "Generated $GEN_COMPOSE"
}

compose_up_all() {
  generate_compose
  # Pre-mount storage for all users that specified it
  local u ssh_p web_p pass cpus_v mem_v storage_v
  while IFS=, read -r u ssh_p web_p pass cpus_v mem_v storage_v; do
    [ -z "${u:-}" ] && continue
    case "$u" in \#*|user) continue;; esac
    u=$(sanitize_user "$u")
    [ -z "$u" ] && continue
    ensure_storage "$u" "${storage_v:-}"
  done < "$USERS_CSV"
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" up -d --build )
}

service_exists() {
  local svc=$1
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" config --services | grep -Fx "$svc" >/dev/null 2>&1 )
}

# Return the container ID for a service (empty if not running)
get_container_id() {
  local svc=$1
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" ps -q "$svc" )
}

start_container() {
    local user=$1
    validate_user "$user"
    generate_compose
    # Mount storage if configured
    local stor
    stor=$(awk -F, -v u="$user" 'BEGIN{IGNORECASE=1} $1==u{print $7; exit}' "$USERS_CSV" | tr -d '\r' || true)
    ensure_storage "$user" "$stor"
    local svc
    svc=$(get_container_name "$user")
    echo "Using service: $svc"
    if ! service_exists "$svc"; then
      echo "Error: service '$svc' not found in $GEN_COMPOSE. Check users.csv and regenerate." >&2
      exit 1
    fi
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" up -d --build -- "$svc" )
}

stop_container() {
    local user=$1
    validate_user "$user"
    local svc
    svc=$(get_container_name "$user")
    if ! service_exists "$svc"; then
      echo "Error: service '$svc' not found in compose config" >&2
      exit 1
    fi
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" stop -- "$svc" )
}

restart_container() {
    local user=$1
    validate_user "$user"
    local svc
    svc=$(get_container_name "$user")
    if ! service_exists "$svc"; then
      echo "Error: service '$svc' not found in compose config" >&2
      exit 1
    fi
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" restart -- "$svc" )
}

recreate_container() {
    local user=$1
    validate_user "$user"
    generate_compose
    local svc
    svc=$(get_container_name "$user")
    echo "Force-recreating service: $svc"
    if ! service_exists "$svc"; then
      echo "Error: service '$svc' not found in compose config" >&2
      exit 1
    fi
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" up -d --build --force-recreate --no-deps -- "$svc" )
}

show_logs() {
    local user=$1
    validate_user "$user"
    local svc
    svc=$(get_container_name "$user")
    if ! service_exists "$svc"; then
      echo "Error: service '$svc' not found in compose config" >&2
      exit 1
    fi
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" logs -f -- "$svc" )
}

open_shell() {
    local user=$1
    validate_user "$user"
    local svc
    svc=$(get_container_name "$user")
    if ! service_exists "$svc"; then
      echo "Error: service '$svc' not found in compose config (check username)." >&2
      echo "Available users:" >&2
      print_available_users >&2
      exit 1
    fi
    local cid
    cid=$(get_container_id "$svc")
    if [ -z "$cid" ]; then
      echo "Container for service '$svc' is not running. Starting it..."
      ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" up -d -- "$svc" )
      cid=$(get_container_id "$svc")
      if [ -z "$cid" ]; then
        echo "Error: failed to start service '$svc'" >&2
        exit 1
      fi
    fi
    echo "Opening shell in container for user: $user"
    docker exec -it -- "$cid" /bin/bash
}

show_ssh_info() {
    local user=$1
    validate_user "$user"
    local svc
    svc=$(get_container_name "$user")
    if ! service_exists "$svc"; then
      echo "Error: service '$svc' not found in compose config" >&2
      echo "Available users:" >&2
      print_available_users >&2
      exit 1
    fi
    local cid
    cid=$(get_container_id "$svc")
    local ssh_port=""
    if [ -n "$cid" ]; then
      ssh_port=$(docker port -- "$cid" 22 2>/dev/null | cut -d: -f2)
    fi

    if [ -n "$ssh_port" ]; then
        echo "SSH Connection Info for $user:"
        echo "  Host: localhost"
        echo "  Port: $ssh_port"
        echo "  Username: $user"
        echo "  Command: ssh -p $ssh_port $user@localhost"
    else
        echo "Container for user $user is not running or port not mapped; try: $0 start $user"
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
    ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" ps )
}

show_config() {
  generate_compose
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" config --services | cat )
}

doctor() {
  local user=${1:-}
  if [ -n "$user" ]; then
    validate_user "$user"
  fi
  echo "== CSV (raw) =="
  sed -n '1,200p' "$USERS_CSV" | cat
  echo
  echo "== Generated services =="
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" config --services | cat ) || true
  if [ -n "$user" ]; then
    local svc
    svc=$(get_container_name "$user")
    echo
    echo "Resolved service for '$user': $svc"
    if service_exists "$svc"; then
      echo "Service exists in compose."
    else
      echo "Service NOT found in compose."
      echo "Available users:"
      print_available_users
    fi
    if file "$USERS_CSV" | grep -qi 'CRLF'; then
      echo "CSV has CRLF line endings; run: dos2unix '$USERS_CSV'" >&2
    fi
  fi
}

csv_upsert_user() {
  ensure_users_csv
  local user=$1 ssh_port=${2:-0} web_port=${3:-0} password=${4:-} cpus=${5:-} memory=${6:-} storage=${7:-}
  validate_user "$user"
  # sanitize ports numeric
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=0
  [[ "$web_port" =~ ^[0-9]+$ ]] || web_port=0
  # remove existing line for user (exact match at start of line)
  if grep -E "^${user}," "$USERS_CSV" >/dev/null 2>&1; then
    tmp=$(mktemp); awk -F, -v u="$user" 'BEGIN{OFS=","} NR==1{print;next} $1!=u{print}' "$USERS_CSV" > "$tmp" && mv "$tmp" "$USERS_CSV"
  fi
  # generate password if empty
  if [ -z "$password" ]; then
    password=$(gen_password)
  fi
  echo "${user},${ssh_port},${web_port},${password},${cpus},${memory},${storage}" >> "$USERS_CSV"
  echo "$password"  # echo so caller can capture
}

add_user_service() {
  local user=$1 ssh_port=${2:-0} web_port=${3:-0} password=${4:-} cpus=${5:-} memory=${6:-} storage=${7:-}
  local pw
  pw=$(csv_upsert_user "$user" "$ssh_port" "$web_port" "$password" "$cpus" "$memory" "$storage")
  start_container "$user"
  echo "User $user added/updated. Password: $pw"
}

# Unmount and remove loopback storage for a user (if present)
teardown_storage() {
  local user=$1
  local mnt="$STORAGE_DIR/${user}"
  local img="$STORAGE_DIR/${user}.img"
  if mountpoint -q "$mnt"; then
    umount -l "$mnt" || true
  fi
  [ -d "$mnt" ] && rmdir "$mnt" 2>/dev/null || true
  [ -f "$img" ] && rm -f "$img" || true
}

remove_user_service() {
  local user=$1
  validate_user "$user"
  local svc
  svc=$(get_container_name "$user")
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" stop -- "$svc" || true )
  ( cd "$SCRIPT_DIR" && compose_cmd -f "$GEN_COMPOSE" rm -f -- "$svc" || true )
  docker volume rm "${user}-data" 2>/dev/null || true
  # unmount and remove dedicated storage if present
  teardown_storage "$user"
  # remove from CSV
  if [ -f "$USERS_CSV" ]; then
    tmp=$(mktemp); awk -F, -v u="$user" 'BEGIN{OFS=","} NR==1{print;next} $1!=u{print}' "$USERS_CSV" > "$tmp" && mv "$tmp" "$USERS_CSV"
  fi
  # regenerate compose after removal
  generate_compose
  echo "Removed user $user service and data (if any)."
}

# Show configured and runtime resources for a user
show_resources() {
  local user=$1
  validate_user "$user"
  generate_compose
  local svc cid
  svc=$(get_container_name "$user")
  if ! service_exists "$svc"; then
    echo "Error: service '$svc' not found in compose config" >&2
    exit 1
  fi
  # Config from CSV
  local csv_cpus csv_mem
  csv_cpus=$(awk -F, -v u="$user" 'BEGIN{IGNORECASE=1} $1==u{print $5; exit}' "$USERS_CSV" | tr -d '\r')
  csv_mem=$(awk -F, -v u="$user" 'BEGIN{IGNORECASE=1} $1==u{print $6; exit}' "$USERS_CSV" | tr -d '\r')
  [ -z "$csv_cpus" ] && csv_cpus="(not set)"
  [ -z "$csv_mem" ] && csv_mem="(not set)"
  echo "Configured (CSV):"
  echo "  CPUs:   $csv_cpus"
  echo "  Memory: $csv_mem"
  # Runtime from docker inspect (if running)
  cid=$(get_container_id "$svc")
  if [ -z "$cid" ]; then
    echo "Runtime: container not running. Start it to inspect actual limits."
    return 0
  fi
  # Fetch NanoCpus, CpuQuota/Period, Memory, MemoryReservation
  local nano quota period mem_bytes mem_resv cpuset
  nano=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$cid" 2>/dev/null | tr -d '\r')
  quota=$(docker inspect -f '{{.HostConfig.CpuQuota}}' "$cid" 2>/dev/null | tr -d '\r')
  period=$(docker inspect -f '{{.HostConfig.CpuPeriod}}' "$cid" 2>/dev/null | tr -d '\r')
  cpuset=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$cid" 2>/dev/null | tr -d '\r')
  mem_bytes=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null | tr -d '\r')
  mem_resv=$(docker inspect -f '{{.HostConfig.MemoryReservation}}' "$cid" 2>/dev/null | tr -d '\r')
  # Compute CPUs
  local cpus_calc cps
  if [ -n "$nano" ] && [ "$nano" -gt 0 ] 2>/dev/null; then
    # NanoCPUs is in units of 1e-9 CPU
    cpus_calc=$(awk -v n="$nano" 'BEGIN{printf "%.3f", n/1000000000}')
  elif [ -n "$quota" ] && [ -n "$period" ] && [ "$period" -gt 0 ] 2>/dev/null; then
    cpus_calc=$(awk -v q="$quota" -v p="$period" 'BEGIN{printf "%.3f", q/p}')
  else
    cpus_calc="(unlimited)"
  fi
  # Memory formatting
  format_bytes() {
    local b=$1
    if [ -z "$b" ] || [ "$b" -le 0 ] 2>/dev/null; then echo "(unlimited)"; return; fi
    awk -v b="$b" 'BEGIN{u[1]="B";u[2]="KiB";u[3]="MiB";u[4]="GiB";u[5]="TiB";i=1;while(b>=1024 && i<5){b/=1024;i++} printf "%.2f %s", b,u[i]}'
  }
  echo "Runtime (docker):"
  echo "  CPUs:   ${cpus_calc}${cpuset:+ (cpuset=$cpuset)}"
  echo "  Memory: $(format_bytes "$mem_bytes") (reservation: $(format_bytes "$mem_resv"))"
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
    add_user_service "$2" "${3:-0}" "${4:-0}" "${5:-}" "${6:-}" "${7:-}"
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
  recreate)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    recreate_container "$2"
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
  config)
    show_config
    ;;
  doctor)
    [ -z "${2:-}" ] && { echo "Usage: $0 doctor <user>"; exit 1; }
    doctor "$2"
    ;;
  list)
    list_containers
    ;;
  status)
    show_status
    ;;
  resources)
    [ -z "${2:-}" ] && { echo "Error: user required"; exit 1; }
    show_resources "$2"
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

