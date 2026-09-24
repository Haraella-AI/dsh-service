# Proposal

## Why

安装器与 `dshctl upgrade` 默认都跟随 npm 的 `latest` 通道，但 `@deepseek-ai/dsh` 的实际最新构建并不
在 `latest` 上：registry 当前 `latest = 0.1.5-rc.3`、`next = 0.1.7-rc.1`、`alpha = 0.1.7-alpha.2`。
由于 dsh 本身以 rc 版本对外发布，`next` 才是「最新可用构建」的通道，默认跟随 `latest` 会让每台新装
机器一开始就落后一个通道，用户还得自己知道 `--dsh-version next` 才能装到真正的最新版。

## What Changes

- 引入统一的「默认通道」概念：`next`。它是 `install.sh` 与内嵌 `dshctl` 中版本默认值的唯一来源。
- `install.sh`：`--dsh-version` 的默认值从 `latest` 改为 `next`；`--help` 用法文本与 README 同步。
- `install.sh` 新增「保留已有安装」规则（与 Node 24 的保留规则同构）：未提供 `--dsh-version`、未提供
  `--force` 且检测到已安装 dsh 时，安装器**保留**现有版本——不执行 npm 安装、不切换通道，并报告保留
  的版本以及切换到默认通道的方式。只有检测不到任何已安装 dsh 时，它才安装默认通道（`next`）的版本。
  显式 `--dsh-version` 与 `--force` 行为不变，仍按请求的目标安装。
- 泛化 dist-tag 解析：`install.sh` 的 `ensure_dsh` 与 `dshctl` 的 `resolve_target` 不再只对字面量
  `latest` 走 registry 查询，而是查询 `dist-tags` 得到**任意** dist-tag（`latest`/`next`/`alpha`）对应的
  具体版本，用于幂等比较；具体版本号仍原样使用、不查询网络。registry 不可达时保持现有的降级行为。
- `dshctl upgrade`：省略目标时的默认从 `latest` 改为 `next`；显式 `dshctl upgrade latest`、显式版本与
  其他 dist-tag 不受影响。装前校验只在用户显式给出目标时进行（保持现有语义），默认通道由 registry
  解析结果直接使用。
- `dshctl upgrade-node`：切换 Node 后为重装 dsh 选择目标时，同样使用默认通道 `next`，与其他入口保持
  一致的通道语义。
- 版本未找到提示改为报告「默认通道 `next` 的当前版本」，其余字段（`--list` 命令、安装默认通道版本的
  命令）保持可用。
- 更新 README（安装步骤表、选项参考、升级与排障章节）与内嵌 `dshctl` 的用法文本。

## Capabilities

### New Capabilities

无——未引入新能力，改动都落在既有安装与维护契约上。

### Modified Capabilities

- `installation`：`dsh` 的默认安装通道从 `latest` 改为 `next`，并新增「未显式指定时保留已有安装」的
  契约；CLI 选项契约中 dsh 的默认值随之更新（pnpm 仍为 `latest`）。
- `maintenance`：升级版本解析的默认目标改为 `next`，并把 dist-tag 解析从 `latest` 泛化到 `dist-tags`
  中的任意 tag；`upgrade-node` 重装 dsh 时以默认通道为目标。
- `offline-tests`：验证契约更新为覆盖默认通道安装、已有安装的保留路径、任意 dist-tag 的幂等解析，以及
  `dshctl upgrade` / `upgrade-node` 的默认通道目标。

## Non-goals

- **不新增配置键或环境变量**（例如 `DSH_SERVICE_DSH_CHANNEL`）：默认通道是脚本内的常量，切换通道用
  `--dsh-version next|latest|alpha|<版本>`（安装）或 `dshctl upgrade <spec>`（维护），因此现有
  `~/.config/dsh-service/config` 文件与导入/导出格式都不受影响。
- **不自动迁移已有安装**：重跑安装器不会把现有 dsh 升到 `next`，也不会改写已记录的版本；迁移始终是用户
  的显式动作（`--dsh-version next` 或 `dshctl upgrade`）。
- 不改变 pnpm 的默认值（仍为 `latest`）与 pnpm 的失败只告警语义。
- 不改变 `dshctl upgrade` 的失败隔离、安装后校验与自动回滚语义，也不改变 `upgrade --list` 的输出格式
  （它已经标记 dist-tag）。
- 不引入通道自动探测、stable/beta 通道选择界面或多通道并存安装。
- 不改变 `--dsh-version` 与 `--pnpm-version` 的字符集校验规则，也不改变 npm 安装失败即退出 1 的契约。

## Impact

- `install.sh`：
  - 安装器主体——默认值常量（`next`）、`--help`/头部用法文本、`ensure_dsh`（保留规则 + dist-tag 解析）、
    dry-run 打印内容。
  - 内嵌 `dshctl` heredoc——`cmd_upgrade`（默认 `spec`、显式性判定）、`resolve_target`（dist-tag 泛化）、
    `upgrade_latest_version` 与 `upgrade_target_not_found_hint` 的措辞、`cmd_upgrade_node` 的重装目标、
    用法文本。内嵌副本仍是唯一来源，`--print-dshctl` 的字节一致性必须保持。
- 行为与兼容性：
  - **重跑幂等**：已有安装重跑 `install.sh`（不带 `--dsh-version`）现在会保留现有版本，而不是跟随默认
    通道升级；这与 Node 默认值的保留规则一致，也是本次唯一会改变既有机器行为的点。未提供
    `--dsh-version` 的**新装**才会落到 `next`。
  - `dshctl upgrade`（无参）与 `dshctl upgrade-node` 现在指向 `next`；显式目标路径不变。
  - 未新增、删除或重命名配置键，因此既有配置文件继续有效。
- `README.md`：安装步骤表（第 3 步的 `npm install -g @deepseek-ai/dsh@latest` 改为默认通道 `next`）、
  `install.sh` 选项参考、升级与回滚章节、故障排查中的示例命令。
- `tests/run.sh`：dry-run 与默认安装断言、幂等分节（`默认 latest 安装幂等`）、`upgrade --check` 与
  `upgrade` 相关分节、`upgrade-node` 分节，以及 npm 桩对 `next` 目标的版本回写。
- `openspec/config.yaml`：项目上下文未描述 dsh 版本默认值，因此无需改动。
- **归档顺序依赖**：本变更的 delta 规格以已实现但尚未归档的 `simplify-toolchain-and-upgrade-ux`（Node 24、
  无构建工具链）为基线编写。归档时该变更必须先归档（或两者一并归档），否则它对该组需求的整体替换会覆盖
  本次的默认通道改动。
