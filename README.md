# ai-dev
Containerized copilot and claude code cli

## Install

```bash
source <(curl -fsSL https://raw.githubusercontent.com/brdl-io/ai-dev/main/install.sh)
```

This installs `dev` to `~/.local/bin` and ensures it's on your PATH. After installation, run:

```bash
dev
```

## Basic Usage

```bash
dev                                # Both tools, current directory
dev ~/work/api                     # Mount a specific directory
dev --claude-only .                # Claude Code only
dev --copilot-only ~/src/project   # Copilot CLI only
dev --launch copilot .             # Both tools, auto-launch copilot
dev --no-firewall .                # Skip firewall setup
dev --rebuild .                    # Force rebuild the Docker image
```

## Container Management

```bash
dev --list                         # Show all ai-dev containers
dev --stop-all                     # Stop all running containers
dev --rm-all                       # Stop + remove all containers
```
