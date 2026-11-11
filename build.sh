#!/usr/bin/env bash
set -euo pipefail

# colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# defaults
BUILD_MODE="release"
SPLIT_ABI=false
SIGN=false
CLEAN=false
OUTPUT_DIR="build/app/outputs/flutter-apk"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Minimum tooling versions
MIN_FLUTTER_VERSION="3.50.0"

check_versions() {
    if ! command -v flutter >/dev/null 2>&1; then
        log_error "flutter not found on PATH"
        exit 1
    fi
    local flutter_version
    flutter_version="$(flutter --version 2>/dev/null | head -1 | grep -oE 'Flutter [0-9.]+' | awk '{print $2}')"
    if [[ -z "$flutter_version" ]]; then
        log_error "could not determine flutter version"
        exit 1
    fi
    if [[ "$(printf '%s\n%s\n' "$MIN_FLUTTER_VERSION" "$flutter_version" | sort -V | head -n1)" != "$MIN_FLUTTER_VERSION" ]]; then
        log_error "flutter $flutter_version is below minimum $MIN_FLUTTER_VERSION"
        exit 1
    fi
    log_info "flutter $flutter_version (>= $MIN_FLUTTER_VERSION)"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Build Taskdroid APKs"
    echo ""
    echo "Options:"
    echo "  -d, --debug      Build debug APK (default: release)"
    echo "  -r, --release    Build release APK (default)"
    echo "  -s, --split      Split APKs by ABI (arm64, arm32, x86_64)"
    echo "  --sign           Sign APKs (requires env vars, see below)"
    echo "  --clean          Clean build before building"
    echo "  -h, --help       Show this help"
    echo ""
    echo "Environment variables for signing:"
    echo "  ANDROID_KEYSTORE_BASE64   Base64 encoded keystore"
    echo "  ANDROID_KEY_ALIAS         Key alias"
    echo "  ANDROID_KEYSTORE_PASSWORD Keystore password"
    echo "  ANDROID_KEY_PASSWORD      Key password"
    echo ""
    echo "Examples:"
    echo "  $0 --debug                     # Debug build"
    echo "  $0 --release                   # Universal release APK"
    echo "  $0 --release --split           # Split ABIs, no sign"
    echo "  $0 --release --split --sign    # Split + sign"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_versions

# parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    -d | --debug)
        BUILD_MODE="debug"
        shift
        ;;
    -r | --release)
        BUILD_MODE="release"
        shift
        ;;
    -s | --split)
        SPLIT_ABI=true
        shift
        ;;
    --sign)
        SIGN=true
        shift
        ;;
    --clean)
        CLEAN=true
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
done

# validate build mode
if [[ "$BUILD_MODE" != "debug" && "$BUILD_MODE" != "release" ]]; then
    log_error "Invalid build mode: $BUILD_MODE"
    exit 1
fi

# check if flutter is available
if ! command -v flutter &>/dev/null; then
    log_error "Flutter not found in PATH"
    exit 1
fi

# check apksigner if signing
if [[ "$SIGN" == true ]]; then
    if ! command -v apksigner &>/dev/null; then
        log_error "apksigner not found. Install Android SDK build-tools"
        exit 1
    fi
fi

# clean if requested
if [[ "$CLEAN" == true ]]; then
    log_info "Cleaning build..."
    flutter clean
    rm -rf "$OUTPUT_DIR"
fi

# get dependencies
log_info "Fetching dependencies..."
flutter pub get

# generate version info
if [[ -f "tool/generate_version.dart" ]]; then
    log_info "Generating version info..."
    dart run tool/generate_version.dart
else
    log_warn "tool/generate_version.dart not found, skipping version generation"
fi

# build command
BUILD_CMD="flutter build apk --$BUILD_MODE"

if [[ "$SPLIT_ABI" == true ]]; then
    BUILD_CMD="$BUILD_CMD --split-per-abi"
    log_info "Building split ABI APKs ($BUILD_MODE)"
else
    log_info "Building universal APK ($BUILD_MODE)"
fi

# run build
log_info "Running: $BUILD_CMD"
eval "$BUILD_CMD"

if [[ $? -ne 0 ]]; then
    log_error "Build failed"
    exit 1
fi

# rename output files
pushd "$OUTPUT_DIR" >/dev/null

if [[ "$BUILD_MODE" == "release" && "$SPLIT_ABI" == true ]]; then
    log_info "Renaming APKs..."

    if [[ -f "app-arm64-v8a-release.apk" ]]; then
        mv "app-arm64-v8a-release.apk" "$REPO_ROOT/taskdroid-arm64.apk"
        log_info "Created: taskdroid-arm64.apk"
    fi
    if [[ -f "app-armeabi-v7a-release.apk" ]]; then
        mv "app-armeabi-v7a-release.apk" "$REPO_ROOT/taskdroid-arm32.apk"
        log_info "Created: taskdroid-arm32.apk"
    fi
    if [[ -f "app-x86_64-release.apk" ]]; then
        mv "app-x86_64-release.apk" "$REPO_ROOT/taskdroid-x86_64.apk"
        log_info "Created: taskdroid-x86_64.apk"
    fi
    if [[ -f "app-release.apk" ]]; then
        rm -f "app-release.apk"
    fi

elif [[ "$BUILD_MODE" == "release" && "$SPLIT_ABI" == false ]]; then
    log_info "Renaming universal APK..."
    if [[ -f "app-release.apk" ]]; then
        mv "app-release.apk" "../../../taskdroid-universal.apk"
        log_info "Created: taskdroid-universal.apk"
    fi

elif [[ "$BUILD_MODE" == "debug" ]]; then
    log_info "Debug APK available at: $OUTPUT_DIR/app-debug.apk"
fi

popd >/dev/null

# sign if requested
if [[ "$SIGN" == true ]]; then
    if [[ -z "${ANDROID_KEYSTORE_BASE64:-}" ]] ||
        [[ -z "${ANDROID_KEY_ALIAS:-}" ]] ||
        [[ -z "${ANDROID_KEYSTORE_PASSWORD:-}" ]] ||
        [[ -z "${ANDROID_KEY_PASSWORD:-}" ]]; then
        log_error "Signing requested but missing environment variables"
        exit 1
    fi

    if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
        cd "$GITHUB_WORKSPACE"
    fi

    log_info "Looking for APKs in: $(pwd)"
    ls -la taskdroid-*.apk 2>/dev/null || ls -la "$OUTPUT_DIR"/taskdroid-*.apk 2>/dev/null || {
        log_error "No APKs found in $(pwd) or $OUTPUT_DIR"
        exit 1
    }

    log_info "Signing APKs..."

    # decode keystore
    echo "$ANDROID_KEYSTORE_BASE64" | base64 -d >keystore.jks

    # find APKs
    apk_list=()
    if ls taskdroid-*.apk 1>/dev/null 2>&1; then
        apk_list=(taskdroid-*.apk)
    elif ls "$OUTPUT_DIR"/taskdroid-*.apk 1>/dev/null 2>&1; then
        apk_list=("$OUTPUT_DIR"/taskdroid-*.apk)
    fi

    for apk in "${apk_list[@]}"; do
        if [[ -f "$apk" ]] && [[ ! "$apk" == *"-signed.apk" ]]; then
            signed_name="${apk%.apk}-signed.apk"
            log_info "Signing: $apk -> $signed_name"

            apksigner sign \
                --ks keystore.jks \
                --ks-key-alias "$ANDROID_KEY_ALIAS" \
                --ks-pass pass:"$ANDROID_KEYSTORE_PASSWORD" \
                --key-pass pass:"$ANDROID_KEY_PASSWORD" \
                --out "$signed_name" \
                "$apk"

            mv "$signed_name" "$apk"
        fi
    done

    rm -f keystore.jks
    log_info "Signing complete"
fi

log_info "Build completed successfully!"

if [[ "$BUILD_MODE" == "debug" ]]; then
    ls -lh "$OUTPUT_DIR"/*.apk
else
    ls -lh taskdroid-*.apk
fi
