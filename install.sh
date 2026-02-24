#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
REPO_URL="https://raw.githubusercontent.com/brdl-io/ai-dev/main/ai-dev.sh"

mkdir -p "${INSTALL_DIR}"
curl -fsSL "${REPO_URL}" -o "${INSTALL_DIR}/dev"
chmod +x "${INSTALL_DIR}/dev"

# Ensure ~/.local/bin is on PATH
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  SHELL_RC=""
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  SHELL_RC="${HOME}/.zshrc" ;;
    *)    SHELL_RC="${HOME}/.bashrc" ;;
  esac

  if [ -n "${SHELL_RC}" ] && ! grep -qF "${INSTALL_DIR}" "${SHELL_RC}" 2>/dev/null; then
    echo "export PATH=\"${INSTALL_DIR}:\${PATH}\"" >> "${SHELL_RC}"
    echo "Added ${INSTALL_DIR} to PATH in ${SHELL_RC}"
    echo "Run 'source ${SHELL_RC}' or open a new terminal to use 'dev'."
  fi
else
  echo "Done. You can now run 'dev' from anywhere."
fi
