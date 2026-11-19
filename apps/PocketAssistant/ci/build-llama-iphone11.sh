#!/bin/bash
# Builds llama.xcframework for one target only: iPhone 11 (Apple A13) on iOS 14.
#
# Reuses the helper functions from the pinned llama.cpp's build-xcframework.sh (the
# submodule itself is not modified; a patched copy is generated next to it), but builds
# just the iOS device slice, with:
#   - deployment target iOS 14.0
#   - no Accelerate BLAS: it links cblas_sgemm$NEWLAPACK$ILP64 (iOS 16.4+), which is NULL
#     on iOS 14 and crashed every prompt of 32+ tokens (device report 2026-11-19)
#   - no Metal: the A13 GPU (Apple6) lacks simdgroup reduction/matrix ops, so ggml-metal
#     cannot run matrix multiplies there anyway; CPU-only avoids GPU buffers, CPU<->GPU
#     copies and the on-device shader compile
#   - CPU code compiled for the A13 (ARMv8.4-A: dot-product instructions, plus FP16
#     arithmetic) instead of generic arm64. The result will not run on A9-A12 iPhones.
set -euo pipefail

cd "$(dirname "$0")/../llama.cpp"
export GGML_CPU_ARM_ARCH="${GGML_CPU_ARM_ARCH:-armv8.4-a+fp16}"

UPSTREAM=build-xcframework.sh
OUT=build-xcframework-iphone11.sh

cut_line=$(grep -n '^echo "Building for iOS simulator..."' "$UPSTREAM" | cut -d: -f1)
[ -n "$cut_line" ] || { echo "error: platform section marker not found in $UPSTREAM"; exit 1; }

# Settings and helper functions only (everything before the first platform build).
head -n $((cut_line - 1)) "$UPSTREAM" > "$OUT"
sed -i '' \
    -e 's/^IOS_MIN_OS_VERSION=.*/IOS_MIN_OS_VERSION=14.0/' \
    -e 's/^GGML_METAL=ON$/GGML_METAL=OFF/' \
    -e '/libggml-blas\.a"/d' \
    -e '/libggml-metal\.a"/d' \
    "$OUT"
# ggml/CMakeLists.txt re-sets GGML_BLAS_DEFAULT=ON for Apple, so GGML_BLAS must be passed itself.
perl -i -pe 's/^(\s*)-DGGML_BLAS_DEFAULT=\$\{GGML_BLAS_DEFAULT\}$/$&\n$1-DGGML_BLAS=OFF/' "$OUT"

# Fail loudly if upstream changed shape and a patch did not apply.
grep -q '^IOS_MIN_OS_VERSION=14.0$' "$OUT"
grep -q '^GGML_METAL=OFF$' "$OUT"
grep -q '^ *-DGGML_BLAS=OFF$' "$OUT"
if grep -nE 'libggml-(blas|metal)\.a' "$OUT"; then echo "error: BLAS/Metal libs still listed"; exit 1; fi

cat >> "$OUT" <<'EOF'

echo "Building for iOS devices (iPhone 11 / A13, -march=${GGML_CPU_ARM_ARCH})..."
cmake -B build-ios-device -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DGGML_CPU_ARM_ARCH=${GGML_CPU_ARM_ARCH} \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF \
    -S .
cmake --build build-ios-device --config Release -- -quiet

setup_framework_structure "build-ios-device" ${IOS_MIN_OS_VERSION} "ios"
combine_static_libraries "build-ios-device" "Release-iphoneos" "ios" "false"

xcrun xcodebuild -create-xcframework \
    -framework $(pwd)/build-ios-device/framework/llama.framework \
    -debug-symbols $(pwd)/build-ios-device/dSYMs/llama.dSYM \
    -output $(pwd)/build-apple/llama.xcframework
EOF

bash -n "$OUT"
chmod +x "$OUT"
./"$OUT"
