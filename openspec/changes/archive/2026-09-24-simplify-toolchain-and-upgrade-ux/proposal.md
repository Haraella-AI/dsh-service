# Proposal

## Why

安装器及其维护工具中累积了三处摩擦：

1. 可选的构建工具链步骤（`--with-build-tools`）存在的唯一目的，是覆盖一个已不再发生的失败场景：dsh 的每个依赖都以预构建形式发布，而该选项却引入了一条针对特定发行版的 `sudo apt-get`/`dnf` 代码路径——它未经测试、平台脆弱，还迫使安装器保留它并不需要的知识。
2. 安装器默认仍会准备 Node 22。新安装应当从 Node 24 开始；当前默认值还会把每台新机器固定到最早过期的版本上。
3. `dshctl upgrade <version>` 只能通过 npm 原始的 `ETARGET` 输出暴露版本错误。正如在一台真实机器上观察到的：

   ```
   $ dshctl upgrade 1.7.0-rc.1
   ==> 升级 @deepseek-ai/dsh: 0.1.5-rc.3 -> 1.7.0-rc.1
   npm error code ETARGET
   npm error notarget No matching version found for @deepseek-ai/dsh@1.7.0-rc.1.
   ERROR npm 安装失败，服务未做任何改动（当前仍为 0.1.5-rc.3）
   ```

   该命令丢弃了可操作的部分（`No matching version found`），也让用户无从得知究竟存在哪些版本。

## What Changes

- **BREAKING** — 彻底移除构建工具链功能：`--with-build-tools` 标志、其选项解析、`detect_pkg_manager`/`distro_name`/`ensure_build_tools`、安装器的摘要行、`--help` 与头部文本，以及记录该功能的 README 章节。传入已移除的标志会变成普通的“未知选项”错误（退出码 1）。安装器不再为任何事调用 `sudo`，唯一的例外是 `loginctl enable-linger`；需要编译器的用户可按照文档建议自行安装。
- 将安装器的默认 Node 主版本从 22 改为 24，仅针对**新**安装。在服务配置已记录可用 Node 二进制目录的机器上重新运行 `install.sh` 时，会保留现有 Node 版本，而不会准备 24；切换现有安装需要显式指定 `--node-major 24` 或执行 `dshctl upgrade-node 24`。
- 新增 `dshctl upgrade --list [N]`，用于从已配置的 registry 列出可用的 `@deepseek-ai/dsh` 版本——最新在前，并标记带 tag 的发布——默认限制条目数量。
- 在安装前，先针对 registry 预校验显式请求的升级目标。不存在的版本或 dist-tag 现在会在开始时就失败，并给出指明 `--list` 命令和当前最新版本的有针对性消息，而不是抛出 npm 的 `ETARGET`。如果无法访问 registry，则跳过该检查并给出警告，原有的安装/验证/回滚流程保持不变。
- 将版本未找到提示保留为安全网，以应对包在检查与安装之间消失的竞态，方法是识别 npm 的 notarget/ETARGET 输出。
- 更新项目文档与 OpenSpec 项目上下文，使其不再描述 Node 22 或构建工具链步骤。

## Capabilities

### New Capabilities

无——未引入新能力；`--list` 扩展的是现有的维护面。

### Modified Capabilities

- `installation`：移除 “Optional Build Toolchain Installation” 需求；从 CLI 选项契约中删除 `--with-build-tools`；将默认 Node 主版本改为 24，并定义重新运行时如何保留现有安装的 Node；从安装摘要中删除构建工具状态。
- `maintenance`：扩展升级的版本解析契约，加入查找与预校验，并为列出可用版本以及版本未找到诊断新增一条需求。
- `offline-tests`：更新验证契约，使测试套件覆盖新的默认 Node 主版本、现有 Node 保留路径、`upgrade --list` 以及无效版本诊断，并不再断言构建工具链行为。

## Non-goals

- 不改变 dsh 自身支持的 Node 下限：`dshctl doctor` 继续接受 Node ≥ 22，因为运行在 Node 22 上的现有安装仍然有效，不能开始无法通过健康检查。
- 不把现有安装自动迁移到 Node 24；Node 升级始终是用户的显式操作。
- 不把 `--list` 做成交互式版本选择器，也不添加 release notes、changelog，或超出“最新在前加数量限制”的版本过滤。
- 不改变普通 `dshctl upgrade` 解析 `latest` 及其他 dist-tag 的方式。
- 不改变 pnpm 处理、镜像/registry 设置，或导出/导入、插件与卸载路径。
- 不添加按需安装编译器的回退方案：如果将来的依赖需要本地工具链，用户应使用其发行版的包管理器自行安装。

## Impact

- `install.sh` —— 安装器主体（选项解析与校验、用法/头部文本、`NODE_MAJOR` 默认值与 Node 复用逻辑、构建工具函数及其调用点、最终摘要）以及内嵌的 `dshctl` heredoc（`cmd_upgrade` 参数处理、新的列出路径、目标校验）。内嵌副本仍是唯一来源；`--print-dshctl` 的字节一致性必须保持。
- 行为与兼容性：`--with-build-tools` 不再被接受（破坏性变更）；新安装获得 Node 24；现有安装重新运行的行为不变；没有新增、删除或重命名任何配置键，因此现有的 `~/.config/dsh-service/config` 文件仍然有效。
- `README.md` —— 安装步骤表（删除一个步骤后重新编号）、环境要求、选项参考、dshctl 命令表，以及升级/故障排查章节。
- `tests/run.sh` —— 删除构建工具链断言，新增对 Node 24 默认值、现有 Node 保留路径、`upgrade --list` 和无效版本诊断的覆盖。
- `openspec/config.yaml` —— 项目上下文仍然写着 “nvm + Node 22”，并称 `--with-build-tools` 是两条 `sudo` 路径之一；这两处表述都必须修正。
