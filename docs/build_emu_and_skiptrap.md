# 构建 `build/emu`、正常退出仿真与 DiffTest 改动说明

本文档总结了当前工作流中最常用的三个主题：

1. 如何配置环境并产出 `build/emu`
2. 如何借助 `software/skiptrap/skiptrap.S` 演示一次可控的 GOODTRAP 退出
3. 我们在 `difftest` 子模块里为了观察内存写入日志所做的定制改动

---

## 构建 `build/emu`

1. **准备依赖**
   - 环境变量：
     - `NOOP_HOME` 设为 XiangShan 根目录，例如 `export NOOP_HOME=$PWD`。
     - 若只想使用仓库自带的预构建资产，可直接把 `NEMU_HOME` 与 `AM_HOME` 都指向 `ready-to-run`（也常被称为 “ready-to-go”）子模块：  
       `export NEMU_HOME=$NOOP_HOME/ready-to-run`  
       `export AM_HOME=$NOOP_HOME/ready-to-run`
     - 若需要自行编译 NEMU/AM，可改为各自源码目录。
   - 工具链：`Verilator`、`mill`、任意可用的 RISC-V GNU 工具链（用于编译软件镜像）。
     - 仓库根目录自带 `./mill` 启动脚本；为确保 `make` 与其他脚本调用到本地版本，可执行  
       `export PATH=$NOOP_HOME:$PATH` 或直接在命令中使用 `./mill ...`。
   - 仓库初始化：在 XiangShan 根目录执行
     ```bash
     git submodule update --init --recursive --depth 1
     cd rocket-chip && git submodule update --init --depth 1 cde hardfloat
     cd openLLC && git submodule update --init --depth 1 openNCB
     ```
     上述命令与 `make init` 等价，但通过 `--depth 1` 控制浅克隆，可显著降低下载量；如需完整历史，可去掉该参数。
2. **执行构建**
   ```bash
   # 在 XiangShan 根目录
   NOOP_HOME=/home/canxin/XiangShan NEMU_HOME=/home/canxin/XiangShan/ready-to-run AM_HOME=/home/canxin/XiangShan/ready-to-run PATH=/home/canxin/XiangShan:$PATH IN_XSDEV_DOCKER=y make emu -j$(nproc)
   ```
   - 以上命令会在 `build/` 下生成 Verilator 中间文件，并输出 `build/emu`。
   - `CONFIG`、`EMU_THREADS` 可按需要覆盖；其他常见参数可在 `Makefile` 与 `verilator.mk` 中查阅。
3. **验证产物**
   ```bash
   ./build/emu --help
   ```
   - 若能打印命令行参数说明，即表示编译链路就绪。

---

## 使用 `skiptrap` 正常退出仿真

`software/skiptrap/skiptrap.S` 用于演示「触发异常 → 修补 → 主动 GOODTRAP」的流程，并在退出前做一次可观测的内存写入。

1. **生成镜像**
   ```bash
   cd software/skiptrap
   make          # 生成 skiptrap.bin
   ```
2. **运行并观察退出**
   ```bash
   cd $NOOP_HOME
   ./build/emu -i software/skiptrap/skiptrap.bin \
     --diff ready-to-run/riscv64-nemu-interpreter-so
   ```
   - 首条指令是 `c.unimp`（故意触发非法指令异常），陷入 `trap_handler` 后会修正 `mepc` 并返回。
   - 成功返回后，程序会：
     1. `sd s0, (skiptrap_store_buf)` —— 触发一次内存写，以便 DiffTest 输出完整的地址/数据/掩码日志。
     2. `li t0, 0` 并通过 `.insn i 0x6b, 0, x0, t0, 0` 触发 XiangShan 自定义陷阱，`t0=0` 代表 `STATE_GOODTRAP`。
     3. 进入一个自旋标签 `1:`，防止仿真器在捕获 GOODTRAP 之前继续跑飞。
   - 因为 `t0=0`，`build/emu` 会以「DiffTest STATE_GOODTRAP」状态退出；若打开 `--dump-difftrace`，可以看到新增的内存写日志。

---

## DiffTest 子模块的日志增强

为追踪上述 `skiptrap`（以及后续测试）里的 store，我们在 `difftest` 子模块做了以下改动：

1. **提交轨迹携带写入详情**  
   - `src/test/csrc/difftest/difftest.cpp` 的 `do_instr_commit()` 在 `CONFIG_DIFFTEST_STOREEVENT` 下调用 `get_store_event_info()`，将 ROB 索引对应的地址、数据、掩码打包到 `state->record_inst()`。
   - `src/test/csrc/difftest/difftest.h` 的 `InstrTrace` 结构新增 `hasStoreInfo/storeAddr/storeData/storeMask` 字段，`display_custom()` 会把这些信息打印到 difftrace 中。
2. **建立 `store_event_cache`**  
   - 在 `store_event_record()` 中把每个有效 `dut->store[i]` 同时推入 `store_event_queue` 与 `store_event_cache[robidx]`，以便后续按 ROB 索引查询。
   - `do_store_check()` 在事件被消费或丢弃时同步 `erase()` 缓存，防止陈旧数据撑爆内存。
   - `get_store_event_info()` 封装了对缓存的查询逻辑，供 `do_instr_commit()`/`state->record_inst()` 调用。

通过这些调整，`build/emu` 的 difftrace 会在每条存储指令提交时打印「addr/data/mask」，使我们能够快速定位 GOODTRAP 退出前的内存写入行为。
