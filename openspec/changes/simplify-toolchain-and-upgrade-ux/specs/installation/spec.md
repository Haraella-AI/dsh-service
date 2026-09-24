# Spec Delta

## MODIFIED Requirements

### Requirement: CLI 选项契约与校验

`install.sh` SHALL 接受已文档化的选项 —— `--port N`、`--name NAME`、`--node-major N`、
`--nvm-version V`、`--dsh-version V`、`--pnpm-version V`、`--prefix DIR`、`--mirror`、`--no-mirror`、
`--no-pnpm`、`--no-service`、`--no-linger`、`--no-rc`、`--force`、`--strict-port`、`--dry-run`、
`--allow-root`、`--print-dshctl` 以及 `-h|--help` —— 并且同时支持 `--option value` 和
`--option=value` 两种形式，默认值为 `--port 3080`、`--name dsh`、`--node-major 24`、
`--nvm-version v0.40.1`、dsh 和 pnpm 为 `latest`、前缀为 `$HOME/.local/bin`，并启用镜像模式。对于
未知选项、非数字或不在 1-65535 范围内的端口、超出 `A-Za-z0-9_.@-` 的单元名，以及非绝对路径的前缀，
它 SHALL 输出错误信息并退出 1。`--help` 和 `--print-dshctl` SHALL 在任何安装步骤之前打印其输出并
退出 0。

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

### Requirement: Node 供给、复用与重试

`install.sh` SHALL 对新安装默认使用 Node 主版本 24，并 SHALL 在其用法文本中报告该默认值。它 SHALL
复用 `$NVM_DIR/versions/node` 下与所请求主版本匹配的已安装 Node 版本，选择补丁版本最高的那个，并在
不访问网络的情况下将其设为 nvm 默认版本。当不存在匹配版本时，它 SHALL 通过 nvm 安装所请求的主版本，
最多重试 `DSH_SERVICE_NODE_ATTEMPTS` 次（默认 3），每次间隔 `DSH_SERVICE_NODE_RETRY_DELAY` 秒
（默认 5），并在每次尝试都失败时给出补救提示并退出 1。安装成功之后，它 SHALL 校验 Node 二进制文件
存在且与所请求的主版本匹配。当未提供 `--node-major` 且服务配置已经记录了包含可执行 `node` 的可用
Node 二进制目录时，安装器 SHALL 在这次运行中保留该已有的 Node 版本而不是使用默认值，并 SHALL 告知
用户保留了哪个版本以及如何切换主版本。

#### Scenario: 新安装的默认主版本

- **WHEN** 安装器运行时未提供 `--node-major`，且没有记录在案的可用 Node 二进制目录
- **THEN** 所请求的主版本为 24
- **AND** 用法文本将 24 记录为默认值

#### Scenario: 已有安装保留其 Node 版本

- **WHEN** 配置记录了一个 Node 二进制目录，其 `node` 可执行，且未提供 `--node-major`
- **THEN** 这次运行使用该 Node 版本，且不下载其他主版本
- **AND** 安装器报告所保留的版本，并指出用 `--node-major` 或 `dshctl upgrade-node` 进行切换

#### Scenario: 记录的 Node 已不再可用

- **WHEN** 记录的 Node 二进制目录缺失或其 `node` 不可执行，且未提供 `--node-major`
- **THEN** 安装器供给默认主版本 24

#### Scenario: 显式指定的主版本

- **WHEN** `--node-major` 指定了一个主版本
- **THEN** 该主版本优先于默认值以及任何记录在案的 Node

#### Scenario: 已安装匹配的主版本

- **WHEN** nvm 已经有请求主版本的 Node 版本
- **THEN** 该版本被复用并被设为 nvm 默认版本
- **AND** 不尝试任何网络下载

#### Scenario: 瞬时下载失败

- **WHEN** 一次安装尝试失败，但稍后的尝试成功
- **THEN** 安装器对每次失败的尝试发出警告并继续

#### Scenario: 持续下载失败

- **WHEN** 所有尝试都失败
- **THEN** 安装器打印网络、镜像和手动安装提示并退出 1
- **AND** 其余安装步骤被跳过

#### Scenario: 无效的重试设置

- **WHEN** `DSH_SERVICE_NODE_ATTEMPTS` 不是正整数，或 `DSH_SERVICE_NODE_RETRY_DELAY` 不是数字
- **THEN** 安装器报告该无效值并退出 1

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

#### Scenario: 保留用户编辑过的值

- **WHEN** 用户编辑了某个配置值（例如额外的 `dsh web` 参数），并在未覆盖它的情况下重复运行
- **THEN** 该编辑过的值被读取并重新渲染，而不是被重置为其默认值

#### Scenario: 被中断的运行

- **WHEN** 安装器提前退出或被中断
- **THEN** 它注册的临时文件被移除

### Requirement: 安装摘要

在一次成功运行结束时，`install.sh` SHALL 打印摘要，报告解析出的 dsh 和 Node 版本、pnpm 状态、
镜像模式、服务地址，以及单元文件、配置文件和 `dshctl` 的路径，随后给出后续步骤。当本地二进制目录
不在当前 `PATH` 上且服务已被应用时，它 SHALL 对此发出警告。

#### Scenario: 安装成功

- **WHEN** 安装器完成
- **THEN** 摘要列出 dsh 和 Node 版本、pnpm 状态、镜像模式、地址以及相关路径
- **AND** 它不报告任何构建工具链状态

#### Scenario: 本地二进制目录不在 PATH 上

- **WHEN** 本地二进制目录不在当前 `PATH` 中且服务已被应用
- **THEN** 安装器警告需要将该目录添加到 `PATH`

## REMOVED Requirements

### Requirement: 可选的构建工具链安装

**Reason**: dsh 的每个依赖都以预构建形式发布，因此安装器从不需要本地编译器。这个可选步骤引入了
按发行版分支的包管理器逻辑（`apt-get`/`dnf`/`yum`）以及一条未经测试、依赖平台且与安装器职责无关
的 `sudo` 路径。

**Migration**: `--with-build-tools` 标志和工具链步骤已被移除；现在传入该标志会得到未知选项错误。
需要编译器的用户可在重新运行 `install.sh` 之前，使用其发行版的包管理器自行安装
（`sudo apt-get install build-essential`，或 `sudo dnf install gcc gcc-c++ make`）。一条说明此事的
提示取代了被移除的文档。
