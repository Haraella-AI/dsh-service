# Spec Delta

## MODIFIED Requirements

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
