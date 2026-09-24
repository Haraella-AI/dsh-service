# offline-tests Specification

## Purpose

定义本仓库的验证契约：`tests/run.sh` 是一个单文件、完全离线的验收测试套件，端到端地检验
`install.sh` 及其内嵌的 `dshctl`。它构造一个一次性的沙箱，配有桩系统工具和用完即弃的 home
目录，因此该套件不需要网络、不需要 systemd、也不需要 root，并固定安装器对外可观察的行为——
包括幂等性、端口处理、升级回滚、插件重置、导出/导入以及注入加固。对安装器的修改应当伴随此处
的覆盖。

## Requirements

### Requirement: 确定性的调用与判定

该套件 SHALL 可在无参数的情况下以 `bash tests/run.sh` 运行。它 SHALL 在带标题的分节下为每条断言
打印一行结果，打印通过和失败断言数的最终统计，并在至少一条断言失败时退出码为 1、全部通过时
退出码为 0。

#### Scenario: 所有断言通过

- **WHEN** 该套件无失败地运行至完成
- **THEN** 最终摘要报告通过的数量
- **AND** 该套件以 0 退出

#### Scenario: 一条断言失败

- **WHEN** 至少一条断言失败
- **THEN** 最终摘要报告非零的失败数量
- **AND** 该套件以 1 退出

#### Scenario: 无参数调用

- **WHEN** 该套件以 `bash tests/run.sh` 调用
- **THEN** 它无需参数解析即运行完整套件

### Requirement: 密闭沙箱与桩注入

每次运行 SHALL 在仓库被忽略的 `.tmp` 目录树下重建一个一次性工作目录，将桩可执行文件放置其中并
把它们前置到 `PATH`，同时为每个用例隔离出全新的临时 home 目录，并预置安装器所期望的文件。任何
网络访问、systemd 实例、root 权限或真实用户配置都 SHALL NOT 被要求或触碰。

#### Scenario: 沙箱被重建

- **WHEN** 该套件启动
- **THEN** 工作目录被删除并重建，其中包含桩二进制目录和
  模拟的全局 npm 目录树

#### Scenario: 桩遮蔽真实工具

- **WHEN** 安装器或 `dshctl` 调用 `systemctl`、`journalctl`、`loginctl`、`sudo`、`ss`、
  `node` 或 `npm`
- **THEN** 前置 `PATH` 上的桩被执行，而非真实工具

#### Scenario: 每个用例的 home 隔离

- **WHEN** 某个用例运行
- **THEN** 它使用一个临时 home 目录，其中包含 `nvm.sh`、`.bashrc`、配置
  目录以及本地二进制目录

### Requirement: 桩的保真度与控制开关

这些桩 SHALL 模拟脚本所依赖的可观察行为——单元状态、日志可读性、linger 状态、端口列表、npm 版本
查询与全局安装，以及 nvm 安装——并 SHALL 可通过导出的变量进行操控，以便确定性地覆盖成功、失败、
重试和降级路径。调用 SHALL 被记录，使断言能够验证实际运行过的命令。

#### Scenario: 模拟端口被占用

- **WHEN** 端口列表桩被配置为报告一个监听者
- **THEN** 安装器和 `dshctl` 将该端口视为已占用

#### Scenario: 模拟服务崩溃

- **WHEN** 单元状态桩报告服务为 failed
- **THEN** 安装器检测到该服务未能变为 active

#### Scenario: 模拟受限的日志访问

- **WHEN** 日志桩拒绝用户日志访问
- **THEN** 用户日志查询失败，而 sudo 回退仍能给出登录 URL

#### Scenario: 脚本化安装失败

- **WHEN** npm 或 nvm 桩被配置为失败、空操作或失败若干次尝试
- **THEN** 安装器的失败、跳过和重试路径被确定性地覆盖

### Requirement: 全新安装覆盖

该套件 SHALL 断言完整的全新安装契约：退出状态、安装后的 `dshctl` 与 dsh 入口点、配置与单元文件、
shell rc 代码块、已启用并已启动的服务、打印出的登录 URL、单元文件内容、默认 Node 主版本、默认安装
通道、pnpm 处理以及镜像选择。

#### Scenario: 从空 home 完整安装

- **WHEN** 安装器在全新的临时 home 中运行
- **THEN** 它以 0 退出，报告服务已启用并已启动，并打印带令牌的登录 URL

#### Scenario: 单元文件内容

- **WHEN** 安装完成
- **THEN** 单元使用 `Type=exec`、带环回主机与所配置端口的预期可执行行、
  `Restart=on-failure` 以及 `WantedBy=default.target`
- **AND** 它不包含工作目录指令，且其 `PATH` 包含本地二进制目录和
  Node 二进制目录

#### Scenario: 默认 Node 主版本

- **WHEN** 安装器在未带 `--node-major` 的全新 home 中运行
- **THEN** 该套件断言请求的是 Node 24，且用法文本将 24 记录为
  默认值

#### Scenario: 默认安装通道

- **WHEN** 安装器在没有任何已安装 dsh 的 home 中运行，且未提供 `--dsh-version`
- **THEN** 该套件断言全局安装的目标是 `@deepseek-ai/dsh@next`
- **AND** 该次运行报告安装后的实际版本

#### Scenario: pnpm 处理

- **WHEN** pnpm 被安装、通过 `--no-pnpm` 跳过，或安装失败
- **THEN** 该套件断言相应的成功、跳过和仅告警行为

#### Scenario: 镜像选择

- **WHEN** 安装器以默认镜像模式或带 `--no-mirror` 运行
- **THEN** 该套件断言预期的源 URL 和已持久化的镜像配置

### Requirement: 幂等重跑覆盖

该套件 SHALL 断言第二次完全相同的安装会让单元文件、rc 代码块和 `dshctl` 保持逐字节一致，只保留
一个 rc 代码块，在未给出 `--port` 时保留用户编辑过的端口，保留早于当前默认值的已安装 Node 版本，
在未显式指定版本时保留已安装的 dsh，并在已安装版本与目标版本匹配时跳过 npm 安装，包括通过 dist-tag
解析出的目标以及带 `v` 前缀的目标匹配裸版本号的情况。

#### Scenario: 第二次相同的运行

- **WHEN** 安装器以相同选项运行两次
- **THEN** 单元文件、rc 代码块和 `dshctl` 的哈希值保持不变
- **AND** 该次运行报告配置已存在

#### Scenario: 已安装的 Node 版本被保留

- **WHEN** 配置为较旧的主版本记录了可用的 Node 二进制目录，且
  安装器在未带 `--node-major` 的情况下重跑
- **THEN** 不下载任何其他 Node 主版本，且单元文件保留所记录的 Node 二进制
  目录
- **AND** 该次运行报告保留了哪个 Node 版本

#### Scenario: 重跑保留已安装的 dsh

- **WHEN** 已安装的 dsh 版本与默认通道指向的版本不同，且安装器在未提供
  `--dsh-version` 的情况下重跑
- **THEN** 不记录任何 `npm install @deepseek-ai/dsh` 调用
- **AND** 该次运行报告保留了已安装的版本

#### Scenario: 用户编辑过的端口

- **WHEN** 配置被编辑为另一个端口，且安装器在未带
  `--port` 的情况下重跑
- **THEN** 单元文件保留编辑后的端口
- **AND** 传入 `--port` 会在单元文件和配置中同时覆盖它

#### Scenario: 版本无操作

- **WHEN** 已安装的 dsh 版本等于所请求的目标版本，包括通过 dist-tag 解析出的
  目标以及带 `v` 前缀的写法
- **THEN** 不执行全局安装，且该次运行报告该版本已安装

### Requirement: 端口预检覆盖

该套件 SHALL 断言：除非给出 `--strict-port`，被占用的端口会导致自动前进到下一个空闲端口；本服务
自身的端口不会被当作冲突；端口匹配是精确的；并且带前导零的端口会按十进制规范化。

#### Scenario: 端口被占用

- **WHEN** 所请求的端口被报告为遭外部监听者占用
- **THEN** 安装器采用下一个端口，且单元文件、配置和报告的地址都
  使用它

#### Scenario: 严格端口模式

- **WHEN** 给出 `--strict-port` 且该端口被占用
- **THEN** 安装器以非零退出，且不写入单元文件

#### Scenario: 精确端口匹配

- **WHEN** 某个监听者使用的端口仅与所配置端口共享前缀
- **THEN** 所配置端口被报告为未在监听

#### Scenario: 前导零端口

- **WHEN** 安装器收到一个带前导零写法的端口
- **THEN** 该值被按十进制处理，且预检从该数字开始前进

### Requirement: 升级与回滚覆盖

该套件 SHALL 断言升级后的版本校验、校验失败时自动回滚到上一个版本、仅检查模式、对带 `v` 前缀
目标版本的处理、可用版本的列表、对不存在目标的拒绝、省略目标时的默认通道，以及 registry dist-tag
的解析。

#### Scenario: 损坏的升级

- **WHEN** 一次升级安装的版本与目标不匹配
- **THEN** 该命令报告校验失败，重新安装上一个版本，并以
  非零退出

#### Scenario: 检查模式

- **WHEN** 在有更新版本可用时运行 `upgrade --check`
- **THEN** 该命令报告可用的版本迁移而不执行安装

#### Scenario: 带 v 前缀的目标

- **WHEN** 升级的目标是带 `v` 前缀的版本
- **THEN** 该命令成功完成，不报告校验失败或回滚

#### Scenario: 版本列表

- **WHEN** 运行 `upgrade --list`，可选地带一个数量
- **THEN** 该套件断言可用版本按从新到旧打印并标记带标签的版本，
  该数量会限制输出，且该命令以 0 退出而不安装或
  触碰服务

#### Scenario: 不存在的版本

- **WHEN** 升级请求一个 registry 未发布的版本
- **THEN** 该命令在安装前以非零退出，并指向版本列表命令
  和默认通道的当前版本
- **AND** 不尝试任何软件包安装

#### Scenario: 安装失败并给出未找到版本的诊断

- **WHEN** 软件包安装失败并给出无匹配版本的诊断
- **THEN** 该命令报告失败而不回滚，并打印未找到版本的提示

#### Scenario: 省略目标时使用默认通道

- **WHEN** 不带目标运行 `dshctl upgrade`
- **THEN** 该命令以 registry 的 `dist-tags` 中 `next` 指向的版本为目标
- **AND** 它不把 `latest` 指向的版本当作目标

#### Scenario: 显式 dist-tag 被解析为具体版本

- **WHEN** 运行 `dshctl upgrade latest` 或其他 dist-tag
- **THEN** 该命令以该 tag 解析出的具体版本为目标，并在安装后按该版本校验
### Requirement: 服务健康、doctor 与日志回退覆盖

该套件 SHALL 断言：服务未能变为 active 的安装会带指引地失败；`dshctl doctor` 覆盖前端资源、dsh
配置转储、服务状态、稳定入口点以及 `DSH_HOME` 挂载警告；并且当用户日志受限制时，`logs` 和
`url` 会回退到 sudo 日志。

#### Scenario: 服务在启动时崩溃

- **WHEN** 服务在安装期间未能变为 active
- **THEN** 安装器以非零退出，报告服务未正确启动，并指向
  `dshctl logs -n 30`

#### Scenario: 健康安装上的 doctor

- **WHEN** 对健康的安装运行 `dshctl doctor`
- **THEN** 它以 0 退出，并报告前端资源、配置转储检查、正在运行的
  服务以及稳定入口点

#### Scenario: 受限的日志

- **WHEN** 用户日志不可读，但 sudo 回退可用
- **THEN** `dshctl logs` 和 `dshctl url` 仍然成功，且 doctor 不把该日志报告为
  不可读

#### Scenario: doctor 修复

- **WHEN** 在缺少 nvm 目录或单元文件无效的情况下运行 `doctor --fix`
- **THEN** 它报告问题而不崩溃，并且仍然打印其摘要

### Requirement: Node 与 nvm 韧性覆盖

该套件 SHALL 断言：Node 安装会重试至所配置的尝试次数；持续失败会带镜像提示和可读消息报告 Node
下载失败；后续尝试可以成功；已存在的匹配主版本会被复用而无需下载；并且 nvm 调用绝不会触发
未绑定变量失败。

#### Scenario: 持续下载失败

- **WHEN** 每一次 Node 安装尝试都失败
- **THEN** 安装器以 1 退出，带镜像提示报告下载失败，并恰好尝试了
  所配置的次数

#### Scenario: 瞬时失败

- **WHEN** 第一次尝试失败而后续尝试成功
- **THEN** 安装器成功完成，并记录预期的尝试次数

#### Scenario: 已存在的匹配主版本

- **WHEN** nvm 下已安装匹配的 Node 主版本
- **THEN** 不发生下载，且 Node 二进制目录指向该已存在版本

#### Scenario: 严格模式下的未设置变量

- **WHEN** 某个桩或环境使某个变量未设置
- **THEN** 安装器仍能完成，且不报告未绑定变量

### Requirement: 插件重置覆盖

该套件 SHALL 断言：`plugins reset` 在非交互环境中要求确认；除非给出 `--no-restart`，否则停止并
重启服务；备份 profile 清单；从清单和 bundle 列表中移除插件依赖而保留其他字段；删除
`node_modules` 和锁文件；并且不触碰服务配置和用户补丁文件。

#### Scenario: 重置活跃服务

- **WHEN** 运行 `plugins reset --yes`
- **THEN** 服务被停止并重启，且原始清单被保留为备份

#### Scenario: 清单重写

- **WHEN** 清单被重写
- **THEN** 插件依赖从依赖映射和 bundle 列表中消失，而基础 bundle
  与无关字段仍为有效 JSON

#### Scenario: 防护条件

- **WHEN** 没有已安装的插件、给出 `--no-restart`，或非交互
  运行省略 `--yes`
- **THEN** 该套件分别断言相应的无操作消息、不存在停止和重启
  命令，以及非零退出

### Requirement: 导出与导入覆盖

该套件 SHALL 断言：导出默认生成一个 gzip 压缩归档，其中包含清单、配置副本、设置、会话和附件，
同时排除依赖目录、锁文件和凭据；内容和覆盖行为遵循内容标志与 `--force`；并且导入仅应用可移植
设置，备份被覆盖的文件，保留仅本地文件和主机特定值，并拒绝无效归档和绕过确认的行为。

#### Scenario: 默认导出

- **WHEN** 导出在不带内容标志的情况下运行
- **THEN** 归档包含清单、配置副本、设置文件、会话
  目录和附件目录
- **AND** 清单记录密钥被排除以及服务端口

#### Scenario: 内容标志

- **WHEN** 请求凭据或排除会话
- **THEN** 归档相应包含凭据文件或省略会话目录
- **AND** 在未带 `--force` 时拒绝已存在的输出路径

#### Scenario: 导入到新的 home

- **WHEN** 一个归档被导入到不同的 home 目录
- **THEN** 被覆盖的文件保留带编号的备份，无关的本地文件保留，归档中的
  可移植设置被应用，主机特定值保持本地，且先前的配置被
  备份

#### Scenario: 导入防护

- **WHEN** 使用或提供 `--dry-run`、`--no-config`、`--install-plugins`、缺失的归档或
  伪造的归档
- **THEN** 该套件分别断言目录树未变、端口保留、插件安装调用，
  以及非零退出

### Requirement: 加固与降级环境覆盖

该套件 SHALL 断言：配置值按字面存储，在被 source 时不能执行命令替换；单元渲染会拒绝包含换行符
的值；可执行路径中的百分号会为 systemd 转义；恶意的本地二进制目录会让 shell rc 文件保持语法
有效；无效或已移除的参数会被拒绝；并且缺失 `HOME`、`USER`、nvm 或 Node 时会以可读消息降级，
而不是产生未绑定变量失败。

#### Scenario: 配置值中的命令替换

- **WHEN** 某个配置值包含命令替换
- **THEN** 它被按字面存储，且 source 该配置不会执行它

#### Scenario: 额外参数中的换行符

- **WHEN** 额外参数中包含换行符
- **THEN** 单元渲染失败，且不写入任何单元文件

#### Scenario: 百分号转义

- **WHEN** 本地二进制目录包含百分号
- **THEN** 渲染出的可执行行会为 systemd 转义它

#### Scenario: 恶意前缀

- **WHEN** 前缀包含引号或美元符号
- **THEN** shell rc 文件保持语法有效，且 NVM 导出恰好出现一次

#### Scenario: 已移除的构建工具链选项

- **WHEN** 安装器以已移除的构建工具链标志调用
- **THEN** 它以非零退出并给出未知选项错误
- **AND** 该套件断言安装器的选项列表或摘要输出中不存在
  构建工具链步骤

#### Scenario: 缺失 HOME 与无效参数

- **WHEN** `HOME` 未设置，或给出非数字端口等无效参数
- **THEN** 脚本报告可读的错误并以非零退出，而不产生未绑定变量失败

### Requirement: 前置条件失败中止测试套件

当缺少所需的外部命令时，该套件 SHALL NOT 静默跳过；在严格 shell 模式下，缺失的前置条件 SHALL
中止运行并给出截至目前已产生的断言计数，而不是报告虚假的成功。

#### Scenario: 缺失的前置命令

- **WHEN** 该套件所使用的某个必需命令不可用
- **THEN** 该次运行失败，而不是报告所有断言均已通过
