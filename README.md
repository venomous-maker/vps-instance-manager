DOCKER-DEPLOY (SSH containers)

Overview
- Build a single SSH-enabled image once.
- Define users in a simple CSV (src/users.csv) with per-user ports/passwords.
- Generate a compose file automatically; no manual YAML edits.
- Start/stop per-user containers with helper script.

Layout
- src/Dockerfile: Base image for SSH containers.
- src/startup.sh: Idempotent startup; creates users from USERS env; runs sshd in foreground.
- src/add_user.sh: Idempotent user creation.
- src/docker-compose.yml: Base compose with a reusable service template and healthcheck.
- src/manage_container.sh: Helper to generate per-user services and manage containers.
- src/users.csv: CSV source of users (user,ssh_port,web_port,password).
- src/shared/: Host folder mounted read-only into /shared in each container.

Quick start
1) Build the image
```bash
cd src
# Build once; subsequent user containers reuse this image
docker compose -f docker-compose.yml build
```

2) Add users (CSV-driven) and start
- Option A: Use the helper to add a user and start just that container
```bash
./manage_container.sh add alice 2222 8001 mySecretPass
./manage_container.sh ssh-info alice
```
- Option B: Edit src/users.csv (uncomment/add lines), then start all
```bash
# Edit users.csv, then
./manage_container.sh up
```

3) Operate containers
```bash
./manage_container.sh list
./manage_container.sh status
./manage_container.sh logs alice
./manage_container.sh shell alice
./manage_container.sh stop alice
./manage_container.sh remove alice
```

Notes
- Healthcheck ensures sshd is accepting connections (nc -z localhost 22).
- Root SSH login is disabled; users are created with the provided password and sudo group membership.
- To override a password in users.csv, leave the 4th column empty and the tool will generate a random one.
- If docker compose (v2) is not available, the script falls back to docker-compose (v1).

Troubleshooting
- Ensure Docker is running and you have permission to use it.
- If the shared mount fails, ensure src/shared/ exists on the host.
- To regenerate the compose file without starting, run:
```bash
./manage_container.sh generate
cat src/docker-compose.generated.yml
```

