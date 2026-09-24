# configuration Specification

## Purpose

定义 `install.sh` 与内嵌的 `dshctl` 之间共享的配置契约：配置位于何处，如何按环境变量、配置文件、
内置默认值的顺序解析出有效值，如何安全且幂等地写入该文件，Web 端口在占用时如何校验与分配，以及
镜像与 registry 设置如何被选择并注入 npm、nvm 和 Node 下载。

## Requirements

### Requirement: 配置文件位置与格式

`install.sh` 与 `dshctl` SHALL 共用位于
`${DSHCTL_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-service}/config` 的单一配置文件。该文件
SHALL 是一个 Bash 片段，包含针对 `DSH_SERVICE_*` 键的 `: "${VAR:=value}"` 赋值——单元名、profile、
主机、端口、`DSH_HOME`、nvm 目录、Node 二进制目录、本地二进制目录、额外参数、镜像模式、npm
registry 和 Node 镜像——并且 SHALL 以 source 方式加载，而不是当作数据解析。诸如 systemd 单元文件
这类派生路径 SHALL 遵循所配置的单元名。

#### Scenario: 默认配置路径

- **WHEN** 既未设置 `DSHCTL_CONFIG_DIR` 也未设置 `XDG_CONFIG_HOME`
- **THEN** 配置路径为 `$HOME/.config/dsh-service/config`

#### Scenario: 单元路径遵循所配置的名称

- **WHEN** 配置将单元名设置为非默认值
- **THEN** 单元文件路径为 `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/<name>.service`

#### Scenario: 仅安装期生效的选项不会被持久化

- **WHEN** 安装器以 `--node-major`、`--nvm-version`、`--dsh-version` 或
  `--pnpm-version` 运行
- **THEN** 没有任何配置键记录这些值

### Requirement: 配置优先级

有效设置 SHALL 按环境变量优先、其次配置文件、最后内置默认值的顺序解析，因为配置文件在环境之后被
source 并使用 `:=` 赋值。安装器的命令行选项 SHALL 在该次运行期间覆盖这两者，并 SHALL 被写回配置
文件。

#### Scenario: 环境变量覆盖配置文件

- **WHEN** 运行 `DSH_SERVICE_PORT=4000 dshctl restart`
- **THEN** 该次调用的有效端口为 4000
- **AND** 配置文件不会被重写

#### Scenario: 命令行选项覆盖环境变量

- **WHEN** 运行 `DSH_SERVICE_PORT=4000 bash install.sh --port 5000`
- **THEN** 有效端口为 5000
- **AND** 配置文件被重写为 5000

#### Scenario: 显式镜像选项优先于环境变量

- **WHEN** 导出了 `DSH_SERVICE_MIRROR=0` 并传入 `--mirror`
- **THEN** 有效镜像模式被启用，且在重新应用默认值之前清除过期的 registry 与镜像值

### Requirement: 原子且幂等的配置重写

配置 SHALL 通过一个在配置目录中创建、权限为 0644 的临时文件写入，与现有文件逐字节比较，并且仅在
内容不同时才替换；当内容未变时，SHALL 删除该临时文件，并且该次运行 SHALL 报告配置未被修改。包含
换行符或回车符的值 SHALL 以退出码 1 被拒绝，而不是被写入。

#### Scenario: 未变更时重新运行

- **WHEN** 渲染出的配置与现有文件相同
- **THEN** 现有文件保持不变，且不残留临时文件

#### Scenario: 保留用户编辑的值

- **WHEN** 配置包含诸如额外的 `dsh web` 参数之类的自定义值，且安装器在未覆盖它的情况下重新运行
- **THEN** 重写后的配置仍包含该值

#### Scenario: 值包含换行符

- **WHEN** 某个有效配置值包含换行符
- **THEN** 操作报告值不得包含换行符并以退出码 1 退出
- **AND** 现有配置文件不会被覆盖

#### Scenario: 值按字面存储

- **WHEN** 配置值包含 `$()` 或反引号之类的 shell 元字符
- **THEN** 该值在文件中被 shell 引用，因此 source 它时不会执行任何替换

### Requirement: 拒绝无效配置

在 source 配置之前，`install.sh` 与 `dshctl` 都 SHALL 使用 `bash -n` 校验它。遇到语法错误时，它们
SHALL 打印配置路径与修复提示并以退出码 1 退出，且不修改该文件。

#### Scenario: 安装器在配置损坏时中止

- **WHEN** 配置文件包含 shell 语法错误且安装器运行
- **THEN** 它在任何安装步骤之前报告配置错误并以退出码 1 退出

#### Scenario: dshctl 在配置损坏时中止

- **WHEN** 任何 `dshctl` 命令在配置语法无效的情况下运行
- **THEN** 它报告路径与修复提示并以退出码 1 退出

### Requirement: 配置查看与编辑

`dshctl config` SHALL 打印配置路径（文件尚不存在时加以标注）、所有有效的 `DSH_SERVICE_*` 值、派生
出的单元路径与 dsh 路径，以及一条说明环境变量优先的提示。`dshctl config edit` SHALL 使用
`${EDITOR:-vi}` 打开该文件，并且当文件不存在时 SHALL 以退出码 1 退出。

#### Scenario: 显示配置

- **WHEN** 运行 `dshctl config`
- **THEN** 打印每个有效值，包括来自环境变量的值
- **AND** 空的 Node 镜像显示为使用官方源

#### Scenario: 在没有配置文件时编辑

- **WHEN** 运行 `dshctl config edit` 且不存在配置文件
- **THEN** 它报告文件不存在，建议运行安装器，并以退出码 1 退出

#### Scenario: 编辑现有配置

- **WHEN** 在配置文件存在的情况下运行 `dshctl config edit`
- **THEN** 使用所配置的编辑器打开该文件
- **AND** 告知用户需要执行 `dshctl restart` 才能使更改生效

### Requirement: 端口值校验与规范化

所配置的端口 SHALL 是 1 到 65535 之间的整数；任何其他值 SHALL 导致以退出码 1 退出，并给出指明该无
效值的消息。前导零 SHALL 在任何算术运算或比较之前按十进制解释。

#### Scenario: 非数字端口

- **WHEN** 端口为空或不是数字
- **THEN** 命令报告需要一个数字端口并以退出码 1 退出

#### Scenario: 端口超出范围

- **WHEN** 端口为 0、大于 65535 或为六位数
- **THEN** 命令报告端口必须在 1 到 65535 之间并以退出码 1 退出

#### Scenario: 前导零

- **WHEN** 端口指定为 `080`
- **THEN** 有效端口为 80

### Requirement: 端口预检与自动递进

安装之前，`install.sh` SHALL 检测所请求的端口是否被占用。当该端口被外部进程占用时，如果给定了
`--strict-port`，它 SHALL 以退出码 1 退出；否则探测接下来的 20 个端口，采用第一个空闲端口，并报告
该替换；当没有任何候选端口空闲时，它 SHALL 以退出码 1 退出。被采用的端口 SHALL 写入配置与单元
文件。

#### Scenario: 端口被另一个进程占用

- **WHEN** 所请求的端口被外部监听者占用且未给出 `--strict-port`
- **THEN** 安装器发出警告，选择下一个空闲端口并继续
- **AND** 配置与单元文件使用所选的端口

#### Scenario: 严格端口模式

- **WHEN** 给出了 `--strict-port` 且所请求的端口被外部监听者占用
- **THEN** 安装器以退出码 1 退出，不更改端口也不写入单元文件

#### Scenario: 没有空闲候选端口

- **WHEN** 接下来的 20 个端口全部被占用
- **THEN** 安装器报告端口耗尽并以退出码 1 退出

### Requirement: 自身占用端口的识别

仅当所配置单元名对应的单元文件存在、其可执行行指定了该端口且该单元处于活动状态时，`install.sh`
SHALL 将被占用的端口视为属于本次安装。在这种情况下，它 SHALL 保留该端口并报告它正被本服务使用。

#### Scenario: 服务运行时重新运行

- **WHEN** 本次安装的服务在配置的端口上处于活动状态且安装器重新运行
- **THEN** 端口被保留，既不递进也不报错

#### Scenario: 其他进程占用该端口

- **WHEN** 另一个程序监听所配置的端口
- **THEN** 该端口不被视为本次安装自身所有，预检根据 `--strict-port` 递进端口或失败

### Requirement: 监听者检测的回退策略

`install.sh` SHALL 使用 `ss` 检测监听者，回退到 `lsof`，最后回退到回环连接测试。内嵌的 `dshctl`
SHALL 仅使用 `ss` 或 `lsof` 检测监听者；当两个工具都不可用时，它 SHALL 报告没有监听者，这意味着
`dshctl status` 不显示监听者，且 `dshctl doctor` 报告该端口未在监听。

#### Scenario: 优先使用 ss

- **WHEN** `ss` 与 `lsof` 都可用
- **THEN** 仅由 `ss` 的输出决定该端口是否被占用

#### Scenario: 回环连接测试

- **WHEN** 安装器既没有 `ss` 也没有 `lsof` 可用
- **THEN** 回环连接被拒绝表示端口空闲，连接成功表示端口被占用

#### Scenario: dshctl 中缺少工具

- **WHEN** `dshctl` 既没有 `ss` 也没有 `lsof` 可用
- **THEN** 监听者字段报告为 none，且针对该端口的 doctor 检查失败

### Requirement: 镜像选择与注入

镜像模式 SHALL 默认启用，使用 npmmirror 的 npm registry、npmmirror 的 Node 发行版镜像以及托管在
Gitee 上的 nvm 源；`--no-mirror` SHALL 选择官方 npm registry、nodejs.org 与 GitHub 源，并清除先前
存储的镜像 URL。不是 0 或 1 的镜像值 SHALL 导致以退出码 1 退出。环境中已存在的更低层级变量
（`npm_config_registry`、`NVM_NODEJS_ORG_MIRROR`、`NVM_SOURCE`）SHALL NOT 被覆盖，并且当 `git`
不可用时，nvm 的 git 源 SHALL 被丢弃并给出警告。

#### Scenario: 切换到官方源

- **WHEN** 在已配置镜像的机器上传入 `--no-mirror`
- **THEN** 存储的 npm registry 与 Node 镜像值被清除
- **AND** 安装使用官方源

#### Scenario: 用户提供的 registry 优先

- **WHEN** `npm_config_registry` 已被导出
- **THEN** 所配置的 npm registry 不会覆盖它

#### Scenario: git 不可用

- **WHEN** 镜像模式处于活动状态且未安装 `git`
- **THEN** 安装器警告 nvm 的 git 源被忽略，并改用下载的脚本安装 nvm

#### Scenario: 无效的镜像值

- **WHEN** 镜像设置为 0 或 1 以外的值
- **THEN** 安装器报告该无效值并以退出码 1 退出

### Requirement: HOME 与 USER 的健壮性

两个脚本 SHALL 在 `set -Eeuo pipefail` 下运行，且不会因 `USER` 未设置而失败，此时从 `id -un` 推导
用户或回退为 `unknown`。当 `HOME` 未设置或为空时，它们 SHALL 以退出码 1 退出并给出清晰的消息，但
安装器的 `--help` 与 `--print-dshctl` 路径 SHALL 在该检查之前以退出码 0 完成。

#### Scenario: USER 未设置

- **WHEN** 环境中 `USER` 未设置
- **THEN** 脚本使用推导出的用户名继续运行，且从不报告未绑定变量

#### Scenario: HOME 未设置

- **WHEN** `HOME` 为空且执行普通的 `dshctl` 命令或普通的安装器运行
- **THEN** 命令报告缺少 `HOME` 变量并以退出码 1 退出

#### Scenario: 没有 HOME 时的帮助

- **WHEN** `HOME` 为空且运行 `install.sh --help`
- **THEN** 打印用法文本且脚本以退出码 0 退出

### Requirement: 临时文件清理

脚本创建的每个临时文件或目录 SHALL 被注册，并由一个忽略错误的单一 `EXIT` trap 删除，从而使中止和
失败的运行不会在配置目录或单元目录中留下任何临时产物。

#### Scenario: 正常完成

- **WHEN** 一次创建了临时文件的运行完成
- **THEN** 配置目录或单元目录中不残留临时文件

#### Scenario: 中途失败

- **WHEN** 一次运行在创建临时文件后失败并以非零状态退出
- **THEN** trap 删除它们，且退出状态保持非零
