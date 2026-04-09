#!/usr/bin/env bash
# deploy.sh — Selective ECC deployment for the personal ecc branch.
#
# Reads ecc.config.json and deploys:
#   Phase 1:   Core modules via the existing ecc installer
#   Phase 1.5: Remove excluded rule packs
#   Phase 2:   Individual skills, skipping those in the exclude list
#   Phase 3:   Remove unwanted commands (legacy shims + excluded language commands)
#
# Usage:
#   ./deploy.sh              # deploy to ~/.claude
#   ./deploy.sh --dry-run    # show what would be deployed
#   ./deploy.sh --config <path>  # use alternate config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/ecc.config.json"
DRY_RUN=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: deploy.sh [--dry-run] [--config <path>]"
      echo ""
      echo "Options:"
      echo "  --dry-run         Show what would be deployed without writing"
      echo "  --config <path>   Use alternate config (default: ecc.config.json)"
      exit 0
      ;;
    *)
      echo "[ecc-deploy] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# --- Ensure config exists ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[ecc-deploy] Config not found: $CONFIG_FILE" >&2
  exit 1
fi

# --- Ensure npm dependencies ---
if [[ ! -d "${SCRIPT_DIR}/node_modules" ]]; then
  echo "[ecc-deploy] Installing npm dependencies..."
  (cd "$SCRIPT_DIR" && npm install --no-audit --no-fund --loglevel=error)
fi

# --- Read config via node (safe JSON parsing) ---
read_json_array() {
  node -e "
    const cfg = require('$CONFIG_FILE');
    const val = cfg['$1'];
    if (Array.isArray(val)) val.forEach(v => console.log(v));
  "
}

read_json_string() {
  node -e "
    const cfg = require('$CONFIG_FILE');
    const val = cfg['$1'];
    if (typeof val === 'string') console.log(val);
  "
}

read_json_object() {
  node -e "
    const cfg = require('$CONFIG_FILE');
    const val = cfg['$1'];
    if (val && typeof val === 'object' && !Array.isArray(val)) {
      for (const [k, v] of Object.entries(val)) console.log(k + '=' + v);
    }
  "
}

DEPLOY_TARGET="$(read_json_string deploy_target)"
DEPLOY_TARGET="${DEPLOY_TARGET/#\~/$HOME}"
INSTALLER_TARGET="$(read_json_string installer_target)"
INSTALLER_TARGET="${INSTALLER_TARGET:-claude}"

# Collect arrays
mapfile -t MODULES < <(read_json_array installer_modules)
mapfile -t EXCLUDE_SKILLS < <(read_json_array exclude_skills)
mapfile -t EXCLUDE_RULES < <(read_json_array exclude_rules)
mapfile -t REMOVE_CMDS < <(read_json_array remove_commands)

# Collect rename map
declare -A SKILL_RENAMES
while IFS='=' read -r key val; do
  [[ -n "$key" ]] && SKILL_RENAMES["$key"]="$val"
done < <(read_json_object skill_renames)

# --- Header ---
echo "========================================"
echo "  ecc deploy"
echo "========================================"
echo "  Source:    $SCRIPT_DIR"
echo "  Target:    $DEPLOY_TARGET"
echo "  Modules:   ${#MODULES[@]}"
echo "  Excluded:  ${#EXCLUDE_SKILLS[@]} skills, ${#EXCLUDE_RULES[@]} rule packs"
echo "  Renames:   ${#SKILL_RENAMES[@]}"
echo "  Dry run:   $DRY_RUN"
echo "========================================"
echo ""

# Build exclusion lookup
declare -A SKIP_SKILL
for s in "${EXCLUDE_SKILLS[@]}"; do
  SKIP_SKILL["$s"]=1
done

# ============================================================
# Phase 1: Core modules via existing installer
# ============================================================
echo "[Phase 1] Installing core modules via ecc installer..."

MODULE_LIST=$(IFS=,; echo "${MODULES[*]}")
INSTALL_ARGS=(--modules "$MODULE_LIST" --target "$INSTALLER_TARGET")

if $DRY_RUN; then
  INSTALL_ARGS+=(--dry-run)
fi

node "${SCRIPT_DIR}/scripts/install-apply.js" "${INSTALL_ARGS[@]}" || {
  echo "[ecc-deploy] Warning: installer returned non-zero, continuing with Phase 2..." >&2
}
echo ""

# ============================================================
# Phase 1.5: Remove excluded rule packs
# ============================================================
if [[ ${#EXCLUDE_RULES[@]} -gt 0 ]]; then
  echo "[Phase 1.5] Filtering rule packs (excluding ${#EXCLUDE_RULES[@]})..."
  RULES_DST="${DEPLOY_TARGET}/rules"

  rules_removed=0
  for rule_name in "${EXCLUDE_RULES[@]}"; do
    rule_path="${RULES_DST}/${rule_name}"
    if $DRY_RUN; then
      if [[ -d "$rule_path" ]]; then
        echo "  REMOVE  rules/$rule_name/"
      else
        echo "  SKIP    rules/$rule_name/ (not present)"
      fi
    else
      if [[ -d "$rule_path" ]]; then
        rm -rf "$rule_path"
        rules_removed=$((rules_removed + 1))
      fi
    fi
  done

  if ! $DRY_RUN; then
    echo "  Removed: $rules_removed rule packs"
  fi
  echo ""
fi

# ============================================================
# Phase 2: Selective skill deployment
# ============================================================
echo "[Phase 2] Deploying skills (excluding ${#EXCLUDE_SKILLS[@]})..."

SKILLS_SRC="${SCRIPT_DIR}/skills"
SKILLS_DST="${DEPLOY_TARGET}/skills"

deployed=0
skipped=0

for skill_dir in "${SKILLS_SRC}"/*/; do
  [[ ! -d "$skill_dir" ]] && continue
  skill_name="$(basename "$skill_dir")"

  # Check exclusion
  if [[ -n "${SKIP_SKILL[$skill_name]+x}" ]]; then
    $DRY_RUN && echo "  SKIP  $skill_name"
    skipped=$((skipped + 1))
    continue
  fi

  # Check rename
  target_name="$skill_name"
  if [[ -n "${SKILL_RENAMES[$skill_name]+x}" ]]; then
    target_name="${SKILL_RENAMES[$skill_name]}"
    $DRY_RUN && echo "  COPY  $skill_name -> $target_name/ (renamed)"
  else
    $DRY_RUN && echo "  COPY  $skill_name/"
  fi

  if ! $DRY_RUN; then
    mkdir -p "${SKILLS_DST}/${target_name}"
    cp -r "${skill_dir}"* "${SKILLS_DST}/${target_name}/"
  fi
  deployed=$((deployed + 1))
done

echo ""
echo "  Deployed: $deployed skills"
echo "  Skipped:  $skipped skills"
echo ""

# ============================================================
# Phase 3: Remove unwanted commands
# ============================================================
if [[ ${#REMOVE_CMDS[@]} -gt 0 ]]; then
  echo "[Phase 3] Removing unwanted commands (${#REMOVE_CMDS[@]})..."
  CMDS_DST="${DEPLOY_TARGET}/commands"

  cmds_removed=0
  for cmd_file in "${REMOVE_CMDS[@]}"; do
    cmd_path="${CMDS_DST}/${cmd_file}"
    if $DRY_RUN; then
      if [[ -f "$cmd_path" ]]; then
        echo "  REMOVE  commands/$cmd_file"
      else
        echo "  SKIP    commands/$cmd_file (not present)"
      fi
    else
      if [[ -f "$cmd_path" ]]; then
        rm -f "$cmd_path"
        cmds_removed=$((cmds_removed + 1))
      fi
    fi
  done

  if ! $DRY_RUN; then
    echo "  Removed: $cmds_removed commands"
  fi
  echo ""
fi

# ============================================================
# Summary
# ============================================================
echo "========================================"
echo "  Deploy complete"
echo "========================================"
echo "  Skills: $deployed deployed, $skipped excluded"
echo "  Rules:  ${#EXCLUDE_RULES[@]} packs excluded"
echo "  Cmds:   ${#REMOVE_CMDS[@]} commands removed"
echo "  Target: $DEPLOY_TARGET"

if $DRY_RUN; then
  echo ""
  echo "  (Dry run — no files were written)"
fi
echo ""
