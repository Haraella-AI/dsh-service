# installation Specification

## Purpose

定义 `install.sh` —— 一个单文件、可重复运行的 Bash 安装器 —— 必须在 Linux 主机上提供什么：一个
运行 DeepSeek Harness Web GUI（`dsh web`）的用户级 systemd 服务。安装器负责整条软件链（nvm、
Node、`@deepseek-ai/dsh`、可选的 pnpm）、用户级入口点、shell `rc` 代码块、共享配置以及 systemd
单元，并在结束时报告登录 URL。幂等性是核心契约：重复运行安装器必须是安全的，并且必须保留它未
显式修改的取值和文件。

## Requirements

### Requirement: CLI 选项契约与校验

`install.sh` SHALL 接受已文档化的选项 —— `--port N`、`--name NAME`、`--node-major N`、
`--nvm-version V`、`--dsh-version V`、`--pnpm-version V`、`--prefix DIR`、`--mirror`、`--no-mirror`、
`--no-pnpm`、`--no-service`、`--no-linger`、`--no-rc`、`--no-completion`、`--force`、`--strict-port`、
`--dry-run`、`--allow-root`、`--print-dshctl` 以及 `-h|--help` —— 并且同时支持 `--option value` 和
`--option=value` 两种形式，默认值为 `--port 3080`、`--name dsh`、`--node-major 24`、
`--nvm-version v0.40.1`、dsh 为 `next`、pnpm 为 `latest`、前缀为 `$HOME/.local/bin`，并启用镜像模式。
对于未知选项、非数字或不在 1-65535 范围内的端口、超出 `A-Za-z0-9_.@-` 的单元名，以及非绝对路径的
前缀，它 SHALL 输出错误信息并退出 1。`--help` 和 `--print-dshctl` SHALL 在任何安装步骤之前打印其输出
并退出 0。

`--no-completion` SHALL 只跳过补全脚本的安装，不改变 `~/.bashrc` 代码块的其它内容；`--no-rc` SHALL
只管辖 `~/.bashrc`，不阻止补全脚本落盘。两者 SHALL 互相独立，且都 SHALL 被 `--help` 文本记录。

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

#### Scenario: 补全退订与 rc 关停互相独立

- **WHEN** 安装器分别以 `--no-completion` 和 `--no-rc` 运行
- **THEN** `--no-completion` 运行不创建补全脚本文件，且 `~/.bashrc` 代码块不新增补全 source 行
- **AND** `--no-rc` 运行仍创建补全脚本文件，且不修改 `~/.bashrc`

### Requirement: 拒绝 root 权限

当有效用户为 `root` 且未提供 `--allow-root` 时，`install.sh` SHALL 拒绝运行并在执行任何安装步骤
之前退出 1，因为该服务是用户级单元。

#### Scenario: 以 root 运行且未带该标志

- **WHEN** 安装器以 root 身份运行且未提供 `--allow-root`
- **THEN** 它报告脚本不得以 root 身份运行并退出 1
- **AND** 不执行任何安装步骤

#### Scenario: 以 root 运行且带上该标志

- **WHEN** 安装器以 root 身份运行并提供了 `--allow-root`
- **THEN** 它继续执行正常的安装流水线

### Requirement: 试运行透明性

在 `--dry-run` 下，`install.sh` SHALL 打印它将执行的变更操作 —— nvm 脚本下载与执行、Node 安装、
全局 npm 安装、目录创建与符号链接、shell rc 代码块更新，以及 dshctl 的渲染/启用/linger 调用 ——
并且 SHALL NOT 创建、写入、建立符号链接、安装或启用任何内容。试运行 SHALL 仍然以安装摘要结束并
退出 0，且 SHALL NOT 获取登录 URL。

#### Scenario: 试运行安装

- **WHEN** `bash install.sh --dry-run` 在什么都没安装的机器上运行
- **THEN** 每一项本会发生的修改都只被打印出来
- **AND** 不创建或更改任何文件、符号链接、软件包或服务
- **AND** 运行以摘要结束并退出 0

#### Scenario: 组件已存在时的试运行

- **WHEN** nvm、Node、dsh 或 pnpm 已经安装
- **THEN** 既有状态检测仍会检查系统
- **AND** 不执行任何安装或写入命令

### Requirement: nvm 供给

`install.sh` SHALL 在 `$NVM_DIR/nvm.sh` 存在、可读、通过 shell 语法检查并定义了 `nvm` 函数时
复用已有的 nvm 安装。否则它 SHALL 使用 `curl` 或 `wget` 从配置的 URL 下载 nvm 安装脚本，
可选地依据 `DSH_NVM_INSTALL_SHA256` 校验该脚本，执行它，并在之后 nvm 仍无法加载时以退出 1 中止。
当 nvm 目录存在但无法加载时，它 SHALL 警告但继续执行。

#### Scenario: 健康的 nvm 被复用

- **WHEN** `$NVM_DIR/nvm.sh` 能加载并定义了 `nvm`
- **THEN** 安装器报告 nvm 已经安装
- **AND** 它不下载也不执行安装脚本

#### Scenario: 损坏的 nvm 目录

- **WHEN** nvm 目录存在，但 `nvm.sh` 缺失或已损坏
- **THEN** 安装器警告该已有目录无法自动修复并建议将其删除
- **AND** 安装继续执行

#### Scenario: 下载失败

- **WHEN** 没有可用的下载工具，或下载失败，或生成的文件为空
- **THEN** 安装器报告该失败并退出 1

#### Scenario: 校验和不匹配

- **WHEN** 设置了 `DSH_NVM_INSTALL_SHA256` 且它与下载的脚本不匹配
- **THEN** 安装器以退出 1 中止，并且不执行该脚本

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

### Requirement: 可选的 pnpm 安装

`install.sh` SHALL 以 `--pnpm-version` 指定的版本或 dist-tag（默认 `latest`）全局安装 `pnpm`，
除非提供了 `--no-pnpm`；当已安装版本已经匹配时 SHALL 跳过安装。pnpm 安装的任何失败或 pnpm 二进制
文件仍然缺失 SHALL 只产生警告，且 SHALL NOT 中止安装，安装过程 SHALL 在其摘要中报告 pnpm 未安装。

#### Scenario: pnpm 安装失败

- **WHEN** 全局 pnpm 安装失败或 pnpm 仍然不可用
- **THEN** 安装器发出警告并继续执行服务相关步骤
- **AND** 摘要报告 pnpm 未被安装

#### Scenario: pnpm 被跳过

- **WHEN** 提供了 `--no-pnpm`
- **THEN** 不会为 pnpm 发起任何 npm 调用
- **AND** 摘要报告 pnpm 已被跳过

### Requirement: 用户级入口点

`install.sh` SHALL 创建本地二进制目录（默认 `$HOME/.local/bin`），在其中创建或刷新指向全局安装的
dsh 二进制文件的 `dsh` 符号链接，并在该目录安装具有可执行权限的 `dshctl`。重复运行 SHALL 重新
指向该符号链接，并 SHALL 在 `dshctl` 内容已经相同时保持其不变。当全局 dsh 二进制文件不存在或
不可执行时，安装器 SHALL 退出 1。

#### Scenario: 使用相同前缀重复运行

- **WHEN** 入口点已经存在且是最新的
- **THEN** `dsh` 符号链接被刷新
- **AND** `dshctl` 被报告为未更改，而不是被重写

#### Scenario: 全局 dsh 二进制文件缺失

- **WHEN** 全局 dsh 二进制文件找不到或不可执行
- **THEN** 安装器报告该问题并退出 1

#### Scenario: 前缀包含空白字符

- **WHEN** 配置的前缀包含空格或制表符
- **THEN** 安装器对此发出警告并继续

### Requirement: Shell rc 代码块管理

除非提供了 `--no-rc`，`install.sh` SHALL 在用户的 `~/.bashrc` 中维护一个由标记界定的代码块
（从 `# >>> dsh-service >>>` 到 `# <<< dsh-service <<<`），并跟随符号链接指向真实文件。仅当文件
其余部分尚未这样做时，该代码块 SHALL 导出 `NVM_DIR` 并 source nvm，且 SHALL 在 `PATH` 上导出本地
二进制目录。除非提供了 `--no-completion`，该代码块 SHALL 还包含一行以 `[ -r <补全脚本> ]` 为守卫的
source 语句，使用户 shell 无需安装 `bash-completion` 软件包即可加载补全。已存在的代码块 SHALL 被
替换而不是被重复添加，并且当生成的内容匹配时，文件 SHALL 保持逐字节一致。当起始标记存在而缺少
结束标记时，安装器 SHALL 警告并保持文件不变。

#### Scenario: 首次运行

- **WHEN** `~/.bashrc` 不包含 dsh-service 标记
- **THEN** 该代码块被追加

#### Scenario: 配置值发生变化

- **WHEN** 前缀在两次运行之间发生变化
- **THEN** 已存在的代码块被替换为导出新 `PATH` 值的代码块

#### Scenario: 未终止的代码块

- **WHEN** 起始标记存在，但缺少结束标记
- **THEN** 安装器警告缺少结束标记，保持文件不变，并继续安装

#### Scenario: rc 更新被禁用

- **WHEN** 提供了 `--no-rc`
- **THEN** 安装器不修改 `~/.bashrc`

#### Scenario: 补全 source 行

- **WHEN** 安装器在未带 `--no-completion` 的情况下完成安装
- **THEN** `~/.bashrc` 的 dsh-service 代码块包含一行以 `[ -r` 开头的守卫语句，指向补全脚本文件

### Requirement: 补全脚本供给

除非提供了 `--no-completion`，`install.sh` SHALL 在用户数据目录安装 bash 补全脚本
`${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/dshctl`，其内容 SHALL 等于
`dshctl completion bash` 的标准输出。当目标文件已经存在且内容相同时，安装器 SHALL 报告该文件未变化
并保持其逐字节一致，而不是重写。当 `--dry-run` 生效时，安装器 SHALL 只报告将写入的路径而不创建文件。

#### Scenario: 全新安装写入补全脚本

- **WHEN** 安装器在全新的 home 中运行
- **THEN** 补全脚本文件存在，且其内容等于安装后的 dshctl 执行 `completion bash` 的输出

#### Scenario: 重跑不重写相同内容

- **WHEN** 安装器以相同选项运行两次
- **THEN** 补全脚本文件的哈希值保持不变
- **AND** 第二次运行报告该文件未变化

#### Scenario: 试运行不写文件

- **WHEN** 安装器以 `--dry-run` 运行
- **THEN** 它报告将要写入的补全脚本路径
- **AND** 该文件未被创建

### Requirement: 服务供给与旧单元退役

`install.sh` SHALL 通过已安装的 `dshctl` 渲染共享配置和 systemd 单元，传入单元名、端口、
`DSH_HOME`、nvm 目录、Node 二进制目录、本地二进制目录、额外参数以及镜像设置，并在 `dshctl` 缺失时
SHALL 退出 1。单元成功渲染之后，它 SHALL 退役此前配置的、名称与当前 `--name` 不同的单元，即禁用
并移除它。除非提供了 `--no-service`，它 SHALL 启用并启动服务并设置 lingering（除非提供了
`--no-linger`），并且当服务处于活动状态时 SHALL 打印登录 URL。

#### Scenario: 单元名在两次运行之间发生变化

- **WHEN** 保存的配置使用了一个单元名，而安装器以不同的 `--name` 运行
- **THEN** 先渲染新单元
- **AND** 随后禁用旧单元并移除其单元文件和备份文件

#### Scenario: 服务启动失败

- **WHEN** 启用服务失败
- **THEN** 安装器仍然打印安装摘要
- **AND** 报告该失败，告知用户运行 `dshctl enable`，并退出 1

#### Scenario: 登录 URL

- **WHEN** 服务已被启用且在试运行模式之外处于活动状态
- **THEN** 安装器等待并打印登录 URL
- **AND** 当无法获取该 URL 时回退为一条提示

#### Scenario: 服务步骤被跳过

- **WHEN** 提供了 `--no-service`
- **THEN** 启用和 linger 步骤都不会运行
- **AND** 安装器退出 0 并给出运行 `dshctl enable` 的提示

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
