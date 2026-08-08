#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

Build XiangShan emulator binaries.

Options:
  -j, --jobs N           Parallel jobs for make (default: 30)
      --build-root DIR   Intermediate build root directory (default: ./build_result)
      --isa ISA          ISA tag used in artifact name (rv64f|rv64fd; default: rv64fd)
      --cores N          Number of cores (default: 1)
      --rtl-suffix SUF   RTL suffix passed to make (default: sv)
      --out-dir DIR      Output directory for the final binary (default: --build-root)
                         You can also set CX_OUT_DIR (shared across repos) or OUT_DIR.
      --preset NAME      Build preset:
                         aligned | unaligned
                         If omitted for the standard minimal build, defaults to `unaligned`
      --config CLASS     Override CONFIG (e.g. MinimalConfig, DefaultConfig, ...)
      --tag TAG          Optional tag inserted into artifact name

  Coverage modes (default: none):
      --coverage         Build coverage variant (_cov)
      --coverage-light   Build light coverage variant (_cov_light)
      --no-coverage      Explicitly disable coverage (default)

  Maintenance:
      --clean            Remove the selected artifact and its build dir
  -h, --help             Show this help

Artifact naming:
  <out-dir>/xiangshan_<isa>_<tag>_<N>c[_cov|_cov_light]
  (tag is optional)

Notes:
  --isa currently affects artifact naming only; RTL/config is not ISA-specialized.
  rv64f/rv64fd artifacts intentionally reuse the canonical rv64 build output for the
  same preset/config/core-count/coverage tuple.

Examples:
  ./build.sh --preset unaligned --cores 1
  ./build.sh --cores 1 --coverage-light
  ./build.sh --preset aligned --cores 1
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKE_CMD="${MAKE:-make}"
MAKE_JOBS="${MAKE_JOBS:-30}"
BUILD_ROOT_DEFAULT="$ROOT_DIR/build_result"
BUILD_ROOT="${BUILD_ROOT:-$BUILD_ROOT_DEFAULT}"
OUT_DIR_OPT=""

ISA="${ISA:-rv64fd}"
CORES="${CORES:-1}"
RTL_SUFFIX="${RTL_SUFFIX:-sv}"
PRESET=""
CONFIG=""
TAG=""
COV_MODE="none" # none|full|light
DO_CLEAN=0

# Prefer the repo-local mill wrapper if present.
export PATH="$ROOT_DIR:$PATH"
export NOOP_HOME="${NOOP_HOME:-$ROOT_DIR}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--jobs) MAKE_JOBS="$2"; shift 2 ;;
    --build-root) BUILD_ROOT="$2"; shift 2 ;;
    --isa) ISA="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --rtl-suffix) RTL_SUFFIX="$2"; shift 2 ;;
    --out-dir) OUT_DIR_OPT="$2"; shift 2 ;;
    --out-dir=*) OUT_DIR_OPT="${1#*=}"; shift ;;
    --preset) PRESET="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --coverage) COV_MODE="full"; shift ;;
    --coverage-light) COV_MODE="light"; shift ;;
    --no-coverage) COV_MODE="none"; shift ;;
    --clean) DO_CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$ISA" in
  rv64f|rv64fd) ;;
  *) die "unsupported --isa '$ISA' (supported: rv64f, rv64fd)" ;;
esac

[[ "$CORES" =~ ^[0-9]+$ ]] || die "--cores must be an integer"
(( CORES >= 1 )) || die "--cores must be >= 1"

# The published XiangShan artifacts always carry an explicit alignment tag.
if [[ -z "$PRESET" && -z "$CONFIG" && -z "$TAG" ]]; then
  PRESET="unaligned"
fi

preset_tag=""
if [[ -n "$PRESET" ]]; then
  case "$PRESET" in
    aligned)
      CONFIG="${CONFIG:-AlignedAccessConfig}"
      preset_tag="aligned"
      ;;
    unaligned)
      CONFIG="${CONFIG:-UnalignedAccessConfig}"
      preset_tag="unaligned"
      ;;
    *)
      die "unknown --preset '$PRESET'"
      ;;
  esac
fi

CONFIG="${CONFIG:-MinimalConfig}"
if [[ -z "$TAG" && -n "$preset_tag" ]]; then
  TAG="$preset_tag"
fi

cov_suffix=""
emu_name="emu"
case "$COV_MODE" in
  none)
    cov_suffix=""
    emu_name="emu"
    ;;
  full)
    cov_suffix="_cov"
    emu_name="emu-cov"
    ;;
  light)
    cov_suffix="_cov_light"
    emu_name="emu-cov-light"
    ;;
  *) die "internal: unknown COV_MODE '$COV_MODE'" ;;
esac

artifact_name_base="xiangshan_${ISA}"
if [[ -n "$TAG" ]]; then
  artifact_name_base+="_${TAG}"
fi
artifact_name_base+="_${CORES}c"

build_isa="rv64"
build_name_base="xiangshan_${build_isa}"
if [[ -n "$TAG" ]]; then
  build_name_base+="_${TAG}"
fi
build_name_base+="_${CORES}c"

OUT_DIR_DEFAULT="${BUILD_ROOT}"
OUT_DIR="${OUT_DIR_OPT:-${CX_OUT_DIR:-${OUT_DIR:-${OUT_DIR_DEFAULT}}}}"

artifact="$OUT_DIR/${artifact_name_base}${cov_suffix}"
canonical_artifact="$OUT_DIR/${build_name_base}${cov_suffix}"
workdir="$BUILD_ROOT/.work/${build_name_base}${cov_suffix}"
build_meta_file="$workdir/.build-meta"

if [[ $DO_CLEAN -eq 1 ]]; then
  rm -f "$artifact"
  if [[ "$ISA" == "$build_isa" ]]; then
    rm -rf "$workdir"
    echo "cleaned artifact and canonical build: $artifact"
  else
    echo "cleaned alias artifact: $artifact"
  fi
fi

mkdir -p "$BUILD_ROOT" "$OUT_DIR"

if [[ "$ISA" != "$build_isa" && -f "$canonical_artifact" ]]; then
  echo "Building $artifact"
  echo "  artifact ISA tag=$ISA (reuses canonical artifact $canonical_artifact)"
  cp -f "$canonical_artifact" "$artifact"
  echo "  -> $artifact"
  exit 0
fi

target="emu"
case "$COV_MODE" in
  none) target="emu" ;;
  full) target="emu-cov" ;;
  light) target="emu-cov-light" ;;
esac

SIM_ARGS_BUILD="${SIM_ARGS:-}"
# Provider bins rely on compact difftest commit trace plus explicit retire/store/trap prints,
# so keep the noisy global debug stream disabled unless the caller explicitly opts in.
for required_arg in --disable-perf --disable-alwaysdb; do
  case " ${SIM_ARGS_BUILD} " in
    *" ${required_arg} "*) ;;
    *) SIM_ARGS_BUILD="${SIM_ARGS_BUILD:+$SIM_ARGS_BUILD }${required_arg}" ;;
  esac
done

build_meta=$(cat <<EOF
ISA=${build_isa}
CORES=${CORES}
RTL_SUFFIX=${RTL_SUFFIX}
PRESET=${PRESET}
CONFIG=${CONFIG}
TAG=${TAG}
COV_MODE=${COV_MODE}
TARGET=${target}
SIM_ARGS=${SIM_ARGS_BUILD}
EOF
)

if [[ -f "$build_meta_file" ]]; then
  if [[ "$(cat "$build_meta_file")" != "$build_meta" ]]; then
    rm -rf "$workdir"
  fi
fi
mkdir -p "$workdir"
printf '%s\n' "$build_meta" > "$build_meta_file"

echo "Building $artifact"
echo "  CONFIG=$CONFIG"
echo "  NUM_CORES=$CORES"
echo "  RTL_SUFFIX=$RTL_SUFFIX"
echo "  target=$target"
echo "  sim_args=$SIM_ARGS_BUILD"
if [[ "$ISA" != "$build_isa" ]]; then
  echo "  artifact ISA tag=$ISA (reuses canonical build ISA=$build_isa)"
fi

"$MAKE_CMD" -C "$ROOT_DIR" -j"$MAKE_JOBS" \
  BUILD_DIR="$workdir" \
  CONFIG="$CONFIG" \
  NUM_CORES="$CORES" \
  RTL_SUFFIX="$RTL_SUFFIX" \
  EMU_BUILD_JOBS="$MAKE_JOBS" \
  SIM_ARGS="$SIM_ARGS_BUILD" \
  "$target"

bin_path="$workdir/$emu_name"
[[ -f "$bin_path" ]] || die "expected emulator binary not found: $bin_path"
cp -f "$bin_path" "$artifact"
echo "  -> $artifact"
