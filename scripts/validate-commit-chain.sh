#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Validate each commit in BASE..HEAD by replaying CI-like checks locally.

Usage:
  scripts/validate-commit-chain.sh [--base <ref>] [--branch <ref>] [--log-dir <dir>] [--toolchain <ver>] [--allow-dirty]

Defaults:
  --base master
  --branch current branch
  --log-dir /tmp/rust-postgres-commit-validation
  --toolchain 1.85.0

Examples:
  scripts/validate-commit-chain.sh
  scripts/validate-commit-chain.sh --base origin/master --branch my/topic
  scripts/validate-commit-chain.sh --toolchain stable
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 2
  }
}

detect_compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi

  echo "missing docker compose support: install docker compose plugin or docker-compose" >&2
  exit 2
}

BASE="master"
BRANCH="$(git branch --show-current)"
LOG_DIR="/tmp/rust-postgres-commit-validation"
TOOLCHAIN="1.85.0"
ALLOW_DIRTY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --toolchain)
      TOOLCHAIN="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd git
require_cmd awk
require_cmd cargo
detect_compose_cmd

if [[ -z "$BRANCH" ]]; then
  echo "not on a branch; pass --branch <ref>" >&2
  exit 2
fi

if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "base ref not found: $BASE" >&2
  exit 2
fi

if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "branch ref not found: $BRANCH" >&2
  exit 2
fi

if [[ "$ALLOW_DIRTY" -ne 1 ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree is dirty; commit/stash changes or pass --allow-dirty" >&2
  exit 2
fi

cleanup() {
  set +e
  git checkout --quiet "$BRANCH" >/dev/null 2>&1
  "${COMPOSE_CMD[@]}" -p rust-postgres-ci down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

extract_test_job_cargo_commands() {
  # Extract only cargo run lines under the test job in CI workflow.
  awk '
    /^  test:/ { in_test=1; next }
    in_test && /^  [a-zA-Z0-9_-]+:/ { exit }
    in_test && /- run: cargo / {
      sub(/^[[:space:]]*- run: /, "")
      print
    }
  ' .github/workflows/ci.yml
}

run_cargo_cmd() {
  local command_text="$1"
  local log_file="$2"

  if [[ "$command_text" != cargo\ * ]]; then
    echo "unexpected non-cargo command in CI extraction: $command_text" >&2
    return 1
  fi

  local args_text="${command_text#cargo }"
  # CI commands in this workflow do not include quoted arguments.
  # Split into argv without invoking eval.
  local -a cargo_args=()
  read -r -a cargo_args <<<"$args_text"

  if [[ -n "$TOOLCHAIN" ]]; then
    RUSTFLAGS=-Dwarnings cargo "+$TOOLCHAIN" "${cargo_args[@]}" >"$log_file" 2>&1
  else
    RUSTFLAGS=-Dwarnings cargo "${cargo_args[@]}" >"$log_file" 2>&1
  fi
}

validate_commit() {
  local commit="$1"
  local short subject log command_text label

  short="$(git rev-parse --short "$commit")"
  subject="$(git log -1 --format=%s "$commit")"
  echo "=== validating ${short} ${subject}"

  git checkout --quiet "$commit" || return 1

  "${COMPOSE_CMD[@]}" -p rust-postgres-ci down -v --remove-orphans >/dev/null 2>&1 || true

  log="$LOG_DIR/${short}-compose-up.log"
  echo "-> compose-up"
  if ! "${COMPOSE_CMD[@]}" -p rust-postgres-ci up -d --wait --wait-timeout 60 >"$log" 2>&1; then
    cat "$log"
    return 1
  fi

  log="$LOG_DIR/${short}-fmt.log"
  echo "-> fmt"
  if [[ -n "$TOOLCHAIN" ]]; then
    if ! cargo +nightly fmt --all -- --check >"$log" 2>&1; then
      cat "$log"
      return 1
    fi
  else
    if ! cargo +nightly fmt --all -- --check >"$log" 2>&1; then
      cat "$log"
      return 1
    fi
  fi

  log="$LOG_DIR/${short}-clippy.log"
  echo "-> clippy"
  if [[ -n "$TOOLCHAIN" ]]; then
    if ! RUSTFLAGS=-Dwarnings cargo "+$TOOLCHAIN" clippy --quiet --all --all-targets >"$log" 2>&1; then
      cat "$log"
      return 1
    fi
  else
    if ! RUSTFLAGS=-Dwarnings cargo clippy --quiet --all --all-targets >"$log" 2>&1; then
      cat "$log"
      return 1
    fi
  fi

  log="$LOG_DIR/${short}-wasm.log"
  echo "-> wasm"
  if [[ -n "$TOOLCHAIN" ]]; then
    if ! RUSTFLAGS='--cfg getrandom_backend="wasm_js"' cargo "+$TOOLCHAIN" check --quiet --target wasm32-unknown-unknown --manifest-path tokio-postgres/Cargo.toml --no-default-features --features js >"$log" 2>&1; then
      cat "$log"
      return 1
    fi
  else
    if ! RUSTFLAGS='--cfg getrandom_backend="wasm_js"' cargo check --quiet --target wasm32-unknown-unknown --manifest-path tokio-postgres/Cargo.toml --no-default-features --features js >"$log" 2>&1; then
      cat "$log"
      return 1
    fi
  fi

  while IFS= read -r command_text; do
    [[ -z "$command_text" ]] && continue

    label="$(printf '%s' "$command_text" | tr ' /' '__' | tr -cd '[:alnum:]_=-' | cut -c1-80)"
    log="$LOG_DIR/${short}-${label}.log"

    echo "-> ${command_text}"
    if ! run_cargo_cmd "$command_text" "$log"; then
      cat "$log"
      return 1
    fi
  done < <(extract_test_job_cargo_commands)

  echo "=== ok ${short}"
}

if [[ -n "$TOOLCHAIN" ]]; then
  rustup toolchain install "$TOOLCHAIN" >/dev/null
  rustup target add --toolchain "$TOOLCHAIN" wasm32-unknown-unknown >/dev/null
else
  rustup target add wasm32-unknown-unknown >/dev/null
fi

echo "__VALIDATION_START__"

failed=0
failed_commit=""

mapfile -t commits < <(git rev-list --reverse "$BASE".."$BRANCH")

if [[ "${#commits[@]}" -eq 0 ]]; then
  echo "no commits to validate in range ${BASE}..${BRANCH}"
  exit 0
fi

for commit in "${commits[@]}"; do
  if ! validate_commit "$commit"; then
    failed=1
    failed_commit="$(git rev-parse --short "$commit" 2>/dev/null || printf unknown)"
    break
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "=== validation failed at ${failed_commit}"
  exit 1
fi

echo "=== validation complete"
