#!/bin/bash

set -e
set -u
(set -o pipefail) 2>/dev/null && set -o pipefail
IFS=$'\n\t'

################ 配置 ################
ORG_NAME="jsdcdzkj"
DESKTOP_PATH="/Volumes/ssd"

SYNC_ROOT="/Volumes/ssd/.sync"
CACHE_ROOT="$SYNC_ROOT/repo_sync"
LOG_DIR="$SYNC_ROOT/logs"
PART_ROOT="$SYNC_ROOT/parts"
HASH_ROOT="$SYNC_ROOT/hash"

MAX_SIZE=$((90 * 1024 * 1024))        # 90MB
RELEASE_MAX=$((1900 * 1024 * 1024))   # 1.9GB

################ 忽略规则 ################
IGNORE_FILES=(
  "*.DS_Store"
  "*.log"
  "*.tmp"
  "*.swp"
)

mkdir -p "$CACHE_ROOT" "$LOG_DIR" "$PART_ROOT" "$HASH_ROOT"

LOG_FILE="$LOG_DIR/sync_$(date '+%Y%m%d_%H%M%S').log"
touch "$LOG_FILE"

log() {
  echo "$1"
  echo "$1" >> "$LOG_FILE"
}

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

to_pinyin() {
python3 - <<EOF
from pypinyin import lazy_pinyin
print(''.join(lazy_pinyin("$1")).lower())
EOF
}

log "================ 开始同步 $(date '+%F %T') ================"

git config --global user.email "sync@local"
git config --global user.name "AutoSync"

################ 主流程 ################
for folder in "$DESKTOP_PATH"/*; do
  [ -d "$folder" ] || continue
  folder_name=$(basename "$folder")

  case "$folder_name" in
    .git|.svn|.idea|node_modules|__pycache__|target)
      log "[SKIP] 忽略顶层目录：$folder_name"
      continue
      ;;
  esac

  log "== 处理：$folder_name =="

  repo_name=$(to_pinyin "$folder_name")
  LOCAL_REPO="$CACHE_ROOT/$repo_name"

  if [ -d "$LOCAL_REPO/.git" ]; then
    cd "$LOCAL_REPO"
    git reset --hard >/dev/null
    git clean -fdx >/dev/null
    git pull origin main >/dev/null 2>&1 || true
  else
    gh repo view "$ORG_NAME/$repo_name" >/dev/null 2>&1 \
      || gh repo create "$ORG_NAME/$repo_name" --public --confirm
    gh repo clone "$ORG_NAME/$repo_name" "$LOCAL_REPO"
    cd "$LOCAL_REPO"
  fi

  find . -type f \( -name "*.part*" -o -name "*.zip" -o -name "*.rar" \) -delete 2>/dev/null || true

  BIG_FILES=()
  IGNORED_FILE_COUNT=0

  cat > README.md <<EOF
# $folder_name

自动同步仓库
同步时间：$(date '+%F %T')

## 大文件（GitHub Release）
EOF

  while IFS= read -r -d '' f; do
    rel="${f#$folder/}"
    [ -z "${rel:-}" ] && continue

    for pat in "${IGNORE_FILES[@]}"; do
      if [[ "$(basename "$f")" == $pat ]]; then
        IGNORED_FILE_COUNT=$((IGNORED_FILE_COUNT + 1))
        continue 2
      fi
    done

    size=$(stat -f%z "$f")
    mkdir -p "$(dirname "$LOCAL_REPO/${rel:-}")"

    if [ "$size" -gt "$MAX_SIZE" ]; then
      safe_name=$(echo "${rel:-}" | sed 's#[ /]#_#g')
      hash_dir="$HASH_ROOT/$repo_name"
      mkdir -p "$hash_dir"
      hash_path="$hash_dir/$safe_name.sha256"

      new_hash=$(hash_file "$f")
      old_hash=""
      [ -f "$hash_path" ] && old_hash=$(cat "$hash_path")

      if [ "$new_hash" = "$old_hash" ]; then
        log "  [跳过未变化大文件] ${rel:-}"
        echo "- ${rel:-}（未变化）" >> README.md
        continue
      fi

      echo "$new_hash" > "$hash_path"

      if [ "$size" -gt "$RELEASE_MAX" ]; then
        base=$(basename "${rel:-}")
        part_dir="$PART_ROOT/$repo_name"
        mkdir -p "$part_dir"
        rm -f "$part_dir/$base.part"* 2>/dev/null || true

        split -b 1900m "$f" "$part_dir/$base.part"
        for p in "$part_dir/$base.part"*; do
          BIG_FILES+=("$p")
        done
        echo "- ${rel:-}（已分卷）" >> README.md
      else
        BIG_FILES+=("$f")
        echo "- ${rel:-}" >> README.md
      fi
    else
      cp "$f" "$LOCAL_REPO/${rel:-}"
    fi

  done < <(
    find "$folder" \
      -type d \( \
        -name .git \
        -o -name .svn \
        -o -name .idea \
        -o -name node_modules \
        -o -name __pycache__ \
        -o -name target \
      \) -prune -o \
      -type f -print0
  )

  {
    echo ""
    echo "## ⚠️ 已忽略内容"
    echo "- 忽略目录：.git .svn .idea node_modules __pycache__ target"
    echo "- 忽略文件数：$IGNORED_FILE_COUNT"
  } >> README.md

  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "Auto Sync $(date '+%F %T')" >/dev/null
    git branch -M main
    git push --force >/dev/null
    log "[OK] Git 同步完成：$repo_name"
  fi

  if [ "${#BIG_FILES[@]}" -gt 0 ]; then
    TAG="sync-$(date +%Y%m%d)"
    gh release view "$TAG" -R "$ORG_NAME/$repo_name" >/dev/null 2>&1 \
      || gh release create "$TAG" -R "$ORG_NAME/$repo_name" -t "$TAG"

    for bf in "${BIG_FILES[@]}"; do
      log "  [Release 上传] $(basename "$bf")"
      gh release upload "$TAG" "$bf" -R "$ORG_NAME/$repo_name" --clobber
    done
  fi

done

log "================ 同步完成 $(date '+%F %T') ================"
