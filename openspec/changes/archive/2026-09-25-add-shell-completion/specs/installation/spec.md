# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

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
