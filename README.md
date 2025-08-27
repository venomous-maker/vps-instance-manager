DOCKER-DEPLOY (SSH containers)

Overview
- Build a single SSH-enabled image once.
- Define users in a simple CSV (src/users.csv) with per-user ports/passwords and optional CPU/RAM limits.
- Generate a compose file automatically; no manual YAML edits.
- Start/stop per-user containers with helper script.

Layout
- src/Dockerfile: Base image for SSH containers.
- src/startup.sh: Idempotent startup; creates users from USERS env; runs sshd in foreground.
- src/add_user.sh: Idempotent user creation.
- src/docker-compose.yml: Base compose with a reusable service template and healthcheck.
- src/manage_container.sh: Helper to generate per-user services and manage containers.
- src/users.csv: CSV source of users (user,ssh_port,web_port,password,cpus,memory).
- src/shared/: Host folder mounted read-only into /shared in each container.

CSV format
- Columns: user,ssh_port,web_port,password,cpus,memory
- cpus: number of CPU cores (examples: 0.5, 1, 2)
- memory: RAM limit (examples: 256m, 1g)
Examples:
- alice,2222,8001,alicePass123,1,512m
- bob,2223,8002,,0.5,256m

Quick start
1) Build the image
```bash
cd src
docker compose -f docker-compose.yml build
```

2) Add users (CSV-driven) and start
- Option A: Use the helper to add a user with resource limits and start just that container
```bash
cd src
./manage_container.sh add alice 2222 8001 mySecretPass 1 512m
./manage_container.sh ssh-info alice
```
- Option B: Edit src/users.csv, then start all
```bash
cd src
# Edit users.csv, then
./manage_container.sh up
```

3) Operate containers
```bash
cd src
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
- Leaving the password column empty will auto-generate a secure password.
- CPU/RAM limits are emitted under deploy.resources.limits in the generated compose; modern Docker Compose (v2 plugin) applies these. Legacy docker-compose may ignore deploy limits.

Troubleshooting
- Ensure Docker is running and you have permission to use it.
- If the shared mount fails, ensure src/shared/ exists on the host.
- To regenerate the compose file without starting, run:
```bash
cd src
./manage_container.sh generate
cat docker-compose.generated.yml
```
