# Spec Delta

## MODIFIED Requirements

### Requirement: 升级版本解析

`dshctl upgrade [<version>|latest] [--check] [--yes] [--no-restart]` SHALL 通过查询 npm
registry 获取最新的 `@deepseek-ai/dsh` 版本来解析省略的版本或 `latest`，并 SHALL 接受显式
版本或 dist-tag。在任何版本比较之前，SHALL 先去除开头的 `v`。显式请求的目标版本 SHALL 在
安装任何内容之前针对 registry 进行校验；当 registry 回应称该版本或 dist-tag 不存在时，命令
SHALL 在安装前失败，指明所请求的目标版本，提示版本列表命令，显示当前最新版本，并以退出码 1
退出。当校验期间无法访问 registry 时，命令 SHALL 发出警告并继续尝试安装。当解析出的目标版本
等于已安装版本时，命令 SHALL 报告无需升级，并在刷新 dsh 入口点后以退出码 0 退出。

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
- **AND** 提示版本列表命令，并显示当前最新版本
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

## ADDED Requirements

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
