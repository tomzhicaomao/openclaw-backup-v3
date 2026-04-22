#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
CONFIG_DIR="$REPO_ROOT/config"
BACKUP_DIR="$REPO_ROOT/backups"
TARGETS_FILE="$CONFIG_DIR/backup-targets.txt"
EXCLUDES_FILE="$CONFIG_DIR/backup-excludes.txt"
PRIORITY_FILE="$CONFIG_DIR/launchd-priority.txt"
DEPRECATED_LABELS_FILE="$HOME/.openclaw/system/launchd-src/deprecated-labels.txt"
AGE_PUBKEY_FILE="$HOME/.openclaw-backup-keys/backup.key.pub"
AGE_PRIVKEY_FILE="$HOME/.openclaw-backup-keys/backup.key"
BACKUP_LOG="$HOME/.openclaw-backup-keys/backup.log"
SUCCESS_LOG="$HOME/.openclaw-backup-keys/backup_success.log"
BACKUP_REPO_URL="${OPENCLAW_BACKUP_REPO_URL:-https://github.com/tomzhicaomao/openclaw-backup-v2.git}"
RETENTION_DAYS="${OPENCLAW_BACKUP_RETENTION_DAYS:-30}"
# 本地保留 10 个最新备份
MAX_LOCAL_BACKUP_COUNT="${OPENCLAW_BACKUP_MAX_LOCAL_COUNT:-10}"
# 仓库保留 10 个最新备份（推送到 GitHub）
MAX_REPO_BACKUP_COUNT="${OPENCLAW_BACKUP_MAX_REPO_COUNT:-10}"
MAX_RETRIES="${OPENCLAW_BACKUP_MAX_RETRIES:-3}"
RETRY_DELAY="${OPENCLAW_BACKUP_RETRY_DELAY_SEC:-60}"
MAX_ARCHIVE_BYTES="${OPENCLAW_BACKUP_MAX_ARCHIVE_BYTES:-99614720}"
SKIP_PUSH="${OPENCLAW_BACKUP_SKIP_PUSH:-0}"
RUNTIME_HELPER="${OPENCLAW_RUNTIME_HELPER:-$HOME/.openclaw/system/bin/openclaw-runtime.sh}"

# 增量备份配置
# 快照目录存储上次备份的时间戳
SNAPSHOT_DIR="${BACKUP_SNAPSHOT_DIR:-$CONFIG_DIR/snapshots}"
# 每周几做全量备份 (1=周一，7=周日), 默认周一
FULL_BACKUP_DAY="${BACKUP_FULL_BACKUP_DAY:-1}"
# 增量备份：只备份修改时间晚于这个天数的文件
INCREMENTAL_DAYS="${BACKUP_INCREMENTAL_DAYS:-1}"
RESCUE_CONFIG="$HOME/.openclaw-rescue/openclaw.json"
RESCUE_STATE="$HOME/.openclaw-rescue"
TARGET_FILE="$HOME/.openclaw-rescue/feishu-target.txt"
DEFAULT_TARGET="ou_df724a99fec29229a58a2c134b5c1a89"
RUN_AT="$(date '+%Y-%m-%d %H:%M:%S')"
RUN_TS=""
RUN_BACKUP_DIR=""
RUN_COMMIT=""
RUN_DETAIL=""
BACKUP_EXCLUDE_FILE=""

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing command: $1"
    exit 1
  }
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

list_file_items() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '%s\n' "$line"
  done < "$file"
}

write_json_array_from_file() {
  local file="$1"
  local indent="$2"
  local first=1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if [ "$first" -eq 0 ]; then
      printf ',\n'
    fi
    printf '%*s"%s"' "$indent" '' "$(json_escape "$line")"
    first=0
  done < "$file"
  if [ "$first" -eq 1 ]; then
    printf '%*s' "$indent" ''
  fi
}

sanitize_excludes() {
  local tmp_file="$1"
  : > "$tmp_file"
  list_file_items "$EXCLUDES_FILE" > "$tmp_file"

  # 自动发现并排除所有 node_modules，但保留 openclaw-lark
  find "$HOME/.openclaw" -type d -name "node_modules" 2>/dev/null | while IFS= read -r dir; do
    # 跳过 openclaw-lark 的 node_modules
    case "$dir" in
      */openclaw-lark/*) continue ;;
    esac
    # 转换为相对路径并写入排除文件
    rel_path="${dir#$HOME/}"
    printf '%s\n' "$rel_path" >> "$tmp_file"
    printf '%s/*\n' "$rel_path" >> "$tmp_file"
  done

  # 自动发现并排除 Python 缓存
  find "$HOME/.openclaw" -type d \( -name "__pycache__" -o -name ".pytest_cache" -o -name ".mypy_cache" \) 2>/dev/null | while IFS= read -r dir; do
    rel_path="${dir#$HOME/}"
    printf '%s\n' "$rel_path" >> "$tmp_file"
    printf '%s/*\n' "$rel_path" >> "$tmp_file"
  done
}

ensure_public_key() {
  if [ -f "$AGE_PUBKEY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$AGE_PRIVKEY_FILE" ]; then
    log "missing key: $AGE_PUBKEY_FILE"
    exit 1
  fi
  require_cmd age-keygen
  age-keygen -y "$AGE_PRIVKEY_FILE" > "$AGE_PUBKEY_FILE"
  chmod 644 "$AGE_PUBKEY_FILE"
}

# 确保 Git LFS 配置正确
ensure_git_lfs() {
  # No LFS needed - backup files are stored as regular Git files
  return 0
}

get_target() {
  if [ -f "$TARGET_FILE" ]; then
    local value
    value="$(head -n 1 "$TARGET_FILE" | tr -d '[:space:]')"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  printf '%s\n' "$DEFAULT_TARGET"
}

send_feishu() {
  local message="$1"
  local target
  target="$(get_target)"

  if [ ! -f "$RUNTIME_HELPER" ]; then
    log "skip feishu notify: runtime helper missing at $RUNTIME_HELPER"
    return 0
  fi

  # shellcheck source=/dev/null
  . "$RUNTIME_HELPER"
  if ! openclaw_with_context "$RESCUE_CONFIG" "$RESCUE_STATE" message send \
      --channel feishu \
      --target "$target" \
      --message "$message" >> "$BACKUP_LOG" 2>&1; then
    log "skip feishu notify: openclaw message send failed"
  fi
}

notify_result() {
  local exit_code="$1"
  local status_text icon
  if [ "$exit_code" -eq 0 ]; then
    icon="✅"
    status_text="成功"
  else
    icon="❌"
    status_text="失败"
  fi

  send_feishu "${icon} OpenClaw 自动备份${status_text}

时间：${RUN_AT}
批次：${RUN_TS:-N/A}
提交：${RUN_COMMIT:-N/A}
目录：${RUN_BACKUP_DIR:-N/A}
详情：${RUN_DETAIL:-N/A}"
}

on_exit() {
  local exit_code="$1"
  notify_result "$exit_code"
}

backup_exit_handler() {
  local exit_code="$1"
  if [ -n "$BACKUP_EXCLUDE_FILE" ]; then
    rm -f "$BACKUP_EXCLUDE_FILE"
  fi
  on_exit "$exit_code"
}

trap 'backup_exit_handler $?' EXIT

prepare_repo() {
  require_cmd git
  require_cmd age
  require_cmd tar
  require_cmd shasum
  require_cmd split
  ensure_public_key
  ensure_git_lfs
  mkdir -p "$BACKUP_DIR"

  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "backup repo missing git metadata: $REPO_ROOT"
    exit 1
  fi

  if ! git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO_ROOT" remote add origin "$BACKUP_REPO_URL"
  fi

  if git -C "$REPO_ROOT" diff --quiet && git -C "$REPO_ROOT" diff --cached --quiet; then
    git -C "$REPO_ROOT" pull --ff-only origin main >/dev/null 2>&1 || true
  else
    log "repo has local changes; skip pull"
  fi
}

archive_one_target() {
  local target_rel="$1"
  local out_dir="$2"
  local exclude_file="$3"
  local target_abs="$HOME/$target_rel"
  local base_name out_file timestamp_file

  if [ ! -e "$target_abs" ]; then
    log "skip missing target: $target_rel"
    return 0
  fi

  base_name="$(basename "$target_rel")"
  out_file="$out_dir/${base_name}.tar.age"

  # 时间戳文件路径（用于增量备份）
  mkdir -p "$SNAPSHOT_DIR"
  timestamp_file="$SNAPSHOT_DIR/${base_name}.timestamp"

  # 判断是否做全量备份：
  # 1. 时间戳文件不存在
  # 2. 今天是配置的全量备份日
  # 3. 时间戳文件过期（超过 7 天）
  local is_full_backup=0
  local find_args=()

  if [ ! -f "$timestamp_file" ]; then
    is_full_backup=1
    log "full backup (no timestamp): $target_rel"
  elif [ "$(date +%u)" = "$FULL_BACKUP_DAY" ]; then
    is_full_backup=1
    log "full backup (weekly full backup day): $target_rel"
  elif [ -n "$(find "$timestamp_file" -mtime +7 2>/dev/null)" ]; then
    is_full_backup=1
    log "full backup (timestamp expired): $target_rel"
  else
    log "incremental backup: $target_rel"
  fi

  # 构建 find 参数
  if [ "$is_full_backup" -eq 0 ] && [ -f "$timestamp_file" ]; then
    # 增量备份：只备份修改时间晚于上次备份的文件
    local last_backup_time
    last_backup_time="$(cat "$timestamp_file")"
    find_args+=("-newer" "$timestamp_file")
    log "  (files newer than: $last_backup_time)"
  fi

  # 创建临时文件列表
  local file_list
  file_list="$(mktemp)"

  # 使用 find 生成文件列表
  if [ "$is_full_backup" -eq 1 ]; then
    # 全量备份：所有文件
    find "$target_abs" -type f > "$file_list" 2>/dev/null
  else
    # 增量备份：只找新文件
    find "$target_abs" -type f "${find_args[@]}" > "$file_list" 2>/dev/null
  fi

  # 如果有排除文件，应用排除规则
  if [ -f "$exclude_file" ]; then
    local filtered_list
    filtered_list="$(mktemp)"
    # 使用 grep -v 排除匹配的行
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      grep -v "$pattern" "$file_list" > "$filtered_list" || true
      mv "$filtered_list" "$file_list"
    done < "$exclude_file"
  fi

  # 检查是否有文件需要备份
  local file_count
  file_count="$(wc -l < "$file_list" | tr -d ' ')"
  if [ "$file_count" -eq 0 ]; then
    log "  no files changed, skipping $target_rel"
    rm -f "$file_list"
    return 0
  fi

  log "  backing up $file_count files"

  # 创建 tar 并加密
  tar -C "$HOME" -cf - -T "$file_list" | age -r "$(cat "$AGE_PUBKEY_FILE")" -o "$out_file"

  # 更新时间戳文件
  date '+%Y-%m-%d %H:%M:%S' > "$timestamp_file"

  # 清理临时文件
  rm -f "$file_list"

  local size_bytes part_file backup_type
  size_bytes="$(stat -f '%z' "$out_file")"
  backup_type="$([ "$is_full_backup" -eq 1 ] && echo 'full' || echo 'incremental')"

  if [ "$size_bytes" -gt "$MAX_ARCHIVE_BYTES" ]; then
    log "splitting $(basename "$out_file") (${size_bytes} bytes)"
    split -b "$MAX_ARCHIVE_BYTES" -d -a 3 "$out_file" "${out_file}.part."
    rm -f "$out_file"
    for part_file in "${out_file}".part.*; do
      [ -f "$part_file" ] || continue
      (
        cd "$out_dir"
        shasum -a 256 "$(basename "$part_file")" > "$(basename "$part_file").sha256"
      )
    done
  else
    (
      cd "$out_dir"
      shasum -a 256 "$(basename "$out_file")" > "$(basename "$out_file").sha256"
    )
  fi

  log "archived $target_rel (${size_bytes} bytes, $backup_type, $file_count files)"
}

list_launchd_labels() {
  local label
  list_file_items "$PRIORITY_FILE"
  if [ -f "$DEPRECATED_LABELS_FILE" ]; then
    while IFS= read -r label || [ -n "$label" ]; do
      case "$label" in
        ''|'#'*) continue ;;
      esac
      printf '%s\n' "$label"
    done < "$DEPRECATED_LABELS_FILE"
  fi
}

backup_launchd_metadata() {
  local out_dir="$1"
  local meta_dir="$out_dir/meta/launchd"
  local plist_dir="$meta_dir/plists"
  local status_dir="$meta_dir/status"
  local uidn plist label

  mkdir -p "$plist_dir" "$status_dir"
  uidn="$(id -u)"

  find "$HOME/Library/LaunchAgents" -maxdepth 1 -type f \( -name 'ai.openclaw*.plist' -o -name 'com.openclaw.backup.plist' \) | sort | while IFS= read -r plist; do
    [ -f "$plist" ] || continue
    cp "$plist" "$plist_dir/"
  done

  list_launchd_labels | while IFS= read -r label; do
    [ -n "$label" ] || continue
    launchctl print "gui/${uidn}/${label}" > "$status_dir/${label}.txt" 2>&1 || true
  done

  if [ -f "$AGE_PUBKEY_FILE" ]; then
    mkdir -p "$out_dir/meta/age"
    cp "$AGE_PUBKEY_FILE" "$out_dir/meta/age/backup.key.pub"
  fi
}

cleanup_old() {
  # 1. 删除超过保留天数的旧备份
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} + 2>/dev/null || true

  # 2. 本地只保留最近 MAX_LOCAL_BACKUP_COUNT 个备份目录
  local count=0 dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$MAX_LOCAL_BACKUP_COUNT" ]; then
      log "删除本地旧备份目录：$(basename "$dir")"
      rm -rf "$dir"
    fi
  done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
}

# 清理 Git 仓库历史，只保留最近 MAX_REPO_BACKUP_COUNT 次提交
cleanup_git_history() {
  local commit_count
  commit_count=$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo "0")

  # 触发阈值：超过 MAX_REPO_BACKUP_COUNT + 2 次提交时清理
  local threshold=$((MAX_REPO_BACKUP_COUNT + 2))
  if [ "$commit_count" -le "$threshold" ]; then
    return 0
  fi

  log "Git 提交数 $commit_count，触发清理（保留最近 $MAX_REPO_BACKUP_COUNT 次）..."

  # 计算需要保留的提交位置
  local target_commit
  target_commit=$(git -C "$REPO_ROOT" rev-parse HEAD~$MAX_REPO_BACKUP_COUNT 2>/dev/null || echo "")

  if [ -n "$target_commit" ]; then
    # 使用 git reset --soft 保留工作区内容
    git -C "$REPO_ROOT" reset --soft "$target_commit" 2>/dev/null || {
      log "soft reset 失败，尝试使用 rebase 清理"
      git -C "$REPO_ROOT" rebase -i --root --autosquash 2>/dev/null || true
    }

    git -C "$REPO_ROOT" commit -m "backup: $(date +%Y-%m-%d_%H%M%S) - 自动清理旧历史" 2>/dev/null || true

    # 运行 GC 和引用清理
    git -C "$REPO_ROOT" reflog expire --expire=now --all 2>/dev/null || true
    git -C "$REPO_ROOT" gc --prune=now --aggressive 2>/dev/null || true

    log "Git 历史已清理，当前提交数：$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo "1")"
  else
    log "无法计算目标提交，跳过清理"
  fi
}

# 安全推送策略：优先正常推送，失败时自动尝试 force-with-lease
push_with_retry() {
  local force_pushed=0
  local tries=0

  # 第一次尝试正常推送
  if git -C "$REPO_ROOT" push origin main 2>/dev/null; then
    log "推送成功"
    return 0
  fi

  # 推送失败，使用 force-with-lease 重试（安全强制推送）
  # --force-with-lease 会检查远程是否有新的提交，避免覆盖他人的工作
  log "普通推送失败，使用 --force-with-lease 重试..."

  while [ "$tries" -lt "$MAX_RETRIES" ]; do
    if git -C "$REPO_ROOT" push --force-with-lease origin main 2>/dev/null; then
      if [ "$force_pushed" -eq 0 ]; then
        log "⚠️  已使用 force-with-lease 推送（历史清理导致）"
        force_pushed=1
      else
        log "⚠️  force-with-lease 重试成功 ($tries/$MAX_RETRIES)"
      fi
      return 0
    fi

    tries=$((tries + 1))
    if [ "$tries" -lt "$MAX_RETRIES" ]; then
      log "force-with-lease 推送失败; 重试 ($tries/$MAX_RETRIES)"
      git -C "$REPO_ROOT" fetch origin main >/dev/null 2>&1 || true
      sleep "$RETRY_DELAY"
    fi
  done

  log "❌ 所有推送尝试失败"
  return 1
}

write_manifest() {
  local out_dir="$1"
  local openclaw_cmd node_cmd
  openclaw_cmd="$(command -v openclaw 2>/dev/null || true)"
  node_cmd="$(command -v node 2>/dev/null || true)"

  {
    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -Iseconds)"
    printf '  "host": "%s",\n' "$(hostname)"
    printf '  "repo": "%s",\n' "$(json_escape "$BACKUP_REPO_URL")"
    printf '  "format": "tar.age",\n'
    printf '  "incremental": true,\n'
    printf '  "snapshotDir": "%s",\n' "$(json_escape "$SNAPSHOT_DIR")"
    printf '  "fullBackupDay": %s,\n' "$FULL_BACKUP_DAY"
    printf '  "targets": [\n'
    write_json_array_from_file "$TARGETS_FILE" 4
    printf '\n  ],\n'
    printf '  "excludes": [\n'
    write_json_array_from_file "$EXCLUDES_FILE" 4
    printf '\n  ],\n'
    printf '  "launchdPriority": [\n'
    write_json_array_from_file "$PRIORITY_FILE" 4
    printf '\n  ],\n'
    printf '  "tooling": {\n'
    printf '    "openclaw": "%s",\n' "$(json_escape "$openclaw_cmd")"
    printf '    "node": "%s"\n' "$(json_escape "$node_cmd")"
    printf '  },\n'
    printf '  "maxArchiveBytes": %s,\n' "$MAX_ARCHIVE_BYTES"
    printf '  "notes": "Local and repo each keep %s backups; archives encrypted with age"\n' "$MAX_REPO_BACKUP_COUNT"
    printf '}\n'
  } > "$out_dir/manifest.json"
}

do_backup() {
  prepare_repo

  local ts backup_run_dir
  ts="$(date +%Y-%m-%d_%H%M%S)"
  backup_run_dir="$BACKUP_DIR/${ts}"
  mkdir -p "$backup_run_dir"

  RUN_TS="$ts"
  RUN_BACKUP_DIR="$backup_run_dir"

  # 创建排除文件
  BACKUP_EXCLUDE_FILE="$(mktemp)"
  sanitize_excludes "$BACKUP_EXCLUDE_FILE"

  # 备份每个目标
  local target
  while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue
    archive_one_target "$target" "$backup_run_dir" "$BACKUP_EXCLUDE_FILE"
  done < <(list_file_items "$TARGETS_FILE")

  # 备份 LaunchAgent 元数据
  backup_launchd_metadata "$backup_run_dir"

  # 写入 manifest
  write_manifest "$backup_run_dir"

  # 清理旧备份（本地）
  cleanup_old

  # 提交并推送到 Git
  git -C "$REPO_ROOT" add -A
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    RUN_DETAIL="无变化，无需提交"
    return 0
  fi

  git -C "$REPO_ROOT" commit -m "backup: $ts"
  RUN_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

  if [ "$SKIP_PUSH" = "1" ]; then
    RUN_DETAIL="备份完成（跳过推送）"
    printf '[%s] %s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ts" "$RUN_COMMIT" "$backup_run_dir" >> "$SUCCESS_LOG"
    return 0
  fi

  # 推送前清理 Git 历史
  cleanup_git_history

  if ! push_with_retry; then
    RUN_DETAIL="推送失败（已重试）"
    return 1
  fi

  printf '[%s] %s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ts" "$RUN_COMMIT" "$backup_run_dir" >> "$SUCCESS_LOG"
  RUN_DETAIL="备份并推送完成"
}

main() {
  do_backup
  log "backup completed: ${RUN_TS}"
}

main "$@"
