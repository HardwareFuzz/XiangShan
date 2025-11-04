    .section .text
    .globl _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0

    csrr    t0, mstatus
    li      t1, 0x00003000
    or      t0, t0, t1
    csrw    mstatus, t0
    csrw    fcsr, x0

    j       user_code

user_code:
    c.unimp                     # 故意触发非法指令异常
    addi    s0, zero, 42         # 若成功跳过异常，将执行到这里
    la      t1, skiptrap_store_buf
    sd      s0, 0(t1)            # 触发一次对内存的写入，便于观察日志

    # 浮点寄存器演示：写入常数 1.5 并做一次浮点加法
    li      t2, 0x3fc00000       # 1.5f 的 bit pattern
    fmv.w.x ft0, t2              # 将整数写入 ft0 (F0)
    fadd.s  ft1, ft0, ft0        # ft1 = 3.0f, 触发 F1 写回

    # 再写入一个两位编号寄存器，覆盖 ft10 (=F10)
    li      t3, 0x40000000       # 2.0f
    fmv.w.x ft10, t3
    fadd.s  ft11, ft10, ft10     # ft11 = 4.0f，触发 F11 写回
exit:
    li      t0, 0
exit:
    li      t0, 0                # 0 -> DiffTest STATE_GOODTRAP (padding)
    li      t0, 0
    li      t0, 0
    .insn   i 0x6b, 0, x0, t0, 0 # XiangShan custom trap，rs1 携带退出码
exit_spin:
1:
    j       1b                   # 若仿真未立即停止，保持在安全自旋

    .align  2
trap_handler:
    csrr    t0, mepc             # 触发异常的指令地址
    csrr    t1, mcause           # 异常原因
    csrr    t4, mtval

    slli    t5, t1, 1
    srli    t1, t5, 1            # 去掉 msb 的 interrupt bit

    li      t2, 2                # 默认假定是 16bit 指令
    li      t3, 2                # mcause=2 -> illegal instruction
    beq     t1, t3, use_mtval
    li      t3, 1                # instruction access fault
    beq     t1, t3, fetch_inst
    li      t3, 12               # instruction page fault
    beq     t1, t3, fetch_inst

fetch_inst:
    lhu     t4, 0(t0)
    j       decode_length

use_mtval:
    j       decode_length

decode_length:
    andi    t4, t4, 3
    li      t3, 3
    bne     t4, t3, compressed_len
    li      t2, 4
    j       update_mepc

compressed_len:
    li      t2, 2

update_mepc:
    add     t0, t0, t2           # 跳过异常指令
    csrw    mepc, t0
    csrw    mcause, x0
    csrw    mtval, x0
    mret

    .section .data
    .align  3
skiptrap_store_buf:
    .dword  0

    .section .tohost,"aw",@progbits
    .align  3
    .globl tohost
    .globl fromhost
    tohost:
        .dword 0
    fromhost:
        .dword 0
