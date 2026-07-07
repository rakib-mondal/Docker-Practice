# DevOps Handbook: Day 2 — Docker Deep Dive, Image Architecture & Multi-Stage Builds

## 1. Core Component Inspection and Runtime Operations

### `docker inspect`
The `docker inspect` command returns low-level system configuration metadata for Docker objects (containers, images, volumes, networks) in a structured **JSON array format**.

DevOps engineers use this command to audit configurations such as private IP addresses, environment variables, resource constraints (`cgroups`), and volume mount mappings.

**Syntax Variations:**
```bash
# Inspect a container
$ docker inspect <container_id_or_name>

# Extract specific keys using Go templates (e.g., extracting IP Address)
$ docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' newser10
172.17.0.2
```

---

### Executing Commands in Active Workloads: `docker exec`
```bash
$ docker exec -it testcon sh
```
* **Mechanism:** Spawns a new process inside the existing kernel namespaces and cgroups allocated to the target container (`testcon`).
* **Flags Deconstruction:**
  * `-i` (`--interactive`): Keeps `STDIN` open to the container process even if not attached.
  * `-t` (`--tty`): Allocates a pseudo-TTY terminal screen layout.
  * `sh`: Executes the POSIX-compliant shell interpreter inside the running runtime environment.

---

### Run vs. Exec: Architectural Divergence
Understanding the exact functional difference between `docker run` and `docker exec` is a fundamental requirement in automated DevOps operational pipelines.

[Image of docker run vs docker exec execution flow architecture]

```
+-----------------------------------------------------------------------+
| ARCHITECTURAL COMPARISON: RUN VS EXEC                                 |
|                                                                       |
| 1. DOCKER RUN (Creates a totally NEW Container Instance)               |
|    [Image Cache] ---> Creates Container Layer ---> Spawns PID 1       |
|                                                                       |
| 2. DOCKER EXEC (Injects a new worker process into an EXISTING Sandbox) |
|    [Existing Container (PID 1 Alive)] ---> Spawns PID 42 (e.g., sh)   |
+-----------------------------------------------------------------------+
```

* **`docker run`**: Instantiates a brand **new** container filesystem layer, assigns a fresh set of isolated namespaces/cgroups, and executes the default binary application process as **PID 1**.
* **`docker exec`**: Injects a **secondary process** into an already active container sandbox that is currently running a PID 1 program. It shares the exact same infrastructure layer, environment context, and network boundaries as the target container.

---

### Advanced Runtime Resource Enforcement
```bash
$ docker run -itd --name newser10 -p 8006:80 nginx
$ docker run -itd --name newser --memory 500m ubuntu bash
```

* **`-p 8006:80`**: Exposes network traffic pipelines. Maps the public network card interfaces of the host environment at port `8006` to route natively to the private web server port `80` inside the `nginx` container runtime.
* **`--memory 500m`**: Enforces a strict control group (`cgroup`) hard resource constraint boundary. The host Linux kernel will forcefully limit this container instance to use a maximum memory threshold of 500 Megabytes.

---

### Infrastructure Metrics Tracking: `docker container stats`
Provides a live, real-time streaming data feed showing resource consumption metrics for active containers.
```bash
$ docker stats
CONTAINER ID   NAME       CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O         PIDS
e6b1a23c4d5e   newser10   0.05%     3.12MiB / 500MiB      0.62%     1.02kB / 0B       0B / 0B           3
```
* **DevOps Application:** Crucial for profiling microservices during load testing routines to identify memory leaks, resource starvation thresholds, and horizontal/vertical auto-scaling constraints.

---

## 2. Infrastructure Storage Crisis: Disk Exhaustion Scenarios

### Problem Statement: What happens if a physical VM host has only 20 GB of storage capacity, but the combined storage layer definitions of the running Docker containers exceed 20 GB?

When a VM runs out of storage space, Docker containers experience an immediate **write-failure condition**. Containers rely on **Overlay2** storage drivers, which write ephemeral application changes into a localized host directory block (typically situated inside `/var/lib/docker/overlay2/`).

#### Cascade of Technical Failures:
1. **Application Level Failures:** Databases (e.g., PostgreSQL, MySQL) fail instantly because they cannot append data payloads to transaction write-ahead logs (`WAL`). Any application trying to write to `/tmp` will crash.
2. **Container Engine Crashing:** The Docker engine daemon (`dockerd`) fails to process image expansions or handle logging output layers. 
3. **Container Status Stagnation:** Containers often hang in an unresponse state or drop out with an exit runtime exception code.
4. **Host System Freezing:** If the shared storage drive houses both `/var/lib/docker/` and the system root operating system partition (`/`), the Linux operating system kernel locks up entirely due to log exhaustion.

#### DevOps Mitigation Playbook:
* Implement robust automated log-rotation controls within `/etc/docker/daemon.json` (`"log-driver": "json-file"`, with strict `"log-opts": {"max-size": "10m"}`).
* Establish high-threshold alarms using Prometheus/Grafana or node-exporter agents to track node storage thresholds (`disk_utilization > 85%`).
* Run automated sanitization cron schedules utilizing pruning utilities:
  ```bash
  $ docker system prune -a --volumes -f
  ```

---

## 3. Image vs. Container Architecture Deep Dive

Understanding the core distinction between images and containers is essential for constructing efficient systems.

[Image of Docker Image layers with writeable container layer on top]

```
+-------------------------------------------------------+
|            CONTAINER RUNTIME LAYER STACK              |
+-------------------------------------------------------+
| [ Writeable Container Layer ] -> (Volatile, App Logs) |  <-- Created by "docker run"
+-------------------------------------------------------+
| [ Image Layer 3: EXPOSE 80 ]  -> (Read-Only, Immutable)|  ^
+-------------------------------------------------------+  |
| [ Image Layer 2: RUN apt...]  -> (Read-Only, Immutable)|  |-- Defined by Dockerfile
+-------------------------------------------------------+  |
| [ Image Layer 1: FROM base ]  -> (Read-Only, Immutable)|  v
+-------------------------------------------------------+
```

### 1. Docker Image
An **immutable (read-only)** blueprint consisting of an ordered collection of root filesystem layer changes. Images are completely static, stateless structures built upon a series of stacking system snapshots. They do not run actively; they simply store data, files, dependencies, and application run instructions.

### 2. Docker Container
An active, executable **runtime instance** of a Docker Image. When you trigger a container instance initialization, the underlying storage engine (`overlay2`) stacks the read-only image components and tops them with a thin, volatile **Writeable Container Layer** (often termed the "Upper Dir"). 

Any application state modifications, database updates, or file additions generated during execution exist exclusively inside this temporary writeable runtime layer.

---

## 4. Container Management Lifecycles & File Purging

### State Transitions: `docker stop` vs. `docker start` vs. `docker run`
* **`docker run`**: Performs an all-in-one execution flow. It downloads the target image architecture asset, creates a writeable container layer filesystem wrapper, assigns network configurations, and starts the PID 1 workload process.
* **`docker stop`**: Transmits a standard **`SIGTERM`** shutdown signal to the container execution environment, giving the primary application process a default 10-second grace window to clean up network pools, finish active database disk-writes, and terminate gracefully. If the timer expires, it issues a **`SIGKILL`** kernel instruction to forcefully stop the container.
* **`docker start`**: Wakes up an existing, already created but stopped container instance. It reuses the exact same writeable container layer filesystem state and keeps any historical data modifications completely intact. It skips image layer composition steps entirely.

---

### Destructive Automation: Pruning Assets File by File
* **`docker rm`**: Destroys stopped container instances from host storage definitions.
* **`docker rmi`**: Purges cached image definitions from the host environment.

#### High-Velocity Cleanup Variations:
```bash
# Forcefully delete a running container (issues a SIGKILL signal)
$ docker rm -f <container_name>

# Force-delete EVERY container currently existing on the host node
$ docker rm -f $(docker ps -a -q)

# Force-delete EVERY local image asset cached on the host infrastructure 
$ docker rmi -f $(docker ps -a -q)
```
* *Flags breakdown:* `-q` (`--quiet`) filters the console payload to output only numerical hex Object ID metrics, which are then passed cleanly to the removal commands via command substitution.

---

### System Edge Cases: Deleting Images of Active Workloads
**Question:** What happens if an infrastructure engineer executes `docker rmi -f` on an image while a container spawned from that exact image is currently running?

**Technical Consequence:** Docker's graph driver prevents the underlying image layer components from being completely deleted from the physical host filesystem disk allocations. The system records an image untagging operation (`Untagged:...`), disconnecting the readable reference names from the hash registries. 

However, because the active container depends on those underlying filesystem layers via its copy-on-write assembly, the files remain safely locked in storage and the container continues executing without interruption. The layers are only truly removed from disk once the dependent container is stopped and deleted.

---

## 5. Enterprise Reality: Why Use Docker When 95% of Production Uses Kubernetes?

This is a classic architectural evaluation question frequently asked in senior DevOps engineer interviews.

### The True Structural Relationship
Kubernetes is **not** a direct functional replacement for Docker. Instead, they operate at completely different layers of the infrastructure topology:

```
+-----------------------------------------------------------+
|               ENTERPRISE ORCHESTRATION STACK              |
+-----------------------------------------------------------+
| [ Kubernetes (K8s Control Plane) ] -> Cluster Management  |
+-----------------------------------------------------------+
|    [ Containerd / Docker Engine ]  -> Low-Level Runtime   |
+-----------------------------------------------------------+
|        [ Linux Kernel Namespaces / cgroups ]              |
+-----------------------------------------------------------+
```

* **Docker's Role:** Focuses on the single-host domain. It packages applications, dependencies, and environments into standardized images, and runs those isolated containers on a single host machine.
* **Kubernetes' Role:** Focuses on multi-node orchestration. It links thousands of distinct host machines running container engines together into a resilient cluster. It handles auto-scaling, horizontal self-healing, automated rolling deployments, complex network routing, service discovery, and cross-node cluster security.

### Why Docker Knowledge Remains Crucial:
1. **Local Engineering Velocity:** Kubernetes is too resource-heavy for standard local workstation development. Developers use Docker Desktop or Docker CLI to code, package, and build images quickly before pushing them to staging environments.
2. **The Common Standardization Artifact:** Kubernetes requires a packaged artifact to run workloads. The standard artifact used across almost all container orchestrators is the **Docker Image** format, built using a standard `Dockerfile`.
3. **Troubleshooting Foundation:** When a production Pod crashes in a Kubernetes cluster, engineers must log into that specific node and use lower-level container commands (`crictl` or `docker`) to inspect runtime processes, networks, and storage drivers.

---

## 6. Comprehensive Dockerfile Parameter Specification

A `Dockerfile` is a text-based build configuration script containing sequential execution instructions used to assemble a specialized Docker Image.

### Core Parameter Mechanics

#### `FROM`
Defines the base foundational layer image for the build lifecycle. Every valid Dockerfile must start with this parameter.
```dockerfile
FROM alpine:3.18
```

#### `LABEL`
Injects descriptive key-value metadata properties directly into the image's build configuration layer.
```dockerfile
LABEL maintainer="devops-team@company.com" release-version="v2.4"
```

#### `RUN`
Executes terminal shell commands during the image build lifecycle phase. Each `RUN` instruction creates a new immutable, read-only layer on top of the image filesystem stack.
```dockerfile
RUN apt-get update && apt-get install -y curl Git && rm -rf /var/lib/apt/lists/*
```
* *Production Tip:* Always chain commands together using `&&` and clean up package manager caches in the same `RUN` layer to minimize image size overhead.

#### `CMD`
Defines the default application runtime process arguments passed to the container execution environment upon startup. **Important:** If a user passes an override command string during `docker run`, the `CMD` instruction is completely ignored.
```dockerfile
CMD ["nginx", "-g", "daemon off;"]
```

#### `ENTRYPOINT`
Configures the primary executable binary wrapper for the container. Unlike `CMD`, arguments defined here are not overwritten by external trailing `docker run` parameters. Instead, any trailing parameters are appended as arguments to the entrypoint binary.
```dockerfile
ENTRYPOINT ["/usr/bin/redis-server"]
```

#### `EXPOSE`
An informational documentation parameter. It notes which port the container application process listens on. **Layman Terms:** It does *not* actually open host network ports or enable access from the outside world. It is simply an architectural note to developers saying, *"Hey, this application is listening on port 80 inside its private network sandbox."* To route external traffic to it, you must still explicitly pass the `-p` port mapping flag during `docker run`.
```dockerfile
EXPOSE 80
```

#### `WORKDIR`
Sets the active directory path context for all subsequent `RUN`, `CMD`, `ENTRYPOINT`, `COPY`, and `ADD` instructions. If the directory path does not exist, Docker creates it automatically.
```dockerfile
WORKDIR /usr/src/app
```

#### `ENV`
Defines persistent environment variable keys and values that remain available both during the image build process and within the final running container runtime.
```dockerfile
ENV NODE_ENV=production PORT=8080
```

#### `COPY` vs. `ADD`
* **`COPY`**: Safely transfers files and directories from your local development build context directly into the destination image file path structure.
  ```dockerfile
  COPY package.json ./
  ```
* **`ADD`**: An advanced copy parameter that includes extra features: it can fetch files from remote URLs, and it automatically extracts compression tar archives (`.tar.gz`, `.tgz`) directly into the target directory structure during the build phase.
  ```dockerfile
  ADD secure-certs.tar.gz /etc/ssl/private/
  ```

---

### Low-Level Execution Mechanics: `RUN` vs. `CMD` vs. `ENTRYPOINT`

| Parameter | Execution Lifecycle Phase | Overwrite Capability | Core Architectural Purpose |
| :--- | :--- | :--- | :--- |
| **`RUN`** | **Build Time Phase** (Image Assembly) | Not applicable. Generates a physical read-only layer snapshot. | Installs package dependencies, compiles source binaries, and provisions internal system environments. |
| **`CMD`** | **Runtime Phase** (Container Ingress) | **Easily Overwritten** by appending trailing arguments to the `docker run` command. | Defines default, overridable argument strings or standard fallback applications for the container. |
| **`ENTRYPOINT`** | **Runtime Phase** (Container Ingress) | **Highly Persistent**. Requires explicit parameter overrides via the `--entrypoint` CLI flag. | Defines the core binary or system application tool that the container is built to run. |

---

### Building Images via CLI
```bash
# Standard image build configuration referencing active local directory context
$ docker image build -t testapply:v1.1 .

# Build configuration targeting an explicitly named non-standard Dockerfile path asset
$ docker image build -t testapply:v1.1 -f ./infrastructure/production.Dockerfile .
```
* *The Trailing Dot (`.`):* This tells Docker where to find your **Build Context**. All file paths passed to `COPY` or `ADD` commands are resolved relative to this directory root.

---

## 7. Advanced Optimization: Multi-Stage & Distroless Image Paradigms

### The Production Anti-Pattern: Monolithic Image Bloat
A common beginner mistake is using a single Dockerfile configuration to handle application building, dependency compilation, and runtime execution. This patterns results in bloated images that package heavy build-tooling dependencies (like compilers, SDKs, build tools, and package managers) straight into production images. 

This bloat increases infrastructure resource overhead, extends CI/CD pipeline transport times, and significantly widens the security attack surface by leaving unneeded debugging binaries on the production host.

---

### Solution 1: Multi-Stage Builds
Multi-stage builds allow developers to use multiple temporary `FROM` base layers within a single `Dockerfile`. This enables you to compile source code in an early, heavy development stage, and then extract only the final compiled production binaries into a clean, ultra-lightweight execution stage.

### Solution 2: Distroless Images
Distroless images, maintained primarily by Google, contain **only** your application and its minimal runtime dependencies. They do not contain package managers (like `apt`, `apk`), system shells (`bash`, `sh`), or standard coreutils utilities. This minimalist design strips image storage overhead down to the absolute bare essentials and blocks attackers from executing shell scripts if a system compromise occurs.

---

### Step-by-Step Production Dockerfile Implementation: Go API Service

Below is a production-grade, multi-stage `Dockerfile` that demonstrates how to build a Go web application using a heavy compilation container, extract the binary into a minimalist distroless runtime layer, and apply strict security profiles.

```dockerfile
# =======================================================================
# STAGE 1: Compilation Environment (Heavy Build Image)
# =======================================================================
FROM golang:1.21-alpine AS builder

# Establish working directory context inside the build environment
WORKDIR /build

# Copy configuration manifests to leverage Docker image layer caching
COPY go.mod go.sum ./

# Download application dependencies
RUN go mod download

# Transfer the remaining application source code
COPY . .

# Compile the Go application as a statically linked binary
# CGO_ENABLED=0 disables dynamic C-library linking for maximum portability
# GOOS=linux targets the native Linux kernel architecture
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o web-app main.go

# =======================================================================
# STAGE 2: Production Execution Environment (Ultra-Lightweight Distroless)
# =======================================================================
FROM gcr.io/distroless/static-debian12:latest

# Metadata auditing definitions
LABEL corporate.team="DevOps Core Infrastructure" environment="Production"

# Establish runtime execution path directory context
WORKDIR /app

# Secure File Transfer: Extract ONLY the compiled binary asset from the builder stage
COPY --from=builder /build/web-app .

# Define global runtime environment variables
ENV PORT=8080 NODE_ENV=production

# Document target network runtime mapping port
EXPOSE 8080

# Configure execution process as the primary system entrypoint
ENTRYPOINT ["./web-app"]
```

#### Line-by-Line Technical Analysis:
1. `FROM golang:1.21-alpine AS builder`: Initializes a heavy build container equipped with the full Go SDK toolkit, naming this temporary execution stage `builder`.
2. `COPY go.mod go.sum ./` + `RUN go mod download`: Copies dependency manifests and downloads dependencies *before* the main source code transfer. This optimization ensures that Docker reuses cached dependency layers instead of re-downloading modules every time a line of source code changes.
3. `-ldflags="-s -w"`: Strips debugging symbols and location tracking schemas from the Go binary, trimming the file size down significantly.
4. `FROM gcr.io/distroless/static-debian12:latest`: Discards the entire Go SDK compilation environment, initializing a fresh, minimal distroless layer container that contains zero package managers and zero terminal shells.
5. `COPY --from=builder /build/web-app .`: Performs a precise, cross-container file transfer to extract only the compiled, standalone `web-app` binary from the `builder` container filesystem.
6. `ENTRYPOINT ["./web-app"]`: Launches the application binary directly. Because there is no underlying shell interpreter (`bash`/`sh`) inside a distroless container, shell-form commands cannot execute. You must use JSON array executive bracket formatting here.

---

## 8. Senior DevOps Interview Matrix (Day 2 Core Concepts)

### Q1: An analytical profiling tool reports a severe security exploit nested within the `bash` system dependencies of a production image, but your application requires a distroless deployment. How does a distroless framework change your security landscape and incident response strategy?
**Answer:** Distroless deployment patterns eliminate this vulnerability risk entirely by stripping out the host shell layers (`bash`, `sh`, `dash`) and underlying package managers. If there is no shell binary present inside the image layout, automated exploitation frameworks cannot execute shell-injection commands or download malicious tracking toolsets. 

From an incident response standpoint, traditional shell access via `docker exec` becomes impossible. Engineers instead pivot to distributed observability telemetry tools, sidecar inspection container patterns, or ephemeral debug containers to run live infrastructure diagnostics.

### Q2: What is the operational distinction between the shell form and exec form configurations when defining `CMD` or `ENTRYPOINT` parameters inside a Dockerfile?
**Answer:**
* **Shell Form (e.g., `ENTRYPOINT python app.py`):** The container engine executes the binary program as a sub-process wrapper nested within a shell interpreter shell execution execution execution environment (`/bin/sh -c`). Because of this extra wrapping layer, the shell interpreter assumes **PID 1** status inside the container, and the underlying application runs as a child process. This setup blocks the container from receiving native operating system lifecycle signals (like `SIGTERM` during a `docker stop` action), often causing the application to ungracefully time out and take a sudden `SIGKILL` hit.
* **Exec Form (e.g., `ENTRYPOINT ["python", "app.py"]`):** The container engine invokes the application binary directly without spawning a parent shell interpreter wrapper. The target application process assumes **PID 1** status natively, allowing it to respond instantly to standard `SIGTERM` termination requests for clean, graceful shutdowns.

### Q3: A microservice running inside a production container is experiencing random, sudden crashes. The application logs show no output. Running `docker inspect` shows an exit status code of `137`. What does this indicate, and how do you resolve it?
**Answer:** An exit status code of **`137`** indicates that the container process was forcefully terminated by an external operating system command via a **`SIGKILL` signal (Signal 9)**. This most commonly happens when the system hits an **Out-Of-Memory (OOM) condition**.

#### Troubleshooting Workflow:
1. Run `docker inspect` and review the `.State.OOMKilled` JSON boolean parameter string. If it returns `true`, the workload was terminated by either the host system's Linux kernel OOM-killer daemon or a strict container memory limit (`--memory`).
2. Review the container's resource configuration profiles to see if the control group limits (`cgroups`) are set too low for the application's real-world data processing needs.
3. Use runtime monitoring tools like `docker stats` or Grafana alerts to track the application's memory consumption patterns and identify memory leak loops.
4. Scale the container's hardware limits upward, optimize the internal application runtime engine, or configure target garbage collection limits to keep the process within healthy resource boundaries.
