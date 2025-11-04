# DiffTrace 日志格式说明

DiffTest 在检测到仿真异常时，会打印一段 “Commit Instr Trace” 帮助定位问题。下面以一次 `skiptrap` 运行时的片段为例，说明各字段含义以及我们扩展的存储日志。

```
[00] commit pc 0000000010000000 inst 0010029b wen 1 dst 05 data 0000000000000001 idx 000 addiw   t0, zero, 1
[01] commit pc 0000000010000004 inst 01f29293 wen 1 dst 05 data 0000000080000000 idx 001 slli    t0, t0, 31
...
[11] exception pc 0000000080000020 inst 04130000 cause 0000000000000002 c.unimp
[12] commit pc 000000008000003c inst 341022f3 wen 1 dst 05 data 0000000080000020 idx 00b csrr    t0, mepc
...
[29] commit pc 000000008000002e inst 00833023 wen 0 dst 00 data 0000000000000000 idx 01c (00) addr 0000000080000090 data 000000000000002a mask 0xff sd      s0, 0(t1)
```

## 核心结构

日志由两部分组成：

1. **Commit Group Trace**：列出最近若干个提交组（group），便于确认哪组指令触发异常。
2. **Commit Instr Trace**：逐条展示提交轨迹。每一行的格式为  
   `[序号] 类型 pc ... inst ... <附加信息> <反汇编>`  
   其中 `类型` 可能是 `commit`、`exception`、`interrupt`。

## `commit` 行字段

- `pc`：指令提交时的程序计数器，16 位十六进制。
- `inst`：32 位或 16 位指令编码（压缩指令仍以 32 位打印）。
- `wen` / `dst` / `data`：指令是否写回 (`wen`)，目标寄存器编号 (`dst`)，写回数据 (`data`)。
- `idx`：ROB 索引，方便与硬件日志关联。
- 可选 `(xx)`：
  - 若是 Load，括号内为 Load Queue 索引 (`lqIdx`)；
  - 若是 Store，括号内为 Store Queue 索引 (`sqIdx`)。
- 可选 `addr/data/mask`：我们在 `CONFIG_DIFFTEST_STOREEVENT` 下新增的存储日志。如果 `hasStoreInfo` 为真，会额外打印：
  - `addr`：Store 的物理地址；
  - `data`：写入数据；
  - `mask`：按字节划分的写掩码。
- 可选 `(S)`/`(D)`：`S` 表示指令被 `skip`，`D` 表示写回被延迟 (`delayed`)。
- 反汇编：若本地可用 Spike 反汇编（`spike_valid()` 为真），行尾会打印对应的指令助记符。

示例 `[29]` 中的 `(00)` 表示 Store Queue 索引为 0；紧接着的 `addr/data/mask` 则来自我们在 DiffTest 中缓存的 store event，用于观察内存写入。

## `exception` / `interrupt` 行

异常与中断行仅打印：

- `pc`：触发时的程序计数器；
- `inst`：触发异常/中断的指令编码；
- `cause`：CSR `mcause` 的值；
- （若启用 Spike）最后同样会附上助记符。

在示例 `[11]` 中，`cause 2` 对应 “非法指令”，说明 `c.unimp` 成功触发了我们预期的异常。

## 其他常见输出

- 在 `Commit Instr Trace` 之前，`Commit Group Trace` 会以  
  `commit group [NN]: pc xxxxxxxx cmtcnt yy` 的形式列出每一组的首条指令 PC 及提交条数，并在最后一组后附上 `"<--"`。
- 日志末尾通常会跟随一份 REF 寄存器快照，用于进一步比对。

## 将存储拆解为逐字节写入

`DifftestStoreEvent` 的 `mask` 字段是 8 位掩码，对应 64 位（8 字节）写入窗口的逐字节有效位。最低位代表 `addr + 0`，最高位代表 `addr + 7`。当不同指令写入的宽度小于 8 字节时，掩码会只设置被更新的字节。例如：

- `mask = 0xff`：所有 8 个字节有效，通常对应 `sd`。
- `mask = 0x03`：仅第 0/1 个字节有效，对应 `sh`。
- `mask = 0x10`：仅第 4 个字节有效，对应某次 `sb` 到 `addr + 4`。

配合 `data` 字段（按 RISC-V 小端序编码），可以将一次 Store 拆解为最细粒度的字节写入。示例代码：

```python
def expand_store(addr, data, mask):
    bytes_out = []
    for i in range(8):
        if mask & (1 << i):
            byte_val = (data >> (8 * i)) & 0xff
            bytes_out.append((addr + i, byte_val))
    return bytes_out
```

对于示例 `[29]`：

- `addr = 0x80000090`
- `data = 0x2a`
- `mask = 0xff`

展开后得到 8 个连续地址 `0x80000090`～`0x80000097`，每个字节值依次为 `0x2a`、`0x00`、`0x00`、……。这样即可在调试脚本中验证内存镜像与 DiffTrace 日志是否一致，或进一步生成波形/差异对比。

掌握以上字段含义后，可以快速从 DiffTrace 中定位异常、核对 ROB 索引，并配合我们新增的存储日志 (`addr/data/mask`) 追踪内存写入行为直至字节级别。
