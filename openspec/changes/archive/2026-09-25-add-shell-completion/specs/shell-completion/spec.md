# Spec Delta

## Purpose

定义 `dshctl` 面向用户的命令面：公开命令集由单一命令表驱动帮助文本、子命令分派与 shell 补全，并提供一个可独立使用的 bash 补全脚本。

## ADDED Requirements

### Requirement: 公开命令面由单一命令表定义

内嵌的 `dshctl` SHALL 用一份命令表定义公开命令集，每条命令包含名称、所属分组、帮助左列与描述、接受的选项、二级子命令与位置参数类型。帮助文本、公开子命令的分派与补全脚本 SHALL 都从该表产生。表中不存在的命令 SHALL 被报告为未知命令、向标准错误打印用法并退出 2。

隐藏命令 `_render-config`、`_render-unit`、`_enable`、`_linger` SHALL 不出现在命令表、帮助文本与补全候选中，同时 SHALL 仍可被 `install.sh` 以原有名称调用。

#### Scenario: 帮助与分派覆盖同一命令集

- **WHEN** 运行 `dshctl --help`
- **THEN** 输出列出命令表中每条公开命令的帮助行
- **AND** 每条列出的命令都能被 `dshctl <命令>` 分派到其实现，而不是报告未知命令

#### Scenario: 未知命令

- **WHEN** 运行 `dshctl nope`
- **THEN** 它向标准错误打印指明未知命令的报告与用法文本
- **AND** 退出码为 2

#### Scenario: 隐藏命令不暴露但可用

- **WHEN** 运行 `dshctl --help`
- **THEN** 输出不包含 `_render-config`、`_render-unit`、`_enable`、`_linger`
- **AND** `dshctl _render-unit` 仍成功执行并把单元内容写入标准输出

#### Scenario: 帮助描述的列位置

- **WHEN** 运行 `dshctl --help`
- **THEN** 每条帮助行的描述从第 33 个终端列开始
- **AND** 当左列（命令与参数）加两个前导空格已达到或超过该列时，描述另起一行且仍从第 33 列开始

### Requirement: completion 子命令输出补全脚本

`dshctl completion [shell]` SHALL 把补全脚本写入标准输出并以退出码 0 结束；省略 shell 参数时 SHALL 等价于 `bash`。对不支持的 shell，它 SHALL 向标准错误报告当前仅支持 bash、以非 0 退出，且不向标准输出写入任何内容。

输出的脚本 SHALL 是确定性的：同一份 `dshctl` 在相同环境下重复生成 SHALL 逐字节一致。该脚本 SHALL 在调用方 shell 启用了 `set -u` 时仍可用于补全，并且 SHALL 不要求系统安装 `bash-completion` 软件包。

#### Scenario: 默认 shell

- **WHEN** 分别运行 `dshctl completion` 与 `dshctl completion bash`
- **THEN** 两次的标准输出逐字节一致

#### Scenario: 输出确定性

- **WHEN** 在同一环境下连续运行两次 `dshctl completion bash`
- **THEN** 两次的标准输出逐字节一致

#### Scenario: set -u 下不中断

- **WHEN** 在启用了 `set -u` 的 bash 中 source 该脚本，并在缺少后续词元的位置触发补全
- **THEN** 不出现 `unbound variable` 之类的错误信息

#### Scenario: 不依赖 bash-completion 软件包

- **WHEN** 在未加载 `_init_completion` 的 bash 中 source 该脚本并触发顶层补全
- **THEN** 仍给出命令表中的公开命令候选

#### Scenario: 不支持的 shell

- **WHEN** 运行 `dshctl completion zsh`
- **THEN** 标准错误说明当前只支持 bash
- **AND** 退出码非 0 且标准输出为空

### Requirement: 补全候选契约

补全脚本被 source 后，补全 SHALL 满足：顶层位置给出命令表中的公开命令；二级位置给出该命令的子命令（`config` → `edit`，`plugins` → `list`、`ls`、`reset`）；当前词以 `-` 开头时给出该命令接受的选项；`import` 的位置参数与 `export -o|--output` 的取值给出文件路径候选。任何情况下 SHALL 不给出隐藏命令，也不给出该命令未接受的选项；没有候选时 SHALL 安静结束，不向终端输出错误。

#### Scenario: 顶层命令候选

- **WHEN** 对 `dshctl <TAB>` 触发补全
- **THEN** 候选包含命令表中的全部公开命令
- **AND** 候选不包含 `_render-config`、`_render-unit`、`_enable`、`_linger`

#### Scenario: 二级子命令候选

- **WHEN** 在 `dshctl plugins <TAB>` 与 `dshctl config <TAB>` 处触发补全
- **THEN** 候选分别为 `list`、`ls`、`reset` 与 `edit`

#### Scenario: 选项候选

- **WHEN** 在 `dshctl upgrade -<TAB>` 处触发补全
- **THEN** 候选包含 `--check`、`--list`、`--no-restart`、`--yes`
- **AND** 候选不包含 `upgrade` 未接受的选项

#### Scenario: 文件路径候选

- **WHEN** 在 `dshctl import <TAB>` 或 `dshctl export -o <TAB>` 处触发补全
- **THEN** 候选来自当前位置的文件系统条目

#### Scenario: 无候选时安静结束

- **WHEN** 在 `dshctl <未知命令> <TAB>` 处触发补全
- **THEN** 候选为空且不产生错误输出
