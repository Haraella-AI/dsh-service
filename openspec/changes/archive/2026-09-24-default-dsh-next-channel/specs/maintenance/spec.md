# Spec Delta

## MODIFIED Requirements

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
