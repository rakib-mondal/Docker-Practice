# Docker Deep Dive — Image Layers, Custom Images & Docker Networking

> Lecture notes compiled from live session transcript + whiteboard/architecture diagrams.
> Covers: Docker image layers, Dockerfile-to-image build process, custom image creation (Nginx + index.html), image inspection commands, VM networking fundamentals (NAT vs Bridge), Docker CNM, network drivers, `docker0`, and custom bridge network configuration.

---

## Table of Contents

1. [Docker Image Layers — Concept](#1-docker-image-layers--concept)
2. [How `docker build` Actually Works (Step-by-Step)](#2-how-docker-build-actually-works-step-by-step)
3. [Clearing Common Doubts](#3-clearing-common-doubts)
4. [Hands-on: Custom Dockerfile with Nginx + index.html](#4-hands-on-custom-dockerfile-with-nginx--indexhtml)
5. [Image Inspection Commands](#5-image-inspection-commands)
6. [VM Networking Fundamentals (NAT vs Bridge)](#6-vm-networking-fundamentals-nat-vs-bridge)
7. [Docker Networking — SDN & CNM](#7-docker-networking--sdn--cnm)
8. [Docker Network Drivers](#8-docker-network-drivers)
9. [Docker Networking Architecture (Diagram Explained)](#9-docker-networking-architecture-diagram-explained)
10. [`docker0` — The Default Bridge, In Depth](#10-docker0--the-default-bridge-in-depth)
11. [Working with `docker network` Commands](#11-working-with-docker-network-commands)
12. [Creating a Custom Bridge Network](#12-creating-a-custom-bridge-network)
13. [Command Cheat Sheet](#13-command-cheat-sheet)
14. [Interview Questions & Answers](#14-interview-questions--answers)

---

## 1. Docker Image Layers — Concept

**Why do we even need a custom Docker image?**

Before a container is deployed, the underlying OS, application files, dependencies, and configuration must all be bundled together into an **image**. Once an image is built, it is **immutable** — it cannot be modified. If you need to change something, you edit the **Dockerfile** and build a **new version** of the image (e.g., `v1` → `v2`).

> Once an image is created, the image **cannot** be modified. The Dockerfile can be edited, and a **new image** can be built from the updated Dockerfile.

### Key Concept: Images Are Read-Only

| Layer type | Mutable? | Belongs to |
|---|---|---|
| Image layers (base OS layer, each instruction's layer) | ❌ Read-only | Image |
| Container layer (created when you `docker run`) | ✅ Read-write | Container |

Every instruction in a Dockerfile (`FROM`, `RUN`, `COPY`, `ADD`, `ENV`, etc.) produces its **own read-only layer**. When you finally run a container from that image, Docker adds one **thin writable layer** on top — this is the only place where runtime changes (installing a package inside a running container, writing a file, etc.) actually get stored.

---

## 2. How `docker build` Actually Works (Step-by-Step)

This was explained with a worked example: building a custom Ubuntu-based image with MySQL, some CLI tools, and Python.

### The Dockerfile (conceptual example)

```dockerfile
FROM ubuntu:22.04
LABEL maintainer="devops-team"

RUN apt-get update && \
    apt-get install -y mysql-server tree python3 python3-pip

ENV APP_ENV=production

COPY . /app
```

### What happens internally when you run `docker build -t image_name .`

For **every single instruction**, Docker:
1. Spins up a **temporary intermediate container** using the previous layer as its base image.
2. Executes **only that one instruction** inside it.
3. Commits the *result* of that instruction as a new **read-only image layer**.
4. **Deletes** the intermediate container immediately (it is never persistent).
5. Uses this new layer as the base image for the **next** intermediate container, and repeats.

### Worked size example from the lecture

| Step | Instruction | What happens | Cumulative layer size |
|---|---|---|---|
| Layer 0 | `FROM ubuntu` | Pulls base Ubuntu image | ~150 MB |
| Layer 1 | `RUN apt-get update` | Downloads package index (~30 MB) | 150 + 30 = **180 MB** |
| Layer 2 | `RUN apt-get install mysql tree python...` | Installs packages (~150 MB) | 180 + 150 = **330 MB** |
| Layer 3 | `ENV ...` | Sets environment variables | 330 MB (+ negligible) |
| Layer 4 | `COPY . /app` | Copies application files | Final image size |

**Final image = sum of all read-only layers stacked together**, tagged with the name/version you specified (e.g., `myapp:v1`).

### Diagram — Layered Build Process

```
 docker build -t myapp:v1 .
 ────────────────────────────────────────────────────────────

 Dockerfile:
   FROM ubuntu          RUN apt-get update      RUN apt-get install ...   ENV APP_ENV=prod     COPY . /app
        │                       │                        │                       │                   │
        ▼                       ▼                        ▼                       ▼                   ▼
 ┌─────────────┐        ┌───────────────┐        ┌────────────────┐     ┌───────────────┐   ┌────────────────┐
 │ Intermediate│        │  Intermediate │        │  Intermediate   │     │  Intermediate │   │  Intermediate  │
 │ Container 1 │──────▶│  Container 2   │──────▶│  Container 3    │────▶│  Container 4  │──▶│  Container 5   │
 │ (pulls base)│  exec  │ (runs update) │  exec  │ (installs pkgs) │exec │ (sets env)    │exec│ (copies files)│
 └─────────────┘        └───────────────┘        └────────────────┘     └───────────────┘   └────────────────┘
        │  commit & delete       │ commit & delete         │ commit & delete       │ commit & delete    │ commit & delete
        ▼                        ▼                         ▼                        ▼                    ▼
   [ Layer 0 ]              [ Layer 1 ]               [ Layer 2 ]              [ Layer 3 ]          [ Layer 4 = FINAL IMAGE ]
   Ubuntu base              +apt update                +packages                +env config          myapp:v1 (read-only)
   ~150 MB                  180 MB                      330 MB                   330 MB               tagged & stored
```

Each **intermediate container exists only long enough to execute one instruction**, then it is deleted — its filesystem diff becomes the new read-only layer. This is exactly why Docker builds are so fast on rebuilds: unchanged layers are cached and reused (Docker only re-executes instructions from the point where the Dockerfile actually changed).

> 💡 You can verify this yourself at `docs.docker.com` → *Engine → Storage Drivers → Images and Layers* — official Docker docs show the exact same incremental size growth per instruction.

### Does instruction *order* matter?

Mostly no — you don't need to follow a strict protocol for *which* package goes in *which* layer. The only rule that matters: **dependency order**. E.g., you can't configure MySQL environment variables (`ENV`) *before* MySQL is actually installed — that step would be meaningless. Beyond that, ordering is a best-practice/optimization concern (put rarely-changing instructions first to maximize layer-cache reuse), not a hard protocol.

---

## 3. Clearing Common Doubts

### ❓ Doubt 1: "If I install packages/libraries inside a *running container*, do those changes get reflected back into the *image* it was created from?"

**No.** The image is completely locked/read-only. Any changes you make inside a running container (installing packages, writing files, editing configs) live **only in that container's writable layer**. The original image is untouched. If the container is deleted, those changes are lost — unless you explicitly persist them (see below).

### ❓ Doubt 2: "Can we create images *from* containers?"

**Yes** — this wasn't demoed in this session, but it's a standard and important workflow:

```bash
# Make changes inside a running container, then snapshot it into a new image
docker commit <container_id_or_name> new_image_name:tag

# Example
docker commit web10 my_customized_nginx:v1
```

`docker commit` takes the container's current writable layer and freezes it as a new read-only image layer on top of its original base — effectively turning ad-hoc container changes into a reusable image. (Best practice is still to encode changes in a **Dockerfile** for reproducibility, but `commit` is valid for quick snapshots or debugging.)

### ❓ Doubt 3: "Does the `FROM` instruction always need to pull an underlying OS?"

**No.** `FROM` can point to:
- A public **OS base image** (`ubuntu`, `alpine`, etc.)
- A public **application image** directly (`mysql`, `nginx`, etc. — these already have an OS baked in)
- A **previously built custom image** of your own (multi-stage / layered custom builds)

Either way, `FROM` is *mandatory* — you always need to declare some base image to build on top of.

---

## 4. Hands-on: Custom Dockerfile with Nginx + index.html

### Step 1 — Create the application file

```bash
vi index.html
```
```html
<!DOCTYPE html>
<html>
  <head><title>My Custom App</title></head>
  <body><h1>Hello from my custom Nginx image!</h1></body>
</html>
```

### Step 2 — Create the Dockerfile (same folder as `index.html`)

```bash
vi dockerfile
```
```dockerfile
FROM nginx:latest

RUN apt-get update -y

# Create a working directory inside the image
RUN mkdir -p /test

# COPY: copies a file from your LOCAL build context into the image
COPY index.html /test/index.html

# ADD: same as COPY, but can ALSO fetch from a remote URL (COPY cannot)
ADD https://<your-s3-bucket-url>/index.html /test/index2.html

# Expose ports (comma-separated / repeated instructions both work)
EXPOSE 80,443
```

### `COPY` vs `ADD` — the key difference

| Instruction | Source | Notes |
|---|---|---|
| `COPY` | Local build-context path only | Simple, predictable — preferred for most use cases |
| `ADD` | Local path **or** a remote URL (e.g., an S3 object URL) | Can also auto-extract local `.tar` archives — extra "magic" behavior, use only when you specifically need URL/archive handling |

### Step 3 — Build the image

```bash
# Best-practice explicit syntax
docker image build -t new_app_image:2.5 .

# Docker is smart enough to infer "build" = images and "run" = containers,
# so the shorter form also works:
docker build -t new_app_image:2.5 .
```

> 🐢 First build of an image (pulling `nginx` fresh from Docker Hub) takes longer. 🐇 Subsequent builds are fast because Docker reuses the **already-pulled base image from the local repository** instead of re-downloading it, and reuses unchanged cached layers.

### Step 4 — Run a container from your custom image

```bash
docker run -itd --name web10 -p 8008:80 new_app_image:2.5

# Test it directly from inside the container
docker exec -it web10 curl localhost
```

### Step 5 — Verify the copied files persisted in the image layer

```bash
docker exec -it web10 bash
ls
cd test
ls          # index.html / index2.html should be here — baked into the image
```

Because this file is now **part of the image's read-only layer**, *every* container created from this image (whether you spin up 1 or 100 of them) will have this file pre-loaded and identical — that's the whole point of building a custom image: **consistent, predefined configuration across every container instance.**

---

## 5. Image Inspection Commands

```bash
# List all local images
docker images
docker image ls

# List all containers
docker ps                 # running only
docker ps -a               # all (including stopped)
docker container ls

# Full JSON metadata about an image — includes the ordered list of layers
docker inspect image new_app_image:2.5
docker image inspect new_app_image:2.5

# Human-readable build history — shows every instruction + layer size + timestamp
docker image history new_app_image:2.5
```

**Interesting detail seen live:** running `docker image history` on a freshly built custom image showed entries timestamped **"5 days ago"** even though the image was built minutes earlier. That's because the *base* `nginx` public image's own layers (whatever Nginx's maintainers last updated on Docker Hub) get listed too — history is inherited all the way down the layer chain, not just from your own instructions.

```bash
# Cleanup commands used in the session
docker rm <container_name>          # remove a stopped container
docker rm -f <container_name>       # force remove (works even if running)
docker rm -f $(docker ps -aq)       # remove ALL containers at once
```

---

## 6. VM Networking Fundamentals (NAT vs Bridge)

Understanding VM networking first makes Docker networking click immediately — Docker's model is conceptually the same idea, just software-defined and container-scoped.

### Physical Setup

Two physical hosts (or VMs), each with a NIC connected to a **switch** for LAN connectivity — standard networking, no surprises here.

### The VM Layer

On top of a physical host, when you run VMware Workstation / Hyper-V and spin up multiple VMs, **each VM gets a virtual NIC (vNIC)** with its own identity — a MAC address and an IP address.

- VM-to-VM communication **within the same host** → always works fine, uses each VM's own identity directly (no translation needed).
- VM-to-**external network** communication → depends on which mode the vNIC is configured with: **NAT** or **Bridge**.

### Bridge Mode

- The VM uses **its own MAC + IP identity** when talking to the external network.
- Other systems on the network see and address the VM directly, as if it were its own physical device.
- Works well for **internal/enterprise networks** with private DNS and no need for public internet access.
- ⚠️ If you enable Bridge mode without a proper DHCP/network setup, the VM typically **loses public internet connectivity**.

### NAT Mode

- All traffic from the VM is routed through the **physical NIC**, where **Network Address Translation** occurs.
- The VM's outgoing packets get **re-labeled with the host's own MAC + IP** before leaving the physical NIC.
- The external network only ever sees the **host's identity** — it has no idea the VM even exists as a separate entity.
- ✅ **Recommended default** for VMs that need public internet/DNS access.

### Diagram

```
                        BRIDGE MODE                                   NAT MODE
   ┌────────────┐                                     ┌────────────┐
   │   VM  (own  │  MAC:AA  IP:192.168.1.10            │   VM  (own  │  MAC:AA  IP:192.168.1.10
   │  identity)  │────────────────────┐                │  identity)  │───────────┐
   └────────────┘                     │                └────────────┘            │
                                        ▼                                          ▼
                              [ Physical NIC ]  ───▶ External Network      [ Physical NIC + NAT ]
                              passes VM's own                              rewrites src MAC/IP
                              MAC/IP unchanged                             to HOST's own MAC/IP
                                        │                                          │
                              External network sees:                    External network sees:
                              MAC:AA  IP:192.168.1.10  (the VM itself)   MAC:Host IP:Host  (VM is hidden)
```

| | Bridge | NAT |
|---|---|---|
| Identity seen externally | VM's own MAC/IP | Host's MAC/IP (translated) |
| Best for | Internal/enterprise networks, no public DNS needed | Public internet access, general-purpose default |
| Internet access out-of-the-box | ❌ Often broken without extra config | ✅ Works by default |

---

## 7. Docker Networking — SDN & CNM

### It's all Software-Defined

> **Docker networking is purely SDN (Software-Defined Networking).** There are no physical network appliances involved *inside* Docker — everything (bridges, endpoints, IPAM) is virtual/software-based.

### CNM — Container Network Model

- **CNM (Container Network Model)** is the **open standard** that **Docker** uses for networking.
- It is supported by all container engines that adopt it.
- **Kubernetes does NOT use CNM.** Kubernetes uses a *different* standard: **CNI (Container Network Interface)**.

| | Docker | Kubernetes |
|---|---|---|
| Networking standard | **CNM** — Container Network Model | **CNI** — Container Network Interface |
| Built-in network drivers? | ✅ Yes, installed automatically with Docker | ❌ No — plugins must be installed manually (e.g., Calico, Flannel, WeaveNet) |

> 🎯 **Common interview one-liner:** *"Docker uses CNM (Container Network Model), Kubernetes uses CNI (Container Network Interface)."*

---

## 8. Docker Network Drivers

When Docker is installed, it comes with **default built-in network drivers** — no manual setup needed (unlike Kubernetes, where you must install network plugins yourself).

### Single-Host Drivers (available by default)

| Driver | Purpose |
|---|---|
| **bridge** ⭐ | **The most important driver.** Default driver for container-to-container communication on a single host. |
| **host** | Container shares the host's network namespace directly (no isolation). |
| **null (none)** | No networking at all — fully isolated container. |

### Multi-Host / Swarm (Cluster) Drivers

These only appear/activate once you enable **Docker Swarm** (a multi-host Docker cluster):

| Driver | Purpose |
|---|---|
| **overlay** ⭐ | The most important driver in a **Swarm/cluster** setup — enables container-to-container communication *across different Docker hosts*. |
| **macvlan** | Assigns a container its own MAC address, making it appear as a physical device on the network. |
| **ipvlan** | Similar to macvlan but shares the same MAC, splits by IP layer instead. |

> 🎯 **Rule of thumb for interviews:**
> - **Single host → `bridge`** is the default/most important driver.
> - **Swarm/cluster (multi-host) → `overlay`** becomes the important driver.

### Kubernetes side note (mentioned for contrast)

Kubernetes has **no default network drivers**. You must install a CNI plugin manually, compatible with your K8s + Linux version. Popular CNI plugins: **Calico, Flannel, WeaveNet**.

```bash
# See default Docker network drivers on a fresh single-host install
docker network ls
# NETWORK ID     NAME      DRIVER    SCOPE
# xxxxxxxxxxxx   bridge    bridge    local
# xxxxxxxxxxxx   host      host      local
# xxxxxxxxxxxx   none      null      local
```

---

## 9. Docker Networking Architecture (Diagram Explained)

![Docker CNM Architecture](images/docker-cnm-architecture.png)

This is the standard architecture diagram used to explain Docker's CNM model, layer by layer (bottom → top):

1. **Network Infrastructure** *(gray, bottom)* — the physical network: switches, physical NICs, cabling. Exists regardless of whether Docker is installed.
2. **Network Driver** *(dark blue)* — this is the **VM's or physical host's own NIC** (e.g., `ens33` / `eth0`). This has **nothing to do with Docker** — it exists at the OS/hardware level, Docker just sits on top of it and uses it.
3. **IPAM Driver** — **IP Address Management** driver, installed automatically alongside Docker at install time. Responsible for allocating IP ranges/addresses to Docker's own networks.
4. **Docker Engine** *(teal)* — the Docker daemon itself.
5. **Network (light/dark blue, above Docker Engine)** — this is a **Docker network driver** (bridge, host, overlay, etc.) — fully controlled *by* Docker, distinct from the host's physical network driver below it.
6. **Endpoint** — the connection point between a container's network sandbox and the Docker network driver (this is the `veth` interface in Linux terms).
7. **Network Sandbox / Container** *(top)* — each container gets its own **isolated network environment** — just like a VM gets its own vNIC, every container gets its **own network namespace and virtual NIC**.

### Two categories of "NIC" you need to mentally separate

| Layer | Example | Controlled by |
|---|---|---|
| Physical/VM NIC | `ens33`, `eth0` | The OS / hypervisor — exists with or without Docker |
| Docker network driver | `docker0` (bridge), overlay, etc. | Docker Engine — created at Docker install time |
| Container endpoint | `veth0`, `veth1`... | Docker — one per container, connects container ↔ bridge |

> Containers **never talk directly to the host's physical network driver.** They always go through the **Docker network driver** first. The Docker network driver, in turn, uses the physical/VM NIC to reach the outside world.

---

## 10. `docker0` — The Default Bridge, In Depth

The moment Docker is installed, it automatically creates the **default bridge network**, which shows up at the OS level as an interface literally named **`docker0`**.

```bash
ifconfig
# lo        — loopback adapter (every Linux system has this)
# ens33     — the VM/physical host's own NIC (this is "eth0" conceptually)
# docker0   — Docker's default BRIDGE driver  ← created automatically on install
```

- **`docker0` = the default bridge driver.** Whenever you create a container *without* explicitly specifying `--network`, it automatically attaches to `docker0`.
- `docker0` gets assigned an IP range by the **IPAM driver** — typically **`172.17.0.1/16`**, with `.1` reserved as the **gateway**.

### How container IPs get assigned

```
IPAM assigns range 172.17.0.0/16 to docker0
        │
        ▼
docker0 (gateway = 172.17.0.1)
        │
   ┌────┼────┬────────────┐
   ▼         ▼            ▼
Container1  Container2   Container3
172.17.0.2  172.17.0.3   172.17.0.4
```

> **IPAM → assigns the range to the bridge. Bridge → hands out individual IPs (sequentially) to each container that joins it, using that range.**

### Endpoints (`veth`) — what you see from the *host* side

Every container gets its own **endpoint**, shown on the host as `veth0`, `veth1`, `veth2`, etc. (one per running container).

```bash
ifconfig
# You'll see extra "vethXXXXXXX" interfaces appear —
# one new veth interface per running container.
```

⚠️ **Important nuance:** these `veth*` interfaces do **not** show an IPv4 address when you run `ifconfig` on the host — they may show an IPv6 link-local address, but **never IPv4**. That's because a `veth` is just a **connection/endpoint**, not the container's actual network interface. The container's *own* NIC (with its actual IP) is only visible **from inside the container**.

### Two ways to check a container's IP address

**Method 1 — Get inside the container:**
```bash
docker exec -it <container_name> bash
apt update && apt install -y net-tools   # if ifconfig isn't installed
ifconfig
# Shows eth0 (or ens33-style name) with the actual container IP, e.g. 172.17.0.2
```

**Method 2 — Inspect from the host (no need to enter the container):**
```bash
docker network inspect bridge
# Lists ALL containers on this network + their assigned IPs in one shot
```

### Hand-drawn architecture recap (from the whiteboard)

![docker0 bridge whiteboard diagram](images/docker0-bridge-handdrawn.png)

Reading the whiteboard diagram:
- **`Host - Linux`** at the bottom, with a **NIC (`eth0`)** connecting out to a physical **Switch**.
- **`Docker`** engine sits on top of the host Linux, with an **`IPAM`** module attached to it.
- **`docker0` (default bridge)** sits above the Docker engine — this is the default gateway (`172.17.0.1`).
- Three containers (`C1`, `C2`, `C3`) connect to `docker0` via their respective **endpoints** — labeled `veth0`, `veth1`, `veth2` on the host side (with `NIC` denoting the container's internal `eth0`).
- Container IPs shown: `172.17.0.2`, `172.17.0.3`, `172.17.0.4` — sequential allocation from IPAM within the `docker0` range.
- A separate custom bridge is also shown with its own range `172.17.0.4`-style addressing (illustrating that a **second bridge = a second isolated IP range entirely**), with a note: `veth2 — no IP call` (i.e., a `veth` endpoint itself carries **no IPv4 address**, reinforcing the point above).

---

## 11. Working with `docker network` Commands

```bash
# List all networks (drivers) currently available
docker network ls

# Inspect a specific network — shows subnet, gateway, and every connected
# container with its assigned IP address
docker network inspect bridge
docker network inspect <network_name_or_id>

# Get details about running containers
docker ps
```

### Why isolate applications with custom networks?

Just like in a real datacenter you'd put your **web tier** and **DB tier** on separate network segments/VLANs, in Docker you can (and should, for anything beyond a toy setup) put different application tiers on **separate custom bridge networks**:

```
 Default bridge (docker0) — 172.17.0.0/16          Custom bridge "mybridge" — 172.18.0.0/16
 ┌───────────────────────────────┐                  ┌───────────────────────────────┐
 │  Web App Containers            │                  │  DB App Containers (replicas)  │
 │  C1: 172.17.0.2                │                  │  C1: 172.18.0.2                │
 │  C2: 172.17.0.3                │                  │  C2: 172.18.0.3                │
 └───────────────────────────────┘                  │  C3: 172.18.0.4                │
                                                       └───────────────────────────────┘
```

> **By default, containers on two different bridge networks CANNOT communicate with each other** — even with a simple `ping`. This is intentional network isolation.
>
> If cross-network communication is genuinely needed, you can **connect a specific container to multiple networks/bridges** (it then holds two IP addresses, one per network, and can talk to both sides).

```bash
# Connect an already-running container to a second network
docker network connect <second_network_name> <container_name>
```

> 💬 As one participant summarized it well: **"The bridge is basically acting like a switch."** — Precisely correct. Each custom bridge behaves like its own isolated virtual switch/segment.

---

## 12. Creating a Custom Bridge Network

### Basic custom bridge (auto-assigned subnet via IPAM)

```bash
docker network create mybridge100
```
- You don't even need to specify `--driver bridge` explicitly — **bridge is the default driver** if none is specified.
- IPAM will auto-assign the next available range (e.g., if `docker0` already has `172.17.0.0/16`, this new bridge might get `172.18.0.0/16`).
- On the host, this shows up as a new interface prefixed **`br-`** followed by the network's unique ID (NOT the friendly name — Linux only understands it as a NIC, so it identifies it by ID; only the `docker network` command layer resolves it back to `mybridge100`).

```bash
# Confirm it was created
docker network ls

# See the new br-xxxxxxxxxxxx interface at the OS level
ifconfig
```

### Attach containers to the custom bridge

```bash
docker run -itd --name webser10 --network mybridge100 nginx
docker run -itd --name webser20 --network mybridge100 nginx
```

```bash
# Confirm both containers + their IPs (sequential from the bridge's range)
docker network inspect mybridge100
```

### Custom bridge with a MANUALLY specified subnet + gateway

If you don't want Docker/IPAM to auto-pick the next `172.x.0.0/16` range, you can fully control it:

```bash
docker network create mybridge200 \
  --subnet 10.0.0.0/16 \
  --gateway 10.0.0.1
```

```bash
docker network ls
docker network inspect mybridge200
# subnet -> 10.0.0.0/16
# gateway -> 10.0.0.1
```

### Add containers to this manually-configured network

```bash
docker run -itd --name dbserver10 --network mybridge200 alpine
docker run -itd --name dbserver20 --network mybridge200 alpine
```

```bash
docker ps
docker network inspect mybridge200
# dbserver10 -> 10.0.0.2
# dbserver20 -> 10.0.0.3
```

### Static / manually-pinned IP for a specific container

If you don't want IPAM's sequential auto-assignment for a particular container (e.g., a DB master node that other services need to reliably reach at a fixed address):

```bash
docker run -itd --name dbmaster --network mybridge200 --ip 10.0.0.10 alpine
```

> This is a common real-world pattern: give a **master/primary node a static, predictable IP**, while replicas/workers get sequential auto-assigned IPs from IPAM.

### Full worked example recap

```bash
# 1. Create a custom bridge with explicit subnet + gateway
docker network create mybridge200 --subnet 10.0.0.0/16 --gateway 10.0.0.1

# 2. Verify
docker network ls
docker network inspect mybridge200

# 3. Launch containers onto it
docker run -itd --name dbserver10 --network mybridge200 alpine
docker run -itd --name dbserver20 --network mybridge200 alpine

# 4. Confirm all 4 containers total (2 on default bridge/mybridge100 + 2 here)
docker ps

# 5. Confirm IP allocation
docker network inspect mybridge200
```

---

## 13. Command Cheat Sheet

### Images
```bash
docker build -t <image_name>:<tag> .          # build image from Dockerfile in current dir
docker image build -t <image_name>:<tag> .    # explicit/best-practice form
docker images                                 # list images
docker image ls
docker inspect image <image_name>             # full layer/config metadata
docker image history <image_name>             # per-instruction layer history
docker commit <container> <new_image_name>    # snapshot a container into a new image
docker rmi <image_name>                       # remove an image
```

### Containers
```bash
docker run -itd --name <name> <image>                         # run detached container
docker run -itd --name <name> -p <host_port>:<container_port> <image>
docker ps                                                       # running containers
docker ps -a                                                    # all containers
docker exec -it <container> bash                                # shell into container
docker rm <container>                                           # remove stopped container
docker rm -f <container>                                        # force remove (running too)
docker rm -f $(docker ps -aq)                                   # remove ALL containers
```

### Networking
```bash
docker network ls                                                # list all networks/drivers
docker network create <name>                                     # create bridge network (auto subnet)
docker network create <name> --subnet <CIDR> --gateway <IP>      # create with manual subnet/gateway
docker network inspect <name>                                    # subnet, gateway, connected containers + IPs
docker network connect <network> <container>                     # attach a container to another network
docker network disconnect <network> <container>                  # detach
docker run -itd --name <name> --network <net_name> <image>       # run container on a specific network
docker run -itd --name <name> --network <net_name> --ip <ip> <image>  # run with a static IP
ifconfig                                                          # see docker0 / br-xxxx / veth* on the host
```

---

## 14. Interview Questions & Answers

### Docker Images & Dockerfile

**Q1. Are Docker images mutable or immutable?**
A: Immutable/read-only. Once built, an image cannot be modified. Any change requires editing the Dockerfile and building a new image (a new version/tag).

**Q2. What happens internally when you run `docker build`?**
A: Docker reads the Dockerfile and, for **each instruction**, creates a temporary intermediate container, executes that single instruction inside it, commits the result as a new read-only layer, then deletes the intermediate container. The final layer becomes the tagged image.

**Q3. If I install a package or change a file inside a running container, does it affect the image it came from?**
A: No. Changes made inside a running container only exist in that container's writable layer. The image's read-only layers remain untouched. To persist those changes as a reusable image, use `docker commit` or better, encode the change in the Dockerfile and rebuild.

**Q4. Can you create a Docker image from an existing container?**
A: Yes, using `docker commit <container> <new_image>:<tag>`. This freezes the container's current writable-layer state into a new image layer.

**Q5. What is the difference between `COPY` and `ADD` in a Dockerfile?**
A: `COPY` copies files/directories only from the local build context into the image. `ADD` can do everything `COPY` does, plus it can fetch files from a **remote URL** and can **auto-extract** local tar archives. Best practice: prefer `COPY` unless you specifically need `ADD`'s extra behavior.

**Q6. Why are Docker image layers cached, and why does rebuilding an image (with an already-pulled base) go faster the second time?**
A: Docker caches each layer. On rebuild, if a layer's instruction and its inputs haven't changed, Docker reuses the cached layer instead of re-executing it. Also, if the base image (e.g., `nginx`) is already present locally, Docker skips re-downloading it from Docker Hub.

**Q7. Does the order of instructions in a Dockerfile matter?**
A: Generally you have flexibility, but **dependency order matters** — e.g., you can't set environment variables for an application before that application is installed. Beyond hard dependencies, ordering is mainly a caching/optimization concern.

**Q8. Is the `FROM` instruction mandatory, and what can it point to?**
A: Yes, it's mandatory — every Dockerfile needs a base. It can point to a plain OS base image (`ubuntu`), a ready application image (`mysql`, `nginx`), or a previously built custom image of your own.

**Q9. What's the difference between an image layer and a container layer?**
A: Image layers are read-only and shared across all containers created from that image. The container layer is a single writable layer created per-container at runtime, where all runtime changes are stored.

---

### Docker Networking

**Q10. What network model does Docker use, and how is it different from Kubernetes?**
A: Docker uses **CNM (Container Network Model)**, an open standard. Kubernetes uses a different standard, **CNI (Container Network Interface)**. Docker ships with built-in network drivers by default; Kubernetes requires manually installing CNI plugins (e.g., Calico, Flannel, WeaveNet).

**Q11. What is Docker networking built on, conceptually?**
A: It's purely **Software-Defined Networking (SDN)** — no physical appliances involved; bridges, endpoints, and IPAM are all software constructs managed by the Docker engine.

**Q12. What are the default network drivers available on a single Docker host?**
A: `bridge` (default, most important for single host), `host`, and `none` (null). Three more drivers — `overlay`, `macvlan`, `ipvlan` — become relevant once you enable **Docker Swarm** (multi-host cluster), with `overlay` being the key driver there for cross-host container communication.

**Q13. What is `docker0`?**
A: `docker0` is the name of Docker's **default bridge network interface**, automatically created at Docker install time. Any container launched without an explicit `--network` flag attaches to it. It typically gets the `172.17.0.0/16` range with `172.17.0.1` as gateway.

**Q14. What is the IPAM driver responsible for?**
A: IP Address Management — it's installed automatically with Docker and is responsible for allocating subnet ranges to each network/bridge, and then assigning individual IP addresses to containers as they join that network.

**Q15. What is a `veth` interface, and does it have an IP address?**
A: A `veth` (virtual Ethernet) interface is the **endpoint** connecting a container's network namespace to a Docker bridge — visible on the host side as `vethXXXXXXX`. It does **not** carry an IPv4 address of its own; it's purely a connection/link. The container's actual IP is on its internal interface, visible only from inside the container (or via `docker network inspect`).

**Q16. Can two containers on two different Docker bridge networks communicate by default?**
A: No. Different bridge networks are isolated by default — different subnets, no automatic routing between them. To allow communication, you must explicitly connect a container to both networks (`docker network connect`), giving it two IP addresses.

**Q17. How do you create a custom Docker bridge network with a specific subnet and gateway?**
A:
```bash
docker network create mynet --subnet 10.0.0.0/16 --gateway 10.0.0.1
```

**Q18. How do you assign a static IP address to a specific container?**
A:
```bash
docker run -itd --name mycontainer --network mynet --ip 10.0.0.10 <image>
```

**Q19. How can you check which IP address is assigned to each container on a network without entering the container?**
A:
```bash
docker network inspect <network_name>
```
This lists every connected container and its assigned IP in one command.

**Q20. Why would you create multiple custom bridge networks instead of using the default one for everything?**
A: For isolation and organization — e.g., separating web-tier containers from DB-tier containers onto different subnets, mimicking how you'd segment VLANs for different application tiers in a traditional data center. It limits blast radius and unwanted cross-talk between unrelated services.

**Q21. What is the difference between NAT and Bridge mode in VM networking (and how does it map conceptually to Docker)?**
A: In **Bridge** mode, a VM uses its own MAC/IP identity directly on the external network. In **NAT** mode, the VM's traffic is translated to use the host's own MAC/IP when leaving the physical NIC, hiding the VM's identity from the outside network. Conceptually, Docker's bridge network plays a similar "internal switch" role — containers get their own internal identity (IP) via the bridge, and the bridge/host manages how that traffic reaches the outside world.

**Q22. Why doesn't Kubernetes have built-in network drivers like Docker does?**
A: Kubernetes is designed to be pluggable and cloud/infra-agnostic — it delegates networking entirely to CNI plugins, which must be chosen and installed based on the specific K8s version, Linux distribution, and infrastructure compatibility requirements.

---

## Quick Recap Summary

- **Images are immutable** — every Dockerfile instruction creates a temporary intermediate container → executes → commits a read-only layer → deletes the container.
- **Container writable layer** is the only place runtime changes live; use `docker commit` or rebuild the Dockerfile to persist them into a real image.
- **`COPY`** = local only. **`ADD`** = local + remote URL + auto-extract.
- Docker networking = **SDN**, standardized via **CNM** (vs Kubernetes' **CNI**).
- Single host defaults: **bridge, host, none**. Swarm/cluster adds: **overlay, macvlan, ipvlan**.
- **`docker0`** = default bridge, gets IP range from **IPAM**, gateway = `.1` of that range.
- **`veth*`** = per-container endpoint, no IPv4 of its own — just a link between container and bridge.
- Different bridge networks are **isolated by default**; connect a container to multiple networks if cross-talk is needed.
- Custom bridges: `docker network create <name> [--subnet CIDR --gateway IP]`, containers join via `--network <name>`, static IP via `--ip <ip>`.
