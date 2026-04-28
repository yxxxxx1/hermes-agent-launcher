#!/usr/bin/env bash
# deploy.sh — Deploy public files to Cloudflare Pages
# Only copies public-facing files to a temp dir, then deploys.

set -e

COMMIT_HASH="${1:-$(git rev-parse --short HEAD)}"
COMMIT_MSG="${2:-Deploy from $COMMIT_HASH}"
PROJECT="hermes-gui-launcher-20260410"
DEPLOY_DIR=$(mktemp -d)

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
cp downloads/*.zip "$DEPLOY_DIR/downloads/"
cp downloads/*.tar.gz "$DEPLOY_DIR/downloads/" 2>/dev/null || true

# Copy macos-app if exists
if [ -d "macos-app" ]; then
  cp -r macos-app "$DEPLOY_DIR/macos-app"
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
echo "=== Deploying ==="
npx wrangler pages deploy "$DEPLOY_DIR" \
  --project-name="$PROJECT" \
  --branch=main \
  --commit-hash="$COMMIT_HASH" \
  --commit-message="$COMMIT_MSG" \
  --commit-dirty=true

rm -rf "$DEPLOY_DIR"
echo "Done!"
