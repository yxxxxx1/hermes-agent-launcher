#!/usr/bin/env bash
# deploy.sh — Deploy public files to Cloudflare Pages, then optionally Worker.
# Whitelist approach: only copies public-facing files.
#
# Usage:
#   ./deploy.sh                        # deploys Pages only (index.html / launcher / dashboard)
#   ./deploy.sh "" "" --with-worker    # also runs `wrangler deploy` for the telemetry Worker
#   ./deploy.sh "<commit-hash>" "<commit-msg>" [--with-worker]

set -e

COMMIT_HASH="${1:-$(git rev-parse --short HEAD)}"
COMMIT_MSG="${2:-Deploy from $COMMIT_HASH}"
WITH_WORKER=false
for arg in "$@"; do
  if [ "$arg" = "--with-worker" ]; then
    WITH_WORKER=true
  fi
done

PROJECT="hermes-gui-launcher-20260410"
DEPLOY_DIR=$(mktemp -d)

# 任务 011 返工 F2：版本号 vs zip 存在性自检（防陷阱 #13 复刻）
# 从 HermesGuiLauncher.ps1 读出权威版本号，再确认对应 zip 在 downloads/ 下存在
LAUNCHER_VERSION=$(grep -E '^\$script:LauncherVersion\s*=' HermesGuiLauncher.ps1 | head -1 | sed -E "s/.*'Windows v([0-9.]+)'.*/\1/")
if [ -z "$LAUNCHER_VERSION" ]; then
  echo "ERROR: failed to extract LauncherVersion from HermesGuiLauncher.ps1" >&2
  exit 1
fi
EXPECTED_ZIP="downloads/Hermes-Windows-Launcher-v${LAUNCHER_VERSION}.zip"
if [ ! -f "$EXPECTED_ZIP" ]; then
  echo "ERROR: $EXPECTED_ZIP not found." >&2
  echo "       Run this first (PowerShell):" >&2
  # 任务 012 返工 F3：必须把 .\\assets 一起打包，否则字体丢失，启动器英文回退到 Segoe UI
  echo "       Compress-Archive -Path .\\HermesGuiLauncher.ps1, .\\Start-HermesGuiLauncher.cmd, .\\assets -DestinationPath .\\$EXPECTED_ZIP -Force" >&2
  echo "       Copy-Item .\\$EXPECTED_ZIP .\\downloads\\Hermes-Windows-Launcher.zip -Force" >&2
  exit 1
fi
echo "OK: launcher v$LAUNCHER_VERSION zip is present ($(du -h "$EXPECTED_ZIP" | cut -f1))"
# Confirm index.html points to the same version
if ! grep -q "Hermes-Windows-Launcher-v${LAUNCHER_VERSION}.zip" index.html; then
  echo "ERROR: index.html does not reference v${LAUNCHER_VERSION} download link." >&2
  echo "       Update the href in index.html before deploying." >&2
  exit 1
fi
echo "OK: index.html references v${LAUNCHER_VERSION}"

# 任务 012 返工 F3 第四检：zip 必须含 Quicksand 字体（防字体漏打包导致 Mac 视觉对齐失败）
if ! unzip -l "$EXPECTED_ZIP" 2>/dev/null | grep -q "Quicksand"; then
  echo "ERROR: $EXPECTED_ZIP missing Quicksand fonts (assets/fonts/*.ttf)." >&2
  echo "       Repack with .\\assets included:" >&2
  echo "       Compress-Archive -Path .\\HermesGuiLauncher.ps1, .\\Start-HermesGuiLauncher.cmd, .\\assets -DestinationPath .\\$EXPECTED_ZIP -Force" >&2
  exit 1
fi
echo "OK: $EXPECTED_ZIP contains Quicksand fonts"

echo "=== Building deploy directory ==="

# Only copy public files explicitly (whitelist approach)
cp index.html "$DEPLOY_DIR/"
cp README.md "$DEPLOY_DIR/"
cp HermesGuiLauncher.ps1 "$DEPLOY_DIR/"
cp HermesMacGuiLauncher.command "$DEPLOY_DIR/"
cp Start-HermesGuiLauncher.cmd "$DEPLOY_DIR/"
cp _redirects "$DEPLOY_DIR/" 2>/dev/null || true

# Copy downloads directory
mkdir -p "$DEPLOY_DIR/downloads"
cp downloads/*.zip "$DEPLOY_DIR/downloads/" 2>/dev/null || true
cp downloads/*.tar.gz "$DEPLOY_DIR/downloads/" 2>/dev/null || true

# Copy macos-app if exists
if [ -d "macos-app" ]; then
  cp -r macos-app "$DEPLOY_DIR/macos-app"
fi

# Copy dashboard (任务 011) — looks at /dashboard/ on the Pages site
if [ -d "dashboard" ]; then
  mkdir -p "$DEPLOY_DIR/dashboard"
  cp dashboard/*.html "$DEPLOY_DIR/dashboard/" 2>/dev/null || true
  cp dashboard/*.css "$DEPLOY_DIR/dashboard/" 2>/dev/null || true
  cp dashboard/*.js "$DEPLOY_DIR/dashboard/" 2>/dev/null || true
fi

echo "=== Files to deploy ==="
find "$DEPLOY_DIR" -type f | wc -l
echo "files total"
echo ""
echo "=== Verifying NO internal docs ==="
for f in CLAUDE.md DECISIONS.md TODO.md WORKFLOW.md; do
  if [ -f "$DEPLOY_DIR/$f" ]; then
    echo "DANGER: $f found in deploy dir!"
    rm -rf "$DEPLOY_DIR"
    exit 1
  fi
done
echo "OK: no internal docs"

# Make sure the worker source code is NOT in the Pages deploy
if [ -d "$DEPLOY_DIR/worker" ]; then
  echo "DANGER: worker/ found in Pages deploy dir!"
  rm -rf "$DEPLOY_DIR"
  exit 1
fi

# Create dummy files to overwrite previously deployed internal docs on CDN
# Cloudflare Pages doesn't delete old assets, so we must overwrite them
echo "404 Not Found" > "$DEPLOY_DIR/CLAUDE.md"
echo "404 Not Found" > "$DEPLOY_DIR/DECISIONS.md"
echo "404 Not Found" > "$DEPLOY_DIR/TODO.md"
echo "404 Not Found" > "$DEPLOY_DIR/WORKFLOW.md"
mkdir -p "$DEPLOY_DIR/tasks"
echo "404 Not Found" > "$DEPLOY_DIR/tasks/index.html"
mkdir -p "$DEPLOY_DIR/openspec"
echo "404 Not Found" > "$DEPLOY_DIR/openspec/index.html"

echo ""
echo "=== Deploying to Cloudflare Pages ==="
npx wrangler pages deploy "$DEPLOY_DIR" \
  --project-name="$PROJECT" \
  --branch=main \
  --commit-hash="$COMMIT_HASH" \
  --commit-message="$COMMIT_MSG" \
  --commit-dirty=true

rm -rf "$DEPLOY_DIR"

if [ "$WITH_WORKER" = true ]; then
  echo ""
  echo "=== Deploying telemetry Worker (任务 011) ==="
  if [ ! -f "worker/wrangler.toml" ]; then
    echo "ERROR: worker/wrangler.toml not found"
    exit 1
  fi
  if grep -q "REPLACE_WITH_D1_DATABASE_ID" worker/wrangler.toml; then
    echo "ERROR: worker/wrangler.toml still has REPLACE_WITH_D1_DATABASE_ID."
    echo "       First run: wrangler d1 create hermes-telemetry"
    echo "       then paste the database_id into worker/wrangler.toml."
    exit 1
  fi
  ( cd worker && npx wrangler deploy )
  echo ""
  echo "Worker deployed. If this is the first time, also set secrets:"
  echo "  cd worker"
  echo "  npx wrangler secret put DASHBOARD_TOKEN"
  echo "  npx wrangler secret put IP_HASH_SALT"
fi

echo ""
echo "Done!"
