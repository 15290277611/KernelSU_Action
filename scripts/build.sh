
#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ============================================================
# Defconfig
# ============================================================

prepare_defconfig() {
    group "Preparing defconfig"

    [ -f "$DEFCONFIG_PATH" ] \
        || die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

    cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

    local kver
    kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

    if [ "${KSU_VARIANT:-none}" != "none" ]; then
        kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
        ksu_hook_configs \
            "${KSU_VARIANT}" \
            "${KSU_HOOK_MODE:-auto}" \
            "$DEFCONFIG_PATH" "$kver"

        if is_true "${ENABLE_SUSFS:-false}"; then
            susfs_defconfig "$DEFCONFIG_PATH"
        fi

        if is_true "${ENABLE_KPM:-false}"; then
            kconf_set_many "$DEFCONFIG_PATH" \
                CONFIG_KPM=y \
                CONFIG_KALLSYMS=y \
                CONFIG_KALLSYMS_ALL=y
        fi
    fi

    if is_true "${ADD_OVERLAYFS_CONFIG:-false}"; then
        kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS
    fi

    if is_true "${ADD_KPROBES_CONFIG:-false}"; then
        kconf_set_many "$DEFCONFIG_PATH" \
            CONFIG_MODULES=y \
            CONFIG_KPROBES=y \
            CONFIG_HAVE_KPROBES=y \
            CONFIG_KPROBE_EVENTS=y
    fi

    if is_true "${DISABLE_LTO:-false}"; then
        kconf_set_many "$DEFCONFIG_PATH" \
            CONFIG_LTO=n \
            CONFIG_LTO_CLANG=n \
            CONFIG_LTO_CLANG_FULL=n \
            CONFIG_LTO_CLANG_THIN=n \
            CONFIG_THINLTO=n \
            CONFIG_LTO_NONE=y
    fi

    if is_true "${DISABLE_CC_WERROR:-false}"; then
        kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR
    fi

    if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
        local kv
        for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
            [ -n "$kv" ] || continue

            case "$kv" in
                *=*)
                    kconf_set \
                        "$DEFCONFIG_PATH" \
                        "${kv%%=*}" \
                        "${kv#*=}"
                    ;;
                *)
                    warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}'"
                    ;;
            esac
        done
    fi

    if [ -n "${KERNEL_NAME:-}" ]; then
        kconf_set \
            "$DEFCONFIG_PATH" \
            CONFIG_LOCALVERSION \
            "\"-${KERNEL_NAME}\""

        if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
            sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' \
                "${KERNEL_DIR}/scripts/setlocalversion"
        fi
    fi

    info "defconfig changes:"

    diff -u \
        "${WORKSPACE}/defconfig.orig" \
        "$DEFCONFIG_PATH" \
        | sed -n '4,$p' \
        | sed 's/^/    /' || true

    endgroup
}

# ============================================================
# Build arguments
# ============================================================

make_args() {
    printf '%s' "O=out ARCH=${ARCH}"

    [ -n "${CUSTOM_CMDS:-}" ] && \
        printf ' %s' "$CUSTOM_CMDS"

    [ -n "${EXTRA_CMDS:-}" ] && \
        printf ' %s' "$EXTRA_CMDS"

    [ -n "${GCC_64:-}" ] && \
        printf ' %s' "$GCC_64"

    [ -n "${GCC_32:-}" ] && \
        printf ' %s' "$GCC_32"

    if is_true "${USE_LLVM:-false}"; then
        printf ' LLVM=1 LLVM_IAS=1'

        [ -n "${GCC_64:-}" ] || \
            printf ' CROSS_COMPILE=aarch64-linux-gnu-'
    fi
}

# ============================================================
# Kernel build
# ============================================================

build_kernel() {
    group "Building kernel"

    export PATH="${CLANG_PATH:-}:${PATH}"
    export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
    export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

    unset DISABLE_LTO

    if [ -n "${KSU_EXPECTED_SIZE:-}" ] && \
       [ -n "${KSU_EXPECTED_HASH:-}" ]; then

        export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH

        info "using custom manager signature"
    fi

    local cc="clang"
    local args

    # Force Clang to target ARM64.
    # Use LLVM integrated assembler instead of /usr/bin/as.
    local clang_target="aarch64-linux-gnu"
    local clang_flags="--target=${clang_target} -integrated-as"

    if [ "$ARCH" != "arm64" ]; then
        clang_flags=""
    fi

    if is_true "${ENABLE_CCACHE:-true}" && \
       command -v ccache >/dev/null; then

        cc="ccache clang"

        export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"

        info "ccache enabled (dir: ${CCACHE_DIR})"
    fi

    args=$(make_args)

    cd "$KERNEL_DIR"

    info "Kernel architecture: ${ARCH}"
    info "Clang target: ${clang_target}"
    info "Clang flags: ${clang_flags}"

    info "Checking compiler"

    command -v clang || die "clang not found"

    clang --version | head -n 1

    info "Generating kernel configuration"

    # shellcheck disable=SC2086
    make -j"$(nproc --all)" \
        CC="clang ${clang_flags}" \
        $args \
        "${KERNEL_CONFIG}" \
        || die "defconfig generation failed"

    info "Compiling kernel"

    # shellcheck disable=SC2086
    make -j"$(nproc --all)" \
        CC="${cc} ${clang_flags}" \
        $args \
        || die "kernel build failed"

    endgroup
}

# ============================================================
# Verify build output
# ============================================================

check_output() {
    group "Checking build output"

    local boot="${OUT}/arch/${ARCH}/boot"
    local image="${boot}/${KERNEL_IMAGE_NAME}"

    [ -f "$image" ] || die "expected kernel image not found: ${image}
Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
Check KERNEL_IMAGE_NAME."

    ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"

    export_env CHECK_FILE_IS_OK true

    if is_true "${NEED_DTBO:-false}"; then
        [ -f "${boot}/dtbo.img" ] \
            || die "NEED_DTBO=true but dtbo.img was not produced"

        export_env CHECK_DTBO_IS_OK true

        ok "dtbo.img present"
    fi

    if is_true "${ENABLE_KPM:-false}"; then
        kpm_patch_image "$image"
    fi

    if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
        local rel

        rel=$(sed -nE \
            's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' \
            "${OUT}/include/generated/utsrelease.h")

        export_env KERNEL_RELEASE "$rel"

        ok "kernel release: ${rel}"

        summary "| Kernel release | \`${rel}\` |"
    fi

    endgroup
}

# ============================================================
# Entry point
# ============================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-all}" in
        defconfig)
            prepare_defconfig
            ;;
        compile)
            build_kernel
            ;;
        check)
            check_output
            ;;
        all)
            prepare_defconfig
            build_kernel
            check_output
            ;;
        *)
            die "unknown build step '$1'"
            ;;
    esac
fi
