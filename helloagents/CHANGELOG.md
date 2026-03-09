# Changelog

## [0.1.0] - 2026-03-08

### Fixed
- **[toolchain-build]**: 在 GCC 构建前补丁 `libgcc/config.host` 的 RISC-V `tmake_file`，补上 `t-softfp-sfdf`，确保 `rv32imac/ilp32` 产物内生成 `__mulsf3`、`__divsf3`、`__floatsisf`、`__floatunsisf` 等 soft-float helper。
- **[toolchain-build]**: 将 config.host 补丁条件收窄到 RISC-V 目标条目，避免被其他架构已存在的 t-softfp-sfdf 误命中而跳过修复。
- **[toolchain-build]**: 将默认工具链配置基线从 `rv32gc/ilp32` 调整为 `rv32imac/ilp32`，避免 soft-float multilib 漏掉 `__mulsf3`/`__divsf3` 等 helper 实现。
- **[tests]**: 为安装器测试和完整安装器 smoke test 增加 `rv32imac/ilp32` soft-float 链接验证，覆盖浮点乘除和整浮转换路径。
- **[ci]**: 将 `rv32imac/ilp32` 的 `nano` 运行库校验路径改为默认 multilib 根目录，匹配新的 `rv32imac` 基线布局。
