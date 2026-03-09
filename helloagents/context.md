# 项目上下文

## 仓库用途

该仓库用于构建、打包并分发 Windows 版 `riscv32-unknown-elf` 工具链，并生成安装器与安装后冒烟测试。

## 当前问题

- 已安装的 release 位于 `C:/Users/keruth/riscv`。
- `rv32imac/ilp32` 的 `libgcc.a` 缺少 `__mulsf3`、`__divsf3`、`__floatsisf`、`__floatunsisf` 等 soft-float helper 定义。
- `rv32imafc/ilp32f` 链接正常，问题集中在 soft-float multilib。

## 当前处理策略

- 将默认配置基线从 `rv32gc/ilp32` 调整为 `rv32imac/ilp32`。
- 保留 `rv32imafc/ilp32f` multilib。
- 在安装器测试与 CI 中增加 soft-float 链接冒烟测试，防止回归。

