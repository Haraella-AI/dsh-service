# Spec Delta

## MODIFIED Requirements

### Requirement: 卸载范围

`dshctl uninstall [--purge] [--remove-dsh-home] [--remove-node] [--yes]` SHALL 要求确认
（交互式提示，或在非交互环境中使用 `--yes`），然后禁用并停止 unit，移除 unit 文件及其备份、
本地 `dsh` 入口点、已安装的 `dshctl` 以及本地 bash 补全脚本文件。服务配置目录和 shell rc 块
SHALL 仅在使用 `--purge` 时移除，`DSH_HOME` 仅在使用 `--remove-dsh-home` 时移除，Node 版本
仅在使用 `--remove-node` 时移除。此命令 SHALL 永不移除全局安装的 npm 包。

#### Scenario: 默认卸载

- **WHEN** 仅指定 `--yes`
- **THEN** unit、本地入口点、`dshctl` 与本地 bash 补全脚本文件被移除
- **AND** 配置目录、shell rc 块、`DSH_HOME` 和 Node 安装被保留

#### Scenario: 补全 source 行在块移除时一并清理

- **WHEN** 指定了 `--purge`
- **THEN** 含补全 source 行的整个 dsh-service rc 块被移除
- **AND** `~/.bashrc` 的其余内容保持不变

#### Scenario: 用户拒绝确认

- **WHEN** 用户未确认
- **THEN** 命令记录操作已取消并以退出码 0 退出，不做任何更改

#### Scenario: Purge 清理

- **WHEN** 指定了 `--purge`
- **THEN** 配置目录连同带标记的 shell rc 块一起被移除

#### Scenario: Node 移除失败

- **WHEN** 移除 Node 版本失败
- **THEN** 命令发出警告，并告知用户手动处理

#### Scenario: 保留全局包

- **WHEN** 卸载完成
- **THEN** 命令说明全局 npm 包（包括 pnpm）必须手动移除
