# Spec Delta

## MODIFIED Requirements

### Requirement: CLI 选项契约与校验

`install.sh` SHALL 接受已文档化的选项 —— `--port N`、`--name NAME`、`--node-major N`、
`--nvm-version V`、`--dsh-version V`、`--pnpm-version V`、`--prefix DIR`、`--mirror`、`--no-mirror`、
`--no-pnpm`、`--no-service`、`--no-linger`、`--no-rc`、`--force`、`--strict-port`、`--dry-run`、
`--allow-root`、`--print-dshctl` 以及 `-h|--help` —— 并且同时支持 `--option value` 和
`--option=value` 两种形式，默认值为 `--port 3080`、`--name dsh`、`--node-major 24`、
`--nvm-version v0.40.1`、dsh 为 `next`、pnpm 为 `latest`、前缀为 `$HOME/.local/bin`，并启用镜像模式。
对于未知选项、非数字或不在 1-65535 范围内的端口、超出 `A-Za-z0-9_.@-` 的单元名，以及非绝对路径的
前缀，它 SHALL 输出错误信息并退出 1。`--help` 和 `--print-dshctl` SHALL 在任何安装步骤之前打印其输出
并退出 0。

#### Scenario: 未知选项

- **WHEN** 安装器被以无法识别的参数调用
- **THEN** 它向标准错误打印指明该参数的错误信息
- **AND** 退出 1 且不执行任何安装步骤

#### Scenario: 已移除的构建工具链选项

- **WHEN** 安装器被以 `--with-build-tools` 调用
- **THEN** 它将该参数报告为未知并在任何安装步骤之前退出 1
- **AND** 它不尝试安装或检查任何系统软件包

#### Scenario: 带前导零的端口

- **WHEN** 传入 `--port 080`
- **THEN** 该值被解释为十进制 80
- **AND** 非数字、为零或大于 65535 的端口会退出 1

#### Scenario: 无效的单元名或前缀

- **WHEN** `--name` 包含 `A-Za-z0-9_.@-` 之外的字符，或 `--prefix` 不是绝对路径
- **THEN** 安装器退出 1 并给出指明该无效值的消息

#### Scenario: 提前退出选项

- **WHEN** 传入 `--help` 或 `--print-dshctl`
- **THEN** 打印用法文本或内嵌的 dshctl 源码
- **AND** 脚本退出 0 且不触碰系统

#### Scenario: 用法文本记录默认通道

- **WHEN** 运行 `install.sh --help`
- **THEN** 用法文本把 `next` 记为 `--dsh-version` 的默认值，并仍把 `latest` 记为 `--pnpm-version` 的默认值

### Requirement: dsh 包安装与版本幂等性

`install.sh` SHALL 默认以 `next` 通道全局安装 `@deepseek-ai/dsh`，并 SHALL 接受 `--dsh-version` 指定的
具体版本或任意 dist-tag。当未提供 `--dsh-version` 且未提供 `--force` 时：若检测不到已安装的 dsh，它
SHALL 安装默认通道（`next`）的版本；若检测到已安装的 dsh，它 SHALL 保留该已安装版本、不发起任何 npm
安装，并 SHALL 报告所保留的版本以及切换到默认通道的方式（`--dsh-version next` 或 `dshctl upgrade`）。
当提供了 `--dsh-version` 时，它 SHALL 以该版本或 dist-tag 为目标；当目标是 registry 上的 dist-tag
（包括 `next` 与 `latest`）时，它 SHALL 通过查询 registry 的 `dist-tags` 解析出该 tag 指向的具体版本，
仅用于判断是否需要安装，并在 registry 不可达时回退到字面标签并给出警告。当已安装版本已等于解析出的
目标版本时，它 SHALL 跳过安装，除非提供了 `--force`。提供 `--force` 时 SHALL 执行全局 npm 安装，未提供
`--dsh-version` 时目标为默认通道。npm 安装失败 SHALL 退出 1。

#### Scenario: 新安装使用默认通道

- **WHEN** 机器上没有已安装的 dsh，且安装器运行时未提供 `--dsh-version`
- **THEN** 它以 `next` 为安装目标
- **AND** 试运行打印的安装动作是 `npm install -g @deepseek-ai/dsh@next`

#### Scenario: 已有安装保留其版本

- **WHEN** 已安装 dsh 0.1.0，默认通道 `next` 指向更新的 0.1.7-rc.1，且安装器重跑时未提供 `--dsh-version`
- **THEN** 不发起任何 npm 安装，已安装的 0.1.0 保持不变
- **AND** 安装器报告所保留的 0.1.0，并指明用 `--dsh-version next` 或 `dshctl upgrade` 切换通道

#### Scenario: 显式切换到默认通道

- **WHEN** 已安装 dsh 0.1.0，且安装器以 `--dsh-version next` 运行
- **THEN** 它安装 registry 上 `next` 指向的版本
- **AND** 汇总报告安装后的实际版本

#### Scenario: 目标版本已安装

- **WHEN** 已安装的 dsh 版本等于解析出的目标版本（包括显式 dist-tag 解析出的版本），且未提供 `--force`
- **THEN** 安装器报告 dsh 已经安装并跳过 npm
- **AND** 运行继续执行其余步骤

#### Scenario: 强制重装

- **WHEN** 提供了 `--force`
- **THEN** 即使版本已经匹配也会运行全局 npm 安装
- **AND** 未提供 `--dsh-version` 时安装目标是默认通道 `next`

#### Scenario: dist-tag 无法解析

- **WHEN** 显式给出的目标是 dist-tag，但 registry 查询没有返回结果
- **THEN** 安装器对该解析失败发出警告
- **AND** 它仍然直接安装该字面 dist-tag

#### Scenario: 安装失败

- **WHEN** 全局 npm 安装以非零状态退出
- **THEN** 安装器报告失败的命令并退出 1

### Requirement: 幂等重跑与配置保留

重复运行 `install.sh` SHALL 是安全的：已完成的步骤 SHALL 被检测到并跳过，由安装器自身活动单元占用
的端口 SHALL NOT 被视为冲突，且当前运行未覆盖的配置值 SHALL 在重新渲染后保留。运行期间创建的
临时文件 SHALL 在每一条退出路径上被移除，包括失败和中断。

#### Scenario: 无变化的第二次运行

- **WHEN** 安装器以完全相同的选项重复运行
- **THEN** nvm 和 Node 被复用，dsh 版本被跳过，且配置、单元、rc 代码块和 `dshctl` 被报告为未更改
- **AND** 服务被重新启用，运行退出 0

#### Scenario: 重跑保留已安装的 Node 版本

- **WHEN** 已有安装运行在比当前默认值更旧的 Node 主版本上，且安装器在未提供 `--node-major` 的情况下
  被重复运行
- **THEN** 已安装的 Node 版本被保留，且不供给更新的主版本
- **AND** 单元、配置和 `dshctl` 保持未更改

#### Scenario: 重跑保留已安装的 dsh 版本

- **WHEN** 已安装的 dsh 版本不是默认通道 `next` 当前指向的版本，且安装器在未提供 `--dsh-version` 的
  情况下被重复运行
- **THEN** 已安装的 dsh 版本被保留，且不发起 npm 安装
- **AND** 安装器报告该版本及切换通道的方式

#### Scenario: 保留用户编辑过的值

- **WHEN** 用户编辑了某个配置值（例如额外的 `dsh web` 参数），并在未覆盖它的情况下重复运行
- **THEN** 该编辑过的值被读取并重新渲染，而不是被重置为其默认值

#### Scenario: 被中断的运行

- **WHEN** 安装器提前退出或被中断
- **THEN** 它注册的临时文件被移除
