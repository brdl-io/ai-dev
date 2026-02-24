#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev.sh — AI-powered development container launcher
#
# Builds and runs a Docker container with Claude Code and/or GitHub Copilot
# CLI pre-installed, with optional network firewall for sandboxed operation.
#
# Usage:
#   ./dev.sh [OPTIONS] [DIRECTORY]
#
# Arguments:
#   DIRECTORY               Path to mount as /workspace (default: current dir)
#
# Tool selection (at least one required, both enabled by default):
#   --claude-only           Install only Claude Code
#   --copilot-only          Install only GitHub Copilot CLI
#                           (default: both tools installed)
#
# Options:
#   --name NAME             Container name (default: ai-dev-<path-slug>)
#   --no-firewall           Skip firewall setup
#   --rebuild               Force rebuild the Docker image
#   --claude-version V      Claude Code npm version (default: latest)
#   --copilot-version V     Copilot CLI npm version (default: latest)
#   --delta-version V       git-delta version (default: 0.18.2)
#   --zsh-version V         zsh-in-docker version (default: 1.2.0)
#   --shell SHELL           Shell to launch: zsh or bash (default: zsh)
#   --dangerously-skip-permissions
#                           Launch claude with --dangerously-skip-permissions
#   --launch TOOL           Auto-launch tool on attach: claude or copilot
#   -h, --help              Show this help message
#
# Management:
#   --list                  List all ai-dev containers and their status
#   --stop-all              Stop all running ai-dev containers
#   --rm-all                Stop and remove all ai-dev containers
#
# Each unique workspace path automatically gets its own container and shell
# history. Config/auth volumes are shared across all containers. Running
# the script again for the same directory attaches to the existing container.
#
# Examples:
#   ./dev.sh                                # Both tools, current directory
#   ./dev.sh ~/work/api                     # → container "ai-dev-...-work-api"
#   ./dev.sh ~/personal/api                 # → different container (full path)
#   ./dev.sh --claude-only .                # Claude Code only
#   ./dev.sh --copilot-only ~/src/project   # Copilot CLI only
#   ./dev.sh --launch copilot .             # Both tools, auto-launch copilot
#   ./dev.sh --list                         # Show all ai-dev containers
#   ./dev.sh --stop-all                     # Stop everything
#   ./dev.sh --rm-all                       # Stop + remove everything
# =============================================================================

# ── Defaults ──────────────────────────────────────────────────────────────────

CONTAINER_NAME=""  # auto-derived from workspace dir unless --name is given
CONTAINER_NAME_EXPLICIT=false
IMAGE_NAME="ai-code-dev"
WORKSPACE_DIR=""
ENABLE_FIREWALL=true
FORCE_REBUILD=false
CLAUDE_CODE_VERSION="latest"
COPILOT_VERSION="latest"
GIT_DELTA_VERSION="0.18.2"
ZSH_IN_DOCKER_VERSION="1.2.0"
LAUNCH_SHELL="zsh"
SKIP_PERMISSIONS=false
TIMEZONE="${TZ:-UTC}"
INSTALL_CLAUDE=true
INSTALL_COPILOT=true
AUTO_LAUNCH=""  # "", "claude", or "copilot"

# ── Parse arguments ───────────────────────────────────────────────────────────

show_help() {
    sed -n '/^# Usage:/,/^# =====/p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            show_help ;;
        --list)
            echo "Running ai-dev containers:"
            docker ps --filter "name=^ai-dev-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
            echo ""
            echo "All ai-dev containers (including stopped):"
            docker ps -a --filter "name=^ai-dev-" --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || true
            exit 0
            ;;
        --stop-all)
            echo "Stopping all ai-dev containers..."
            RUNNING=$(docker ps --filter "name=^ai-dev-" --format '{{.Names}}' 2>/dev/null || true)
            if [[ -z "$RUNNING" ]]; then
                echo "  No running ai-dev containers found."
            else
                echo "$RUNNING" | while read -r name; do
                    echo "  Stopping $name..."
                    docker stop "$name" >/dev/null
                done
                echo "  Done."
            fi
            exit 0
            ;;
        --rm-all)
            echo "Stopping and removing all ai-dev containers..."
            ALL=$(docker ps -a --filter "name=^ai-dev-" --format '{{.Names}}' 2>/dev/null || true)
            if [[ -z "$ALL" ]]; then
                echo "  No ai-dev containers found."
            else
                echo "$ALL" | while read -r name; do
                    echo "  Removing $name..."
                    docker rm -f "$name" >/dev/null
                done
                echo "  Done."
            fi
            exit 0
            ;;
        --name)               CONTAINER_NAME="$2"; CONTAINER_NAME_EXPLICIT=true; shift 2 ;;
        --no-firewall)        ENABLE_FIREWALL=false; shift ;;
        --rebuild)            FORCE_REBUILD=true; shift ;;
        --claude-only)        INSTALL_CLAUDE=true; INSTALL_COPILOT=false; shift ;;
        --copilot-only)       INSTALL_CLAUDE=false; INSTALL_COPILOT=true; shift ;;
        --claude-version)     CLAUDE_CODE_VERSION="$2"; shift 2 ;;
        --copilot-version)    COPILOT_VERSION="$2"; shift 2 ;;
        --delta-version)      GIT_DELTA_VERSION="$2"; shift 2 ;;
        --zsh-version)        ZSH_IN_DOCKER_VERSION="$2"; shift 2 ;;
        --shell)              LAUNCH_SHELL="$2"; shift 2 ;;
        -dsp|--dangerously-skip-permissions) SKIP_PERMISSIONS=true; shift ;;
        -l|--launch)          AUTO_LAUNCH="$2"; shift 2 ;;
        -*)                   echo "Unknown option: $1" >&2; exit 1 ;;
        *)                    WORKSPACE_DIR="$1"; shift ;;
    esac
done

# Default workspace to current directory
WORKSPACE_DIR="${WORKSPACE_DIR:-.}"
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"

# Derive container name from full workspace path if not explicitly set.
# This ensures each unique directory gets its own container, even if
# two directories share the same basename (e.g. ~/work/api vs ~/personal/api).
# e.g. /home/user/projects/my-app → ai-dev-home-user-projects-my-app
if [[ "$CONTAINER_NAME_EXPLICIT" == false ]]; then
    WORKSPACE_SLUG="$(echo "$WORKSPACE_DIR" | sed 's|^/||' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')"
    CONTAINER_NAME="ai-dev-${WORKSPACE_SLUG}"
    # Docker container names have a max length — truncate if needed but keep
    # it deterministic by appending a short hash when truncated.
    if [[ ${#CONTAINER_NAME} -gt 128 ]]; then
        SHORT_HASH="$(echo "$WORKSPACE_DIR" | md5sum | cut -c1-8)"
        CONTAINER_NAME="${CONTAINER_NAME:0:119}-${SHORT_HASH}"
    fi
fi

# Validate auto-launch choice
if [[ -n "$AUTO_LAUNCH" ]]; then
    case "$AUTO_LAUNCH" in
        claude)
            if [[ "$INSTALL_CLAUDE" != true ]]; then
                echo "ERROR: --launch claude requires Claude Code (don't use --copilot-only)" >&2
                exit 1
            fi
            ;;
        copilot)
            if [[ "$INSTALL_COPILOT" != true ]]; then
                echo "ERROR: --launch copilot requires Copilot CLI (don't use --claude-only)" >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: --launch must be 'claude' or 'copilot'" >&2
            exit 1
            ;;
    esac
fi

# Build a tools label for display
TOOLS_LABEL=""
[[ "$INSTALL_CLAUDE" == true ]] && TOOLS_LABEL="Claude Code"
if [[ "$INSTALL_COPILOT" == true ]]; then
    [[ -n "$TOOLS_LABEL" ]] && TOOLS_LABEL="$TOOLS_LABEL + "
    TOOLS_LABEL="${TOOLS_LABEL}Copilot CLI"
fi

# Adjust image name based on tool selection to avoid cache conflicts
if [[ "$INSTALL_CLAUDE" == true && "$INSTALL_COPILOT" == true ]]; then
    IMAGE_NAME="ai-code-dev-both"
elif [[ "$INSTALL_CLAUDE" == true ]]; then
    IMAGE_NAME="ai-code-dev-claude"
else
    IMAGE_NAME="ai-code-dev-copilot"
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  AI Dev Container                                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Tools:        $TOOLS_LABEL"
echo "  Workspace:    $WORKSPACE_DIR"
echo "  Container:    $CONTAINER_NAME"
echo "  Firewall:     $ENABLE_FIREWALL"
echo "  Timezone:     $TIMEZONE"
echo ""

# ── Preflight checks ─────────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed or not in PATH." >&2
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running." >&2
    exit 1
fi

if [[ ! -d "$WORKSPACE_DIR" ]]; then
    echo "ERROR: Directory does not exist: $WORKSPACE_DIR" >&2
    exit 1
fi

# ── Attach helper (single source of truth for exec-into-container) ────────────

attach_to_container() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  Container ready. Dropping into $LAUNCH_SHELL..."
    echo "  Workspace mounted at /workspace"
    echo ""
    [[ "$INSTALL_CLAUDE" == true ]] && echo "  Run 'claude'  to start Claude Code."
    [[ "$INSTALL_COPILOT" == true ]] && echo "  Run 'copilot' to start GitHub Copilot CLI."
    if [[ "$SKIP_PERMISSIONS" == true ]]; then
    [[ "$INSTALL_CLAUDE" == true ]] && echo "  (claude will auto-launch with --dangerously-skip-permissions)"
    [[ "$INSTALL_COPILOT" == true ]] && echo "  (copilot will auto-launch with --allow-all-tools --allow-all-paths system)"
    fi
    echo ""
    echo "  Type 'exit' to detach (container keeps running)."
    echo "  'docker stop $CONTAINER_NAME' to stop."
    echo "  'docker rm $CONTAINER_NAME' to remove."
    echo "══════════════════════════════════════════════════════════════"
    echo ""

    if [[ "$AUTO_LAUNCH" == "claude" ]]; then
        exec docker exec -it -u node -w /workspace "$CONTAINER_NAME" \
            "$LAUNCH_SHELL" -c "$([[ "$SKIP_PERMISSIONS" == true ]] && echo "claude --dangerously-skip-permissions" || echo "claude")"
    elif [[ "$AUTO_LAUNCH" == "copilot" ]]; then
        exec docker exec -it -u node -w /workspace "$CONTAINER_NAME" \
            "$LAUNCH_SHELL" -c "$([[ "$SKIP_PERMISSIONS" == true ]] && echo "copilot --allow-all-tools --allow-all-paths" || echo "copilot")"
    else
        exec docker exec -it -u node -w /workspace "$CONTAINER_NAME" "$LAUNCH_SHELL"
    fi
}

# ── Check for existing container with same name ──────────────────────────────

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        echo "→ Container '$CONTAINER_NAME' is already running. Attaching..."
        attach_to_container
    else
        echo "→ Removing stopped container '$CONTAINER_NAME'..."
        docker rm "$CONTAINER_NAME" >/dev/null
    fi
fi

# ── Build image if needed ─────────────────────────────────────────────────────

build_image() {
    echo "→ Building image '$IMAGE_NAME' ($TOOLS_LABEL)..."

    local build_dir
    build_dir="$(mktemp -d)"
    trap "rm -rf '$build_dir'" RETURN

    # ── Dockerfile ────────────────────────────────────────────────────────
    cat > "$build_dir/Dockerfile" <<DOCKERFILE
FROM node:20

ARG TZ=UTC
ENV TZ="\$TZ"

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \\
  less \\
  git \\
  procps \\
  sudo \\
  fzf \\
  zsh \\
  man-db \\
  unzip \\
  gnupg2 \\
  gh \\
  iptables \\
  ipset \\
  iproute2 \\
  dnsutils \\
  aggregate \\
  jq \\
  nano \\
  vim \\
  curl \\
  wget \\
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \\
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \\
  && mkdir /commandhistory \\
  && touch /commandhistory/.bash_history \\
  && chown -R \$USERNAME /commandhistory

# Set DEVCONTAINER environment variable
ENV DEVCONTAINER=true

# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude /home/node/.copilot && \\
  chown -R node:node /workspace /home/node/.claude /home/node/.copilot

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=\$(dpkg --print-architecture) && \\
  wget "https://github.com/dandavison/delta/releases/download/\${GIT_DELTA_VERSION}/git-delta_\${GIT_DELTA_VERSION}_\${ARCH}.deb" && \\
  dpkg -i "git-delta_\${GIT_DELTA_VERSION}_\${ARCH}.deb" && \\
  rm "git-delta_\${GIT_DELTA_VERSION}_\${ARCH}.deb"

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=\$PATH:/usr/local/share/npm-global/bin

# Default shell and editor
ENV SHELL=/bin/zsh
ENV EDITOR=vim
ENV VISUAL=vim

# zsh + powerlevel10k via zsh-in-docker
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "\$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v\${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \\
  -p git \\
  -p fzf \\
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \\
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \\
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \\
  -x
DOCKERFILE

    # Conditionally install Claude Code
    if [[ "$INSTALL_CLAUDE" == true ]]; then
        cat >> "$build_dir/Dockerfile" <<DOCKERFILE

# Install Claude Code
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@\${CLAUDE_CODE_VERSION}
DOCKERFILE
    fi

    # Conditionally install Copilot CLI
    if [[ "$INSTALL_COPILOT" == true ]]; then
        cat >> "$build_dir/Dockerfile" <<DOCKERFILE

# Install GitHub Copilot CLI
ARG COPILOT_VERSION=latest
RUN npm install -g @github/copilot@\${COPILOT_VERSION}
DOCKERFILE
    fi

    # Firewall setup (always included — the script just won't run if --no-firewall)
    cat >> "$build_dir/Dockerfile" <<'DOCKERFILE'

# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

USER node
DOCKERFILE

    # ── init-firewall.sh ──────────────────────────────────────────────────
    cat > "$build_dir/init-firewall.sh" <<'FIREWALL'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve and add other allowed domains
# Includes domains needed by both Claude Code and GitHub Copilot CLI
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    "api.githubcopilot.com" \
    "copilot-proxy.githubusercontent.com" \
    "ghcr.io" \
    "objects.githubusercontent.com"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARNING: Failed to resolve $domain (skipping)"
        continue
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "WARNING: Invalid IP from DNS for $domain: $ip (skipping)"
            continue
        fi
        echo "Adding $ip for $domain"
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
FIREWALL

    # ── Build arguments ───────────────────────────────────────────────────
    local build_args=(
        --build-arg "TZ=$TIMEZONE"
        --build-arg "GIT_DELTA_VERSION=$GIT_DELTA_VERSION"
        --build-arg "ZSH_IN_DOCKER_VERSION=$ZSH_IN_DOCKER_VERSION"
    )
    [[ "$INSTALL_CLAUDE" == true ]]  && build_args+=(--build-arg "CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION")
    [[ "$INSTALL_COPILOT" == true ]] && build_args+=(--build-arg "COPILOT_VERSION=$COPILOT_VERSION")

    docker build "${build_args[@]}" -t "$IMAGE_NAME" "$build_dir"

    echo "→ Image '$IMAGE_NAME' built successfully."
}

# Build if image doesn't exist or rebuild requested
if [[ "$FORCE_REBUILD" == true ]] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    build_image
else
    echo "→ Using existing image '$IMAGE_NAME' (use --rebuild to force)."
fi

# ── Volume names ──────────────────────────────────────────────────────────────
# History is per-container (i.e. per workspace) so each project has its own
# shell history. Config volumes are shared across all containers so auth
# tokens, settings, etc. persist regardless of which project you're in.

HIST_VOLUME="${CONTAINER_NAME}-bashhistory"
CLAUDE_CONFIG_VOLUME="ai-dev-shared-claude-config"
COPILOT_CONFIG_VOLUME="ai-dev-shared-copilot-config"

for vol in "$HIST_VOLUME" "$CLAUDE_CONFIG_VOLUME" "$COPILOT_CONFIG_VOLUME"; do
    if ! docker volume inspect "$vol" &>/dev/null; then
        docker volume create "$vol" >/dev/null
        echo "→ Created volume: $vol"
    fi
done

# ── Run container ─────────────────────────────────────────────────────────────

RUN_ARGS=(
    --interactive --tty
    --name "$CONTAINER_NAME"
    --user node
    --workdir /workspace

    # Mount workspace
    --volume "$WORKSPACE_DIR:/workspace:delegated"

    # Persistent volumes
    --volume "$HIST_VOLUME:/commandhistory"
    --volume "$CLAUDE_CONFIG_VOLUME:/home/node/.claude"
    --volume "$COPILOT_CONFIG_VOLUME:/home/node/.copilot"

    # Environment variables
    --env "NODE_OPTIONS=--max-old-space-size=4096"
    --env "CLAUDE_CONFIG_DIR=/home/node/.claude"
    --env "POWERLEVEL9K_DISABLE_GITSTATUS=true"
    --env "TZ=$TIMEZONE"
)

# Pass through API keys / tokens if set on the host
[[ -n "${ANTHROPIC_API_KEY:-}" ]]  && RUN_ARGS+=(--env "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[[ -n "${GH_TOKEN:-}" ]]           && RUN_ARGS+=(--env "GH_TOKEN=$GH_TOKEN")
[[ -n "${GITHUB_TOKEN:-}" ]]       && RUN_ARGS+=(--env "GITHUB_TOKEN=$GITHUB_TOKEN")

# Firewall needs NET_ADMIN + NET_RAW capabilities
if [[ "$ENABLE_FIREWALL" == true ]]; then
    RUN_ARGS+=(
        --cap-add=NET_ADMIN
        --cap-add=NET_RAW
    )
fi

echo "→ Starting container '$CONTAINER_NAME'..."

# Start detached so we can run the firewall postStart step first
docker run -d "${RUN_ARGS[@]}" "$IMAGE_NAME" sleep infinity >/dev/null

# Run firewall setup (equivalent to devcontainer.json postStartCommand)
if [[ "$ENABLE_FIREWALL" == true ]]; then
    echo "→ Initializing firewall..."
    if docker exec -u root "$CONTAINER_NAME" /usr/local/bin/init-firewall.sh; then
        echo "→ Firewall initialized successfully."
    else
        echo "WARNING: Firewall setup failed. Container running without network restrictions." >&2
    fi
else
    echo "→ Firewall disabled, skipping."
fi

# ── Attach ────────────────────────────────────────────────────────────────────

attach_to_container