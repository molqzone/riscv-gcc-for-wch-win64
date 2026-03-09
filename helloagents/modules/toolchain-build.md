# toolchain-build

## 默认配置

- 默认架构：`rv32imac`
- 默认 ABI：`ilp32`
- 附加 multilib：`rv32imafc/ilp32f`

## 修复背景

已安装 release 的 `rv32imac/ilp32` `libgcc.a` 中不存在 `__addsf3`、`__mulsf3`、`__divsf3`、`__floatsisf`、`__floatunsisf`、`__fixsfsi` 等 soft-float helper 定义，导致显式使用 `-march=rv32imac -mabi=ilp32` 时链接失败。

## 处理方式

- 调整构建默认基线到 `rv32imac/ilp32`。
- 在 GCC 下载依赖后补丁 `libgcc/config.host`，为 RISC-V 的 `tmake_file` 追加 `t-softfp-sfdf`，补齐单精度 soft-float helper 的 `libgcc` 构建规则。
- 补丁判定需要精确命中 RISC-V 目标条目，不能仅根据 config.host 全文件里是否出现 t-softfp-sfdf 决定是否跳过。
- 保留 `rv32imafc/ilp32f` multilib 作为硬浮点变体。
- 在安装后测试中编译一个包含浮点乘、浮点除、`int -> float`、`unsigned int -> float` 的样例，确保 soft-float helper 路径可用。
- 同步更新 CI 与安装器测试中的 `nano` 库文件检查路径：`rv32imac` 作为默认 multilib 时，库位于 `riscv32-unknown-elf/lib/` 根目录，而不是 `rv32imac_.../ilp32/` 子目录。
