## ROB Fusion Disable Summary

- `src/main/scala/xiangshan/backend/decode/DecodeUnit.scala`
  - Forces `decodedInst.canRobCompress := false.B` for every decoded instruction so the rename stage never attempts multi-instruction ROB compression.
  - Ensures the value propagated to downstream logic is always `false.B`, preventing accidental re-enabling across FTQ boundaries.

- `src/main/scala/xiangshan/backend/CtrlBlock.scala`
  - Wraps the fusion commit-type rewrite with the existing `disableFusion` guard, so commit types stay unfused when fusion is globally disabled.
  - Keeps decode fusion bookkeeping aligned by blocking `decode.io.fusion(i)` when fusion is disabled.

- Rebuild workflow after these RTL changes:
  1. `NOOP_HOME=$PWD make sim-verilog CONFIG=MinimalConfig NUM_CORES=1 RTL_SUFFIX=sv`
  2. `NOOP_HOME=$PWD/difftest make clean-obj`
  3. `NOOP_HOME=$PWD make emu NUM_CORES=1 RTL_SUFFIX=sv EMU_THREADS=32 -j128`
  4. Copy the resulting `build/emu` binary into the fuzz-test repository as needed.
