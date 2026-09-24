# maintenance Specification

## Purpose

定义内嵌的 `dshctl` 工具对已安装的 dsh 服务执行的维护与生命周期操作：升级 dsh 包和 Node
主版本，并在失败时自动回滚；盘点与重置 profile 插件；以 `tar.gz` 形式导出和导入服务配置及
`DSH_HOME`；在卸载时移除已安装的产物；以及在前台运行 `dsh web` 以便调试。这些操作最有可能
破坏一个可用的安装，因此其失败隔离、备份与确认行为属于契约的一部分。

## Requirements

### Requirement: 升级版本解析

`dshctl upgrade [<version>|<dist-tag>] [--check] [--yes] [--no-restart]` SHALL 以默认通道 `next` 作为
省略目标时的目标：未给出目标时，它 SHALL 查询 npm registry 上 `@deepseek-ai/dsh` 的 `dist-tags` 并把
`next` 解析为具体版本。显式给出的 dist-tag（`latest`、`next` 等）SHALL 以同样方式解析为具体版本；
显式给出的具体版本 SHALL 原样使用。在任何版本比较之前，SHALL 先去除开头的 `v`。显式请求的目标版本
SHALL 在安装任何内容之前针对 registry 进行校验；当 registry 回应称该版本或 dist-tag 不存在时，命令
SHALL 在安装前失败，指明所请求的目标版本，提示版本列表命令，显示默认通道 `next` 的当前版本，并以退出
码 1 退出。当校验期间无法访问 registry 时，命令 SHALL 发出警告并继续尝试安装。当解析出的目标版本
等于已安装版本时，命令 SHALL 报告无需升级，并在刷新 dsh 入口点后以退出码 0 退出。

#### Scenario: 省略目标时使用默认通道

- **WHEN** 用户运行 `dshctl upgrade` 而不给出目标
- **THEN** 目标版本是 registry 的 `dist-tags` 中 `next` 指向的版本，而不是 `latest` 指向的版本

#### Scenario: 显式 latest

- **WHEN** 用户运行 `dshctl upgrade latest`
- **THEN** 目标版本是 registry 的 `dist-tags` 中 `latest` 指向的版本

#### Scenario: 已处于目标版本

- **WHEN** 解析出的目标版本等于已安装的 dsh 版本
- **THEN** 命令记录日志，说明已安装版本已经是最新版本
- **AND** 在不重新安装的情况下刷新 `~/.local/bin/dsh` 入口点
- **AND** 以退出码 0 退出

#### Scenario: 传入的版本带有 v 前缀

- **WHEN** 用户运行 `dshctl upgrade v0.1.6-alpha.2`
- **THEN** 在将已安装版本与目标版本比较之前，先去除开头的 `v`
- **AND** 该版本的成功安装不会被误报为版本检查失败

#### Scenario: 不存在的版本在安装前被拒绝

- **WHEN** 用户请求 registry 未发布的版本或 dist-tag，例如
  `dshctl upgrade 1.7.0-rc.1`
- **THEN** 命令报告所请求的版本不存在
- **AND** 提示版本列表命令，并显示默认通道 `next` 的当前版本
- **AND** 以退出码 1 退出，不执行包安装，也不改动已安装的 dsh

#### Scenario: 校验期间 registry 不可达

- **WHEN** 校验显式请求的目标版本时无法查询 registry
- **THEN** 命令警告无法确认该版本是否存在
- **AND** 继续执行安装、校验与回滚流程

#### Scenario: 无法解析目标版本

- **WHEN** 未给出显式版本且 npm registry 查询没有返回任何结果
- **THEN** 命令报告无法解析目标版本并以退出码 1 退出

#### Scenario: dsh 未安装

- **WHEN** 检测不到任何已安装的 dsh 版本且请求升级
- **THEN** 命令报告 dsh 未安装并以退出码 1 退出

### Requirement: 升级失败隔离

当 `dshctl upgrade` 的包安装步骤失败时，命令 SHALL 报告现有安装未被改动，并 SHALL 在不尝试
回滚的情况下以退出码 1 退出，因为没有替换任何东西。当失败输出表明未找到匹配的版本时，命令
SHALL 额外报告所请求的版本不存在，并提示版本列表命令和当前最新版本。

#### Scenario: npm install 失败

- **WHEN** `npm install -g @deepseek-ai/dsh@<target>` 以非零状态退出
- **THEN** 命令报告服务未被修改，此前安装的版本仍然保留在原位
- **AND** 以退出码 1 退出，且不进入回滚路径

#### Scenario: 安装因版本不存在而失败

- **WHEN** 包安装失败并给出未找到匹配版本的诊断信息
- **THEN** 命令报告该失败且不回滚
- **AND** 打印版本未找到的提示，指明所请求的目标版本、版本列表命令以及当前最新版本

### Requirement: 安装后校验与自动回滚

在包安装成功后，`dshctl upgrade` SHALL 校验已安装版本与目标版本一致，并且服务能成功重启。
如果任一校验失败，命令 SHALL 重新安装此前安装的版本，且无论回滚本身是否成功都 SHALL 以退出
码 1 退出。

#### Scenario: 已安装版本与目标版本不一致

- **WHEN** 安装后报告的版本与目标版本不同
- **THEN** 命令警告安装后版本校验失败
- **AND** 重新安装上一个版本
- **AND** 以退出码 1 退出

#### Scenario: 服务重启失败

- **WHEN** 重启并等待的步骤失败
- **THEN** 命令警告重启失败，并尝试回滚到上一个版本
- **AND** 以退出码 1 退出

#### Scenario: 回滚安装失败

- **WHEN** 回滚过程中重新安装上一个版本失败
- **THEN** 命令报告该失败，并打印用于恢复该版本的手动 npm 命令
- **AND** 以退出码 1 退出

#### Scenario: 升级成功

- **WHEN** 安装、版本校验和重启全部成功
- **THEN** 命令刷新入口点、重启服务，并记录版本变更
- **AND** 以退出码 0 退出

### Requirement: Node 主版本升级

`dshctl upgrade-node [<major>]` SHALL 通过 nvm 安装请求的 Node 主版本（未给出时使用当前主版本），将其
设为 nvm 默认版本，把默认通道 `next` 指向的 dsh 版本以及升级前存在的 pnpm 版本重新安装到新的 Node
上，使用新的 Node 二进制目录重新渲染服务配置，刷新入口点，并重启服务。pnpm 重新安装失败 SHALL 仅发出
警告；缺失 dsh 版本或 Node 安装失败 SHALL 以非零退出码中止。

#### Scenario: 从正在运行的 Node 推断主版本

- **WHEN** 未给出主版本参数
- **THEN** 使用当前 Node 主版本
- **AND** 当无法确定主版本时，命令以退出码 1 中止

#### Scenario: 切换 Node 时按默认通道重装 dsh

- **WHEN** 为新 Node 主版本重装 dsh
- **THEN** 安装目标是 registry 的 `dist-tags` 中 `next` 指向的版本，而不是升级前的已安装版本

#### Scenario: pnpm 重新安装失败

- **WHEN** 为新 Node 版本重新安装 pnpm 失败
- **THEN** 命令发出警告，并给出需要手动运行的命令
- **AND** 仍完成升级的其余部分

#### Scenario: Node 安装失败

- **WHEN** 通过 nvm 安装请求的主版本失败
- **THEN** 命令报告该失败，并指明所配置的 Node 镜像
- **AND** 以退出码 1 退出

#### Scenario: 用户级 systemd 不可用

- **WHEN** 由于无法访问用户级 systemd 而无法重启服务
- **THEN** 命令发出警告但仍以退出码 0 退出，因为 Node 和软件包的变更已经成功
### Requirement: 插件清单

`dshctl plugins list` SHALL 打印 profile 名称、profile 目录，以及该 profile 的
`package.json` 中每个顶层依赖，每行一个。当 manifest 存在但没有依赖时，它 SHALL 报告列表为
空；当 manifest 缺失时，报告 profile 尚未初始化。

#### Scenario: manifest 缺失

- **WHEN** profile 的 `package.json` 不存在
- **THEN** 命令打印 profile 尚未初始化
- **AND** 以退出码 0 退出

#### Scenario: 依赖已安装

- **WHEN** manifest 声明了顶层依赖
- **THEN** 在 profile 目录下逐个列出每个依赖名称，每行一个
- **AND** 显示已安装插件的数量

#### Scenario: 未知参数

- **WHEN** `plugins list` 后面跟着无法识别的参数
- **THEN** 命令报告该未知参数并以退出码 1 退出

### Requirement: 插件重置

`dshctl plugins reset [--yes] [--no-restart]` SHALL 从 `package.json` 和
`dsh.profile.bundles` 列表中移除当前 profile 的每个顶层插件依赖，删除 profile 的
`node_modules` 目录和 `pnpm-lock.yaml`，将原始 manifest 备份到 `package.json.bak`，随后重启
服务。命令 SHALL 保持服务配置文件、`settings.yaml`、凭据以及 profile 的 `cordis.patch.yml`
不变。

#### Scenario: 非交互环境下未确认

- **WHEN** 未指定 `--yes` 且标准输入不是终端
- **THEN** 命令报告在非交互环境中需要 `--yes` 并以退出码 1 退出

#### Scenario: 用户拒绝确认

- **WHEN** 用户对 `[y/N]` 提示做出否定回答
- **THEN** 命令记录操作已取消并以退出码 0 退出，不更改任何内容

#### Scenario: 重写前备份 manifest

- **WHEN** 重置继续进行
- **THEN** manifest 在被重写之前先复制到 `package.json.bak`

#### Scenario: 重写后的 manifest 无效

- **WHEN** 重写后的 manifest 未通过 JSON 校验
- **THEN** 命令以退出码 1 中止，不移除插件也不修改配置

#### Scenario: 抑制重启

- **WHEN** 指定了 `--no-restart`
- **THEN** 服务保持原来的运行或停止状态，命令警告稍后运行 `dshctl restart`

#### Scenario: profile 没有插件

- **WHEN** manifest 缺失或未声明任何依赖
- **THEN** 命令报告没有可重置的内容，并以退出码 0 退出且不做任何修改

### Requirement: 导出归档布局与内容

`dshctl export [-o FILE] [--no-sessions] [--no-attachments] [--with-secrets] [--force]` SHALL
写出一个 `tar.gz` 归档，其中包含由 `KEY=VALUE` 行组成的 `manifest`、位于 `config/` 下的服务
配置只读副本，以及位于 `dsh-home/` 下的 `DSH_HOME` 内容。归档 SHALL 始终排除 `node_modules`、
模块回退目录和锁文件；凭据仅在指定 `--with-secrets` 时才 SHALL 包含，会话和附件 SHALL 由各自
的标志排除。默认输出文件名 SHALL 标明主机和导出时间戳。

#### Scenario: 默认导出

- **WHEN** 导出在未指定任何内容标志的情况下运行
- **THEN** 归档包含 manifest、配置副本和 `DSH_HOME` 内容
- **AND** 会话和附件被包含在内
- **AND** 凭据未被包含

#### Scenario: 包含凭据

- **WHEN** 指定了 `--with-secrets`
- **THEN** 归档包含凭据文件
- **AND** 归档权限受到限制，并打印关于如何保管它的警告

#### Scenario: manifest 内容

- **WHEN** 归档被写出
- **THEN** manifest 记录导出格式版本、导出工具版本、导出时间戳与主机、dsh 版本、源
  `DSH_HOME`，以及可移植的服务设置（名称、profile、host、port、额外参数）和内容包含标志

#### Scenario: 归档写入 DSH_HOME 内部

- **WHEN** 解析出的输出路径位于 `DSH_HOME` 内部
- **THEN** 输出文件被排除在归档之外，从而不会同时读写同一个文件

### Requirement: 导出前置条件与失败处理

`dshctl export` SHALL 在以下情况以退出码 1 失败：`tar` 命令不可用、manifest 值包含换行或
回车、输出路径是目录或是在未指定 `--force` 时已存在的文件、无法创建临时目录，或打包失败
——最后一种情况下会删除不完整的归档。当配置文件或 `DSH_HOME` 缺失时，它 SHALL 发出警告并
继续。

#### Scenario: 输出文件已存在

- **WHEN** 输出路径已存在且未指定 `--force`
- **THEN** 命令报告该文件已存在并以退出码 1 退出

#### Scenario: 打包失败

- **WHEN** `tar` 命令以非零状态退出
- **THEN** 不完整的归档被删除
- **AND** 命令报告打包失败并以退出码 1 退出

### Requirement: 导入归档校验

`dshctl import <archive.tar.gz>` SHALL 以退出码 1 拒绝以下情况：归档路径缺失或不是常规文件、
`tar.gz` 不可读、任何归档成员位于 `manifest`、`config/` 或 `dsh-home/` 之外、任何成员逃逸
出解压根目录、`manifest` 格式版本缺失或不受支持、格式错误的 `KEY=VALUE` manifest 行，以及
非数字或超出范围的端口。

#### Scenario: 归档包含外来成员

- **WHEN** 某个成员既不是 `manifest` 也不位于 `config/` 或 `dsh-home/` 之下
- **THEN** 命令报告该违规成员，并在解压任何内容之前以退出码 1 退出

#### Scenario: 不支持的归档格式

- **WHEN** manifest 缺少预期的导出格式版本，或声明了不同的版本
- **THEN** 命令报告格式不受支持并以退出码 1 退出

#### Scenario: 归档路径无效

- **WHEN** 位置参数中的归档参数缺失或不是常规文件
- **THEN** 命令报告该问题并以退出码 1 退出

### Requirement: 导入应用、备份与重启

在确认后，`dshctl import <archive.tar.gz> [--yes] [--no-config] [--no-restart]
[--install-plugins] [--dry-run]` SHALL 停止活动 unit，将现有服务配置备份为带时间戳的
`config.bak-*` 文件，仅应用可移植设置（profile、host、port、额外参数）并保留主机特定值
（unit 名称、`DSH_HOME`、nvm 和 Node 路径），将归档中的 `DSH_HOME` 合并覆盖到本地
`DSH_HOME`，对被覆盖的文件保留带编号的备份，然后重启服务。`--dry-run` SHALL 报告计划执行
的操作且不写入任何内容。

#### Scenario: 试运行

- **WHEN** 指定了 `--dry-run`
- **THEN** 命令报告未写入任何文件，并以退出码 0 退出且不做任何修改

#### Scenario: 非交互环境下未确认

- **WHEN** 未指定 `--yes` 且标准输入不是终端
- **THEN** 命令报告需要 `--yes` 并以退出码 1 退出

#### Scenario: 合并保留未归档的文件

- **WHEN** 应用归档中的 `DSH_HOME`
- **THEN** 归档中不包含的文件保持原样
- **AND** 被覆盖的文件保留带编号的备份

#### Scenario: 插件未归档

- **WHEN** profile manifest 列出了依赖且未指定 `--install-plugins`
- **THEN** 命令警告 `node_modules` 不属于归档内容，并打印手动安装插件的命令

#### Scenario: 禁用配置应用

- **WHEN** 指定了 `--no-config`
- **THEN** 归档中的可移植设置会被显示，但不会被写入

#### Scenario: 导入后重启失败

- **WHEN** 导入后的重启失败
- **THEN** 命令报告重启失败并以退出码 1 退出

### Requirement: Shell RC 块移除

在 purge 时，卸载路径 SHALL 从 `$HOME/.bashrc` 移除带标记的 `dsh-service` 块，并先将该文件
复制为备份。当文件或起始标记缺失时，它 SHALL 静默成功；当起始标记存在但没有匹配的结束标记
时，SHALL 发出警告并跳过。

#### Scenario: 存在带标记的块

- **WHEN** 起始标记和结束标记都存在
- **THEN** 在删除该块之前创建 `~/.bashrc.dsh-service.bak`

#### Scenario: 没有需要移除的块

- **WHEN** `~/.bashrc` 或起始标记缺失
- **THEN** 该过程返回成功，且不修改任何文件

#### Scenario: 结束标记缺失

- **WHEN** 起始标记存在但结束标记不存在
- **THEN** 该过程警告结束标记缺失，并跳过清理

### Requirement: 卸载范围

`dshctl uninstall [--purge] [--remove-dsh-home] [--remove-node] [--yes]` SHALL 要求确认
（交互式提示，或在非交互环境中使用 `--yes`），然后禁用并停止 unit，移除 unit 文件及其备份、
本地 `dsh` 入口点和已安装的 `dshctl`。服务配置目录和 shell rc 块 SHALL 仅在使用 `--purge`
时移除，`DSH_HOME` 仅在使用 `--remove-dsh-home` 时移除，Node 版本仅在使用 `--remove-node`
时移除。此命令 SHALL 永不移除全局安装的 npm 包。

#### Scenario: 默认卸载

- **WHEN** 仅指定 `--yes`
- **THEN** unit、本地入口点和 `dshctl` 被移除
- **AND** 配置目录、shell rc 块、`DSH_HOME` 和 Node 安装被保留

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

### Requirement: 前台运行

`dshctl run [-- <args>...]` SHALL 使用服务的 `DSH_HOME` 和 profile 在前台运行解析到的 dsh
二进制文件，传入配置的 host 和 port，然后传入任何额外参数；当找不到 dsh 二进制文件时 SHALL
以退出码 1 退出。

#### Scenario: 默认 web profile

- **WHEN** 配置的 profile 是 `web`
- **THEN** 命令运行 `dsh web --host <host> --port <port>`，并附加任何额外参数

#### Scenario: 指定名称的 profile

- **WHEN** 配置的 profile 不是 `web`
- **THEN** 命令运行 `dsh --profile <profile> --host <host> --port <port>`，并附加任何额外
  参数

#### Scenario: 没有 dsh 二进制文件

- **WHEN** 无法解析出任何 dsh 二进制文件
- **THEN** 命令报告该问题并以退出码 1 退出

### Requirement: 升级版本列表

`dshctl upgrade --list [N]` SHALL 查询所配置的 registry 以获取 `@deepseek-ai/dsh` 已发布的
版本和 dist-tag，并按从新到旧的顺序打印版本，标记 dist-tag 所指向的版本。它 SHALL 将输出
限制为请求的条目数量，默认使用一个有界数量，并 SHALL 拒绝非数字或非正数的计数。列出操作
SHALL NOT 要求已安装 dsh，SHALL NOT 安装任何内容，且 SHALL NOT 启动、停止或重启服务。当
registry 查询失败时，命令 SHALL 报告无法获取版本列表，打印网络或 registry 提示，并以退出码
1 退出。

#### Scenario: 列出可用版本

- **WHEN** `dshctl upgrade --list` 针对可达的 registry 运行
- **THEN** 已发布的版本按从新到旧的顺序打印
- **AND** dist-tag 所指向的版本会被如此标记
- **AND** 命令以退出码 0 退出

#### Scenario: 限制列表长度

- **WHEN** 给出正数计数，例如 `dshctl upgrade --list 5`
- **THEN** 最多打印该数量的版本

#### Scenario: 无效的计数

- **WHEN** 计数为非数字或非正数
- **THEN** 命令报告该计数无效并以退出码 1 退出

#### Scenario: 在未安装 dsh 的情况下可用

- **WHEN** 在未安装 dsh 的机器上运行 `dshctl upgrade --list`
- **THEN** 版本被列出，且命令以退出码 0 退出
- **AND** 不会尝试任何安装或服务操作

#### Scenario: registry 不可达

- **WHEN** 无法查询 registry
- **THEN** 命令报告无法获取版本列表，打印网络或 registry 提示，并以退出码 1 退出
