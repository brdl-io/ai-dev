#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
REPO_URL="https://raw.githubusercontent.com/brdl-io/ai-dev/main/ai-dev.sh"

mkdir -p "${INSTALL_DIR}"
curl -fsSL "${REPO_URL}" -o "${INSTALL_DIR}/dev"
chmod +x "${INSTALL_DIR}/dev"

# Ensure ~/.local/bin is on PATH
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  CURRENT_SHELL="$(basename "${SHELL:-/bin/bash}")"
  OS="$(uname -s)"

  # Pick the correct RC file for the shell and OS.
  # macOS Terminal.app opens login shells — bash reads .bash_profile, not .bashrc.
  # zsh reads .zshrc for all interactive shells (login or not) on every platform.
  case "${CURRENT_SHELL}" in
    zsh)  SHELL_RC="${HOME}/.zshrc" ;;
    bash)
      if [[ "${OS}" == "Darwin" ]]; then
        SHELL_RC="${HOME}/.bash_profile"
      else
        SHELL_RC="${HOME}/.bashrc"
      fi
      ;;
    *)    SHELL_RC="${HOME}/.profile" ;;
  esac

  if ! grep -qF "${INSTALL_DIR}" "${SHELL_RC}" 2>/dev/null; then
    echo "export PATH=\"${INSTALL_DIR}:\${PATH}\"" >> "${SHELL_RC}"
    echo "Added ${INSTALL_DIR} to PATH in ${SHELL_RC}"
  fi

  # Apply immediately so 'dev' works without manual reload
  export PATH="${INSTALL_DIR}:${PATH}"
  echo "Done. You can now run 'dev' from anywhere."
else
  echo "Done. You can now run 'dev' from anywhere."
fi
