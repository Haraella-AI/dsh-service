# service-control Specification

## Purpose

定义 `dshctl`（随 `install.sh` 一同安装的服务管理工具）的运维契约：它渲染运行 `dsh web` 的用户级
systemd 单元、控制该单元、报告其状态与日志、提取带令牌的登录 URL、打印版本与环境信息，并通过
`dshctl doctor` 诊断安装情况。由于单元是生成的，所有服务设置在渲染时即被固定，配置更改需要重启。

## Requirements

### Requirement: 渲染 systemd 用户单元

`dshctl` SHALL 在 `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/<name>.service` 渲染用户
systemd 单元，其中包含 `Type=exec`、一个以所配置的 profile、主机与端口（外加 `--no-open` 和任何
额外参数）调用本地 dsh 入口点的 `ExecStart`、所配置的 `PATH` 与 `DSH_HOME` 环境、
`Restart=on-failure`、重启延迟、停止超时、启动速率限制、journal 日志、作为 syslog 标识符的单元名，
以及 `WantedBy=default.target`。它 SHALL NOT 输出 `EnvironmentFile=` 或 `WorkingDirectory=` 指令。
仅当其内容变化时，该单元 SHALL 被重写，并且已存在的单元在被替换之前 SHALL 被备份一次。

#### Scenario: 默认渲染

- **WHEN** 使用默认设置渲染单元
- **THEN** 可执行行以 web profile、回环主机、所配置的端口和 no-open 标志运行本地 dsh 入口点

#### Scenario: 非默认 profile

- **WHEN** 所配置的 profile 不是 `web`
- **THEN** 可执行行在主机与端口参数之前显式传入该 profile

#### Scenario: 单元已是最新

- **WHEN** 渲染出的单元与现有单元文件相同
- **THEN** 不重写任何内容，并告知调用方单元未变化

#### Scenario: 不安全的值

- **WHEN** 单元名、dsh 路径、`DSH_HOME`、`PATH` 或额外参数包含换行符
- **THEN** 渲染以错误失败，且不写入任何单元文件

### Requirement: 服务生命周期命令

`dshctl start`、`dshctl stop` 与 `dshctl restart` SHALL 控制该用户单元，成功时报告单元名，当
systemd 操作失败时以非零退出状态和错误消息失败。`dshctl restart` SHALL 首先重新渲染单元，并 SHALL
验证服务随后变为活动状态。

#### Scenario: 启动服务

- **WHEN** `dshctl start` 成功
- **THEN** 命令报告单元已启动并以退出码 0 退出

#### Scenario: systemd 操作失败

- **WHEN** 底层的启动、停止或重启命令失败
- **THEN** 命令报告该失败并以非零状态退出

#### Scenario: 重启会重新渲染单元

- **WHEN** 运行 `dshctl restart`
- **THEN** 单元依据当前配置渲染，单元变化时重新加载 systemd，并重启服务
- **AND** 命令等待服务变为活动状态

#### Scenario: 重启后服务未处于活动状态

- **WHEN** 服务在重启宽限期之后仍未处于活动状态
- **THEN** 命令报告失败并附上观察到的状态，指向 `dshctl logs -n 30`，并以退出码 1 退出

### Requirement: 开机自启开关

`dshctl enable` SHALL 渲染单元、重新加载 systemd，并启用和启动该单元，同时验证其变为活动状态。
`dshctl disable` SHALL 禁用并停止该单元。两者 SHALL 报告结果状态，并在失败时以非零状态退出。

#### Scenario: 启用服务

- **WHEN** `dshctl enable` 成功
- **THEN** 命令报告服务已启用并已启动，并以退出码 0 退出

#### Scenario: 已启用但未活动

- **WHEN** 单元已启用但在宽限期内未变为活动状态
- **THEN** 命令报告观察到的状态，指向 `dshctl logs -n 30`，并以退出码 1 退出

#### Scenario: 禁用服务

- **WHEN** `dshctl disable` 成功
- **THEN** 命令报告开机自启已取消且服务已停止

### Requirement: 状态报告

`dshctl status` SHALL 先打印该单元的 systemd 状态，随后打印一份包含 dsh 版本、Node 版本、服务地址、
`DSH_HOME`、配置文件与单元文件路径以及监听端口（未发现监听者时报告为 none）的报告。该命令 SHALL 以
底层 systemd 状态查询的退出状态退出。

#### Scenario: 服务处于活动状态

- **WHEN** 单元处于活动状态
- **THEN** 报告包含版本、地址、路径以及检测到的监听端口
- **AND** 命令以退出码 0 退出

#### Scenario: 服务未活动或单元不存在

- **WHEN** 单元未活动或不存在
- **THEN** 报告仍会打印，并传播 systemd 状态的退出码

#### Scenario: 用户 systemd 不可用

- **WHEN** 无法访问用户 systemd 实例
- **THEN** 命令打印 systemd 指引并以退出码 1 退出

### Requirement: 带 journal 回退的日志查看

当用户 journal 可读时，`dshctl logs [args...]` SHALL 将其参数传递给该单元的用户 journal。当用户
journal 不可读时，它 SHALL 回退到按该单元 syslog 标识符过滤的免密 sudo journal 查询；当两者都不可
用时，它 SHALL 打印修复提示并以退出码 1 退出。

#### Scenario: 用户 journal 可读

- **WHEN** 用户 journal 可以被读取
- **THEN** 诸如跟随模式或行数之类的参数被传递给用户 journal 命令
- **AND** 返回其退出状态

#### Scenario: 回退到 sudo

- **WHEN** 用户 journal 不可读但免密 sudo journal 查询成功
- **THEN** 显示日志输出且命令以退出码 0 退出

#### Scenario: 日志不可获取

- **WHEN** 用户 journal 与 sudo 回退都不可用
- **THEN** 命令打印修复提示，包括 journal 组与手动 journal 命令，并以退出码 1 退出

### Requirement: 登录 URL 报告

`dshctl url [--plain] [--wait N]` SHALL 从服务最近的日志输出中提取第一个带令牌的登录 URL 并打印
它，或者在给出 `--plain` 时仅打印地址部分。使用 `--wait N` 时，它 SHALL 每秒重试一次，最多 N 次。
当找不到任何 URL 时，它 SHALL 报告失败并给出修复提示并以退出码 1 退出，并且它 SHALL 拒绝非数字的
等待值。

#### Scenario: 找到 URL

- **WHEN** 服务已打印登录 URL
- **THEN** 打印包含其令牌的完整 URL
- **AND** 使用 `--plain` 时仅打印令牌参数之前的地址

#### Scenario: 等待 URL

- **WHEN** 给出 `--wait N` 且 URL 稍后出现
- **THEN** 命令持续重试，直到找到 URL 或重试次数耗尽

#### Scenario: 无效的等待值

- **WHEN** `--wait` 被赋予非数字值
- **THEN** 命令报告该无效值并以退出码 1 退出

#### Scenario: 未找到 URL

- **WHEN** 日志中没有出现登录 URL
- **THEN** 命令报告失败，打印获取日志或重启的提示，并以退出码 1 退出

### Requirement: 版本输出

`dshctl version` SHALL 打印 dshctl 版本以及 dsh、Node 与 npm 版本和单元文件与配置文件路径，对缺失
的工具使用未检测到的标记。`dshctl -V` 与 `dshctl --version` SHALL 仅打印 dshctl 版本。

#### Scenario: 完整版本报告

- **WHEN** 运行 `dshctl version`
- **THEN** 打印 dshctl、dsh、node、npm、unit 与 configuration 的带标签行

#### Scenario: 缺失的工具

- **WHEN** 未安装 dsh、Node 或 npm
- **THEN** 相应的行报告该工具未检测到

#### Scenario: 短版本标志

- **WHEN** 给出 `dshctl -V` 或 `dshctl --version`
- **THEN** 恰好打印一行 dshctl 版本

### Requirement: 环境自检

`dshctl doctor` SHALL 运行固定的检查清单，并针对每项检查打印一行，标记为通过、失败或值得注意，随后
给出通过与失败数量的摘要。当任何检查失败时它 SHALL 以退出码 1 退出，否则以 0 退出，并且 SHALL 拒绝
未知参数。不表示损坏的警告，例如位于 `/mnt` 挂载上的 `DSH_HOME` 或只能通过 sudo 读取的 journal，
SHALL 被报告为值得注意而非失败。

#### Scenario: 所有检查通过

- **WHEN** 每项检查都成功
- **THEN** 摘要报告通过的检查数量，且命令以退出码 0 退出

#### Scenario: 至少一项检查失败

- **WHEN** 一项或多项检查失败
- **THEN** 摘要报告失败数量，且命令以退出码 1 退出

#### Scenario: 检查清单的覆盖范围

- **WHEN** doctor 运行
- **THEN** 它检查 nvm 安装、Node 主版本、dsh 二进制、Web 前端资源、dsh 配置转储、用户 systemd
  可用性、单元的存在性、启用状态与活动状态、lingering、监听端口、journal 可读性、`PATH` 上的本地
  二进制目录，以及稳定的 dsh 入口点

#### Scenario: 未知参数

- **WHEN** 向 `dshctl doctor` 传入无法识别的参数
- **THEN** 命令报告该未知参数并以退出码 1 退出

### Requirement: Doctor 修复

`dshctl doctor --fix` SHALL 额外刷新稳定的 dsh 入口点并重新渲染单元，在单元变化时重新加载
systemd。失败的修复 SHALL 被报告，但 SHALL NOT 中止 doctor 报告或改变其摘要语义。

#### Scenario: 刷新入口点

- **WHEN** 能够解析出全局 dsh 二进制
- **THEN** 稳定入口点被重新链接到它，并报告该目标

#### Scenario: 修复失败

- **WHEN** 诸如解析全局 dsh 二进制或渲染单元之类的修复失败
- **THEN** 报告该失败，且 doctor 报告仍以摘要完成

### Requirement: 用户 systemd 可用性处理

当无法访问用户 systemd 实例时，需要用户 systemd 的命令 SHALL 以错误和固定的指引块失败。向用户报告
结果的命令路径 SHALL 以退出码 1 退出，而其他命令使用的内部辅助函数 SHALL 返回失败状态或降级并给出
警告，而不是终止进程。当运行时目录或会话总线地址未设置但用户运行时套接字存在时，在调用 systemd
之前 SHALL 合成这两者。

#### Scenario: 用户 systemd 不可达

- **WHEN** 无法查询用户 systemd 环境
- **THEN** 命令打印指引块并失败，而不尝试执行 systemd 操作

#### Scenario: 重启无法访问 systemd

- **WHEN** 请求重启但用户 systemd 不可达
- **THEN** 操作警告重启已被跳过，打印手动重启命令，并向调用方报告失败，而不是立即退出

#### Scenario: Lingering 设置

- **WHEN** 应用 lingering
- **THEN** 报告已启用的状态，否则优先使用免密 sudo，其次是无特权尝试，然后是交互式 sudo
- **AND** 完全失败时警告该服务在没有登录的情况下不会在开机时启动
