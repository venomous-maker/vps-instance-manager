#!/bin/bash
# manage_containers.sh - Script to manage user containers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

show_help() {
    cat << EOF
Container Management Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    start <user>     Start a specific user's container
    stop <user>      Stop a specific user's container
    restart <user>   Restart a specific user's container
    logs <user>      Show logs for a user's container
    shell <user>     Open shell in user's container
    ssh-info <user>  Show SSH connection info for user
    list             List all user containers
    create <user>    Create new user container
    remove <user>    Remove user container and data
    status           Show status of all containers

Examples:
    $0 start user1
    $0 ssh-info user2
    $0 create newuser
    $0 logs user3

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

start_container() {
    local user=$1
    local container_name=$(get_container_name "$user")
    echo "Starting container for user: $user"
    docker-compose -f "$COMPOSE_FILE" up -d "$container_name"
}

stop_container() {
    local user=$1
    local container_name=$(get_container_name "$user")
    echo "Stopping container for user: $user"
    docker-compose -f "$COMPOSE_FILE" stop "$container_name"
}

restart_container() {
    local user=$1
    local container_name=$(get_container_name "$user")
    echo "Restarting container for user: $user"
    docker-compose -f "$COMPOSE_FILE" restart "$container_name"
}

show_logs() {
    local user=$1
    local container_name=$(get_container_name "$user")
    echo "Showing logs for user: $user"
    docker-compose -f "$COMPOSE_FILE" logs -f "$container_name"
}

open_shell() {
    local user=$1
    local container_name=$(get_container_name "$user")
    echo "Opening shell in container for user: $user"
    docker exec -it "$container_name" /bin/bash
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
        echo ""
        echo "Web Service Port: $(docker port "$container_name" 8000 2>/dev/null | cut -d: -f2)"
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
    docker-compose -f "$COMPOSE_FILE" ps
}

create_user_container() {
    local user=$1
    local password=${2:-$(openssl rand -base64 12)}

    echo "Creating container for user: $user"
    echo "Generated password: $password"

    # Add user service to docker-compose.yml (you'll need to manually edit or use a template)
    echo ""
    echo "Please add this service to your docker-compose.yml:"
    cat << EOF

  ${user}-ssh:
    <<: *ssh-template
    container_name: ${user}-ssh
    hostname: ${user}-workspace
    ports:
      - "22XX:22"  # Replace XX with unique port number
      - "80XX:8000"  # Replace XX with unique port number
    volumes:
      - ${user}-data:/home
      - ./shared:/shared:ro
    environment:
      - USERS=${user}:${password}
EOF

    echo ""
    echo "Also add volume:"
    echo "  ${user}-data:"
    echo "    driver: local"
}

remove_container() {
    local user=$1
    local container_name=$(get_container_name "$user")

    echo "Removing container and data for user: $user"
    read -p "Are you sure? This will delete all data for $user (y/N): " confirm

    if [[ $confirm =~ ^[Yy]$ ]]; then
        docker-compose -f "$COMPOSE_FILE" down "$container_name"
        docker volume rm "${user}-data" 2>/dev/null
        echo "Container and data removed for user: $user"
    else
        echo "Operation cancelled"
    fi
}

# Main script logic
case "$1" in
    start)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        start_container "$2"
        ;;
    stop)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        stop_container "$2"
        ;;
    restart)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        restart_container "$2"
        ;;
    logs)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        show_logs "$2"
        ;;
    shell)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        open_shell "$2"
        ;;
    ssh-info)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        show_ssh_info "$2"
        ;;
    list)
        list_containers
        ;;
    create)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        create_user_container "$2" "$3"
        ;;
    remove)
        if [ -z "$2" ]; then echo "Error: User required"; exit 1; fi
        remove_container "$2"
        ;;
    status)
        show_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown command '$1'"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac