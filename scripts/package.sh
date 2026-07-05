#!/usr/bin/env bash
# Package justStats.app into dist/justStats.zip AND dist/justStats.app
# (Release build, unsigned). Always a fresh build: the previous built product is
# removed first so the artifacts can never lag behind the current source — the
# "new zip but stale app" trap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/justStats.xcodeproj"
SCHEME="justStats"
DEST="platform=macOS"
DIST_DIR="${REPO_ROOT}/dist"
ZIP_PATH="${DIST_DIR}/justStats.zip"
DIST_APP="${DIST_DIR}/justStats.app"

echo "==> Locating BUILT_PRODUCTS_DIR..."
BUILT_PRODUCTS_DIR="$(
  xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -destination "${DEST}" \
    -configuration Release \
    -showBuildSettings \
    CODE_SIGNING_ALLOWED=NO \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
)"

if [[ -z "${BUILT_PRODUCTS_DIR}" ]]; then
  echo "ERROR: could not determine BUILT_PRODUCTS_DIR" >&2
  exit 1
fi

APP_PATH="${BUILT_PRODUCTS_DIR}/justStats.app"

# Remove the previous built product so we never ship a stale .app (an incremental
# build that no-ops would otherwise leave an old bundle in place).
echo "==> Removing any previous built product..."
rm -rf "${APP_PATH}"

echo "==> Building Release (unsigned)..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination "${DEST}" \
  -configuration Release \
  build \
  CODE_SIGNING_ALLOWED=NO

if [[ ! -d "${APP_PATH}" ]]; then
  echo "ERROR: built app not found at ${APP_PATH}" >&2
  exit 1
fi

# Bundle the license notices into the app so the distributed .zip is
# self-contained for attribution (our MIT + the embedded Sparkle's licenses).
echo "==> Bundling license notices into the app..."
cp "${REPO_ROOT}/LICENSE" "${APP_PATH}/Contents/Resources/LICENSE.txt"
cp "${REPO_ROOT}/THIRD-PARTY-LICENSES.md" "${APP_PATH}/Contents/Resources/THIRD-PARTY-LICENSES.txt"

mkdir -p "${DIST_DIR}"

# Refresh BOTH artifacts so whichever the user runs is current:
#  - dist/justStats.zip  (the release download)
#  - dist/justStats.app  (a ready-to-run copy — replaces any stale extracted app)
echo "==> Zipping -> ${ZIP_PATH}"
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Refreshing ${DIST_APP}"
rm -rf "${DIST_APP}"
ditto "${APP_PATH}" "${DIST_APP}"

ZIP_SIZE="$(du -h "${ZIP_PATH}" | awk '{print $1}')"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "==> Done (version ${APP_VERSION})."
echo "Zip: ${ZIP_PATH} (${ZIP_SIZE})"
echo "App: ${DIST_APP}"
