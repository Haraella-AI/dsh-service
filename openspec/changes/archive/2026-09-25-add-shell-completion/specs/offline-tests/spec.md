# Spec Delta

## ADDED Requirements

### Requirement: 补全生成与行为覆盖

该套件 SHALL 在完全离线的沙箱中断言补全脚本的生成与补全行为：`dshctl completion bash` 的输出非空、通过 `bash -n` 语法检查、并包含把补全函数注册到 `dshctl` 的注册语句；把该输出 source 进一个未加载 `bash-completion` 的 bash 之后，在顶层、二级子命令、选项与文件路径位置分别给出预期候选；隐藏命令不出现在候选中；生成脚本在调用方启用了 `set -u` 时触发补全也不产生 `unbound variable` 错误。

#### Scenario: 脚本语法与注册语句

- **WHEN** 在沙箱中运行 `dshctl completion bash`
- **THEN** 其输出通过 `bash -n`
- **AND** 输出包含把补全函数注册到 `dshctl` 的 `complete` 语句

#### Scenario: 顶层与二级子命令候选

- **WHEN** 在已 source 该脚本、未加载 `bash-completion` 的 bash 中，把 `COMP_WORDS`/`COMP_CWORD` 置为顶层位置与二级位置并调用补全函数
- **THEN** `COMPREPLY` 分别包含命令表中的公开命令，以及 `plugins`、`config` 的子命令
- **AND** 候选不含 `_render-config`、`_render-unit`、`_enable`、`_linger`

#### Scenario: 选项与文件路径候选

- **WHEN** 把 `COMP_WORDS`/`COMP_CWORD` 置为 `dshctl upgrade -` 与 `dshctl import <路径前缀>` 并调用补全函数
- **THEN** 前者给出 `upgrade` 接受的选项候选
- **AND** 后者给出与路径前缀匹配的文件系统条目

#### Scenario: set -u 安全

- **WHEN** 在启用了 `set -u` 的 bash 中 source 该脚本并触发补全
- **THEN** 不产生 `unbound variable` 错误

### Requirement: 命令表一致性守卫

该套件 SHALL 断言公开命令面在源码中保持一致：命令表中每条命令都有对应的实现且能被分派，表中不存在的命令以退出码 2 报告未知命令；表中每个选项都能在对应命令的参数解析中找到，源码中为各命令解析的选项也都出现在表中；主帮助与三份子命令帮助（`plugins`、`export`、`import`）中出现的选项都出现在表中；四个隐藏命令不出现在命令表、帮助文本与补全输出中。

#### Scenario: 表与分派一致

- **WHEN** 该套件遍历命令表中的每条命令
- **THEN** 每条命令都能被分派执行而不是报告未知命令
- **AND** 表中未收录的命令名以退出码 2 失败并打印用法

#### Scenario: 选项双向一致

- **WHEN** 该套件比对命令表的选项与源码中各命令参数解析的选项
- **THEN** 表里的每个选项都能在对应命令的解析代码中找到
- **AND** 解析代码里的每个选项都出现在表中

#### Scenario: 帮助文本不超出表

- **WHEN** 该套件提取主帮助与三份子命令帮助中出现的选项
- **THEN** 这些选项都出现在命令表中

#### Scenario: 隐藏命令不泄漏

- **WHEN** 该套件检查命令表、`dshctl --help` 输出与补全脚本输出
- **THEN** 三者都不包含 `_render-config`、`_render-unit`、`_enable`、`_linger`

### Requirement: 补全部署与卸载覆盖

该套件 SHALL 离线断言补全脚本的安装生命周期：全新安装后文件存在于用户数据目录且内容等于安装后 dshctl 的 `completion bash` 输出；以相同选项第二次安装保持该文件逐字节不变并报告未变化；`--no-completion` 不创建该文件且 rc 代码块不含补全 source 行；`--no-rc` 仍创建该文件但不修改 `~/.bashrc`；`--dry-run` 报告将写入的路径而不创建文件；默认卸载删除该文件；`--purge` 移除含补全 source 行的整个 rc 代码块。

#### Scenario: 全新安装与重跑幂等

- **WHEN** 安装器在全新 home 中运行两次
- **THEN** 两次运行后补全脚本文件存在于用户数据目录
- **AND** 第二次运行报告该文件未变化，且其哈希值与第一次相同

#### Scenario: 退订补全

- **WHEN** 安装器以 `--no-completion` 运行
- **THEN** 补全脚本文件不存在
- **AND** `~/.bashrc` 的 dsh-service 代码块不含补全 source 行

#### Scenario: 跳过 rc 仍安装补全

- **WHEN** 安装器以 `--no-rc` 运行
- **THEN** 补全脚本文件存在
- **AND** `~/.bashrc` 未被修改

#### Scenario: 试运行不写补全脚本

- **WHEN** 安装器以 `--dry-run` 运行
- **THEN** 输出报告将要写入的补全脚本路径
- **AND** 该文件未被创建

#### Scenario: 卸载移除补全脚本

- **WHEN** 以 `--yes` 运行 `dshctl uninstall`，随后再以 `--purge --yes` 运行
- **THEN** 第一次运行后补全脚本文件已不存在，而 rc 代码块仍存在
- **AND** 第二次运行后 rc 代码块连同补全 source 行一起被移除
