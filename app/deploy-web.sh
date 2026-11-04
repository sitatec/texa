#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-}"

if [ -z "$ENV" ] || { [ "$ENV" != "dev" ] && [ "$ENV" != "staging" ] && [ "$ENV" != "production" ]; }; then
  echo "Error: No environment specified. Use 'dev', 'staging', or 'production'."
  exit 1
fi

if [ -n "$(git status . --porcelain)" ]; then
  echo "Error: You have uncommitted changes. Please **BUMP** version and commit first."
  exit 1
fi

VERSION=$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | tr -d '"' | tr -d "'")

# Prompt user for confirmation
read -r -p "Current version is '$VERSION'. Did you bump the release version in pubspec.yaml? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
  echo "Deployment aborted. Please bump the version in pubspec.yaml and commit before deploying."
  exit 1
fi

echo "Deploying release $VERSION..."

cd web/texa-webspeech && npm run build && cd ../../

flutter build web --release --wasm --dart-define=WASM_BASE_URL=https://cdn.jsdelivr.net/npm/onnxruntime-web@1.31.1/dist/

# sherpa_onnx is not used in web so delete its heavy wasm files to reduce web startup time.
rm -rf build/web/assets/packages/sherpa_onnx_web
# Remove the texa-webspeech source code, the build outputs are included.
rm -rf build/web/texa-webspeech
# Remove the heavy ort wasm files that exceeds cloudflare workers' limit (25MB per file). We provided WASM_BASE_URL above
rm -rf build/web/ort-wasm

bunx wrangler@4.142.0 deploy --env "$ENV" --cwd build/web

echo "Deployment Complete ✅"