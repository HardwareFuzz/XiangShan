#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [options]

Build XiangShan emulator binaries with optional noalign memorder variants.
Outputs land in build_result/ by default.

Options:
  -j, --jobs N           Parallel jobs for make (default: 30)
      --build-root DIR   Output root directory (default: build_result)
      --num-cores N      Override NUM_CORES (default: 2)
      --rtl-suffix SUF   Override RTL_SUFFIX (default: sv)
      --align-config C   Config class for aligned-only build (default: AlignedAccessConfig)
      --unalign-config C Config class for unaligned-enabled build (default: UnalignedAccessConfig)
      --memorder         Build default noalign memorder variants (no coverage)
      --memorder-only    Only build memorder variants (skip aligned/unaligned)

  Coverage options (default: no coverage):
      --coverage         Build full coverage variants
      --coverage-light   Build light coverage variants (line/user only)

  Configuration options (choose one or both, default: both):
      --aligned          Build only aligned variants
      --unaligned        Build only unaligned variants

  -h, --help             Show this help

Output binaries (with core suffix):
  xiangshan_rv64_aligned_<N>c              - Aligned-only, no coverage
  xiangshan_rv64_unaligned_<N>c            - Unaligned-enabled, no coverage
  xiangshan_rv64_noalign_memorder_<id>_<N>c - Memorder variants (noalign, no coverage)

Examples:
  ./build.sh --memorder                       # Build memorder variants only
  ./build.sh --memorder --num-cores 2 -j 30   # Build memorder variants with 30 jobs
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKE_CMD="${MAKE:-make}"
MAKE_JOBS="${MAKE_JOBS:-30}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build_result}"
NUM_CORES="${NUM_CORES:-2}"
RTL_SUFFIX="${RTL_SUFFIX:-sv}"
ALIGN_CONFIG="${ALIGN_CONFIG:-AlignedAccessConfig}"
UNALIGN_CONFIG="${UNALIGN_CONFIG:-UnalignedAccessConfig}"
EXTRA_CONFIGS="${EXTRA_CONFIGS:-}"

# Coverage modes to build: none, full, light
COV_MODES=()
# Configurations to build: aligned, unaligned
CONFIGS=()
# Extra configs to build (name list)
EXTRA_CONFIG_LIST=()
# Memorder variants (noalign, no coverage)
MEMORDER_VARIANTS=("sb4" "sb8" "sq20" "lq24" "sq-nofwd")
BUILD_MEMORDER=0
MEMORDER_ONLY=0

# Always prefer the repo-local mill wrapper
export PATH="$ROOT_DIR:$PATH"
export NOOP_HOME="${NOOP_HOME:-$ROOT_DIR}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--jobs) MAKE_JOBS="$2"; shift 2 ;;
        --build-root) BUILD_ROOT="$2"; shift 2 ;;
        --num-cores) NUM_CORES="$2"; shift 2 ;;
        --rtl-suffix) RTL_SUFFIX="$2"; shift 2 ;;
        --align-config) ALIGN_CONFIG="$2"; shift 2 ;;
        --unalign-config) UNALIGN_CONFIG="$2"; shift 2 ;;
        --memorder) BUILD_MEMORDER=1; shift ;;
        --memorder-only) BUILD_MEMORDER=1; MEMORDER_ONLY=1; shift ;;
        --extra-configs) EXTRA_CONFIGS="$2"; shift 2 ;;
        --coverage|-c) COV_MODES+=("full"); shift ;;
        --coverage-light) COV_MODES+=("light"); shift ;;
        --no-coverage|-n) COV_MODES+=("none"); shift ;;
        --aligned) CONFIGS+=("aligned"); shift ;;
        --unaligned) CONFIGS+=("unaligned"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# Default: build no coverage unless explicitly requested
if [[ ${#COV_MODES[@]} -eq 0 ]]; then
    COV_MODES=("none")
fi

# Default: build all configs if none specified
if [[ ${#CONFIGS[@]} -eq 0 ]]; then
    CONFIGS=("aligned" "unaligned")
fi

if [[ -n "$EXTRA_CONFIGS" ]]; then
    IFS=',' read -r -a EXTRA_CONFIG_LIST <<< "$EXTRA_CONFIGS"
fi

if [[ $MEMORDER_ONLY -eq 1 ]]; then
    CONFIGS=()
fi

mkdir -p "$BUILD_ROOT"

build_variant() {
    local name="$1" config="$2" cov_mode="$3"
    local target="emu"
    local out_root="$BUILD_ROOT/$name"
    if [[ "$cov_mode" == "full" ]]; then
        target="emu-cov"
    elif [[ "$cov_mode" == "light" ]]; then
        target="emu-cov-light"
    fi

    rm -rf "$out_root"
    mkdir -p "$out_root/rtl" "$out_root/generated-src"

    # Ensure helper artifacts are visible under variant BUILD_DIR before make runs
    local helper_files=(
        chisel_db.cpp chisel_db.h
        perfCCT.cpp perfCCT.h
        constantin.cpp constantin.hpp constantin.txt
        DifftestMacros.v
        diffstate.h difftest-dpic.cpp difftest-dpic.h difftest-query.h
    )
    for f in "${helper_files[@]}"; do
        case "$f" in
            DifftestMacros.v)
                ln -sf "$ROOT_DIR/build/generated-src/$f" "$out_root/rtl/$f"
                ;;
            diffstate.h|difftest-dpic.cpp|difftest-dpic.h|difftest-query.h)
                ln -sf "$ROOT_DIR/build/generated-src/$f" "$out_root/generated-src/$f"
                ;;
            *)
                ln -sf "$ROOT_DIR/build/$f" "$out_root/$f"
                ;;
        esac
    done

    local bin_path="$out_root/emu"
    if [[ "$cov_mode" == "full" ]]; then
        bin_path="$out_root/emu-cov"
    elif [[ "$cov_mode" == "light" ]]; then
        bin_path="$out_root/emu-cov-light"
    fi

    local artifact_name=""
    local core_suffix="_${NUM_CORES}c"
    if [[ "$name" == "aligned" || "$name" == "unaligned" ]]; then
        case "${name}:${cov_mode}" in
            aligned:none) artifact_name="xiangshan_rv64_aligned${core_suffix}" ;;
            aligned:full) artifact_name="xiangshan_rv64_aligned${core_suffix}_cov" ;;
            aligned:light) artifact_name="xiangshan_rv64_aligned${core_suffix}_light" ;;
            unaligned:none) artifact_name="xiangshan_rv64_unaligned${core_suffix}" ;;
            unaligned:full) artifact_name="xiangshan_rv64_unaligned${core_suffix}_cov" ;;
            unaligned:light) artifact_name="xiangshan_rv64_unaligned${core_suffix}_light" ;;
            *) echo "Unknown build variant: ${name} (cov_mode=${cov_mode})" >&2; exit 1 ;;
        esac
    else
        local suffix=""
        case "$cov_mode" in
            full) suffix="_cov" ;;
            light) suffix="_light" ;;
            none) suffix="" ;;
        esac
        artifact_name="xiangshan_rv64_${name}${core_suffix}${suffix}"
    fi

    echo "Building ${artifact_name} (config=${config})..."
    "$MAKE_CMD" -C "$ROOT_DIR" -j"$MAKE_JOBS" \
        BUILD_DIR="$out_root" \
        CONFIG="$config" \
        NUM_CORES="$NUM_CORES" \
        RTL_SUFFIX="$RTL_SUFFIX" \
        EMU_BUILD_JOBS="$MAKE_JOBS" \
        "$target"

    # Refresh helper files after build in case they were regenerated
    for f in "${helper_files[@]}"; do
        case "$f" in
            DifftestMacros.v)
                if [[ -f "$ROOT_DIR/build/generated-src/$f" ]]; then
                    src="$ROOT_DIR/build/generated-src/$f"
                    dest="$out_root/rtl/$f"
                    if [[ ! "$src" -ef "$dest" ]]; then
                        cp -f "$src" "$dest"
                    fi
                fi
                ;;
            diffstate.h|difftest-dpic.cpp|difftest-dpic.h|difftest-query.h)
                if [[ -f "$ROOT_DIR/build/generated-src/$f" ]]; then
                    src="$ROOT_DIR/build/generated-src/$f"
                    dest="$out_root/generated-src/$f"
                    if [[ ! "$src" -ef "$dest" ]]; then
                        cp -f "$src" "$dest"
                    fi
                fi
                ;;
            *)
                if [[ -f "$ROOT_DIR/build/$f" ]]; then
                    src="$ROOT_DIR/build/$f"
                    dest="$out_root/$f"
                    if [[ ! "$src" -ef "$dest" ]]; then
                        cp -f "$src" "$dest"
                    fi
                fi
                ;;
        esac
    done

    local out="$BUILD_ROOT/$artifact_name"
    cp "$bin_path" "$out"
    echo "  -> $out"
}

# Build selected variants
for config in "${CONFIGS[@]}"; do
    case "$config" in
        aligned)
            for cov_mode in "${COV_MODES[@]}"; do
                build_variant aligned "$ALIGN_CONFIG" "$cov_mode"
            done
            ;;
        unaligned)
            for cov_mode in "${COV_MODES[@]}"; do
                build_variant unaligned "$UNALIGN_CONFIG" "$cov_mode"
            done
            ;;
    esac
 done

if [[ $BUILD_MEMORDER -eq 1 ]]; then
    for variant in "${MEMORDER_VARIANTS[@]}"; do
        case "$variant" in
            sb4) build_variant "noalign_memorder_sb4" "MemOrderSB4Config" "none" ;;
            sb8) build_variant "noalign_memorder_sb8" "MemOrderSB8Config" "none" ;;
            sq20) build_variant "noalign_memorder_sq20" "MemOrderSQ20Config" "none" ;;
            lq24) build_variant "noalign_memorder_lq24" "MemOrderLQ24Config" "none" ;;
            sq-nofwd) build_variant "noalign_memorder_sq-nofwd" "MemOrderSQNoForwardConfig" "none" ;;
        esac
    done
fi

