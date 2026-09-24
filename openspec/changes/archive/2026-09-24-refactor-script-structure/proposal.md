# Proposal

## Why

`install.sh` 已达 3219 行，呈两个叠加的结构问题：内嵌 dshctl 的 heredoc（L29-2183）把 2150 行放在文件最前，安装器主体被挤到后面且被劈成两半——L2288-2441 的配置/校验/镜像源是顶层散装语句，中间隔着约 800 行函数定义，L3137-3219 的执行序列与汇总又在文件末尾。读者要理解一次安装的流程，必须在三处之间来回跳。

同时，两段不能互相 `source` 的脚本各自维护一份「共享内核」，其中 `load_nvm` 的同名函数在两边语义不同（dshctl：`try_load_nvm` 是详细版、`load_nvm` 是薄包装；install.sh：`load_nvm` 是详细版、安静版叫 `load_nvm_soft`），是读者最容易误读的点。个别诊断提示也不对称——npm 安装失败的补救建议不区分国内镜像/官方源，而紧邻的 Node 下载失败提示已经做了区分。

现在做这次重构，是因为功能面刚刚稳定（最近两次归档改动刚落地），行为回归风险最低，且离线测试套件已有 285 条断言可以充当安全网。

## What Changes

- **常量提取**：在两段脚本头部各建一个「常量区」，收纳版本号、内置默认值（端口/主版本/通道/镜像 URL）、systemd 单元策略（`RestartSec` 等原本是 `render_unit` 里的裸字面量）与零散的魔法数字（`--wait 30`、重试次数与间隔）。
- **install.sh 主体函数化**：把顶层散装语句收进 `setup_colors` / `parse_args` / `init_config` / `validate_options` / `init_derived_values` / `init_mirrors` / `print_summary` / `main`，使顶层只剩函数定义与末尾一次 `main "$@"`。
- **内嵌 dshctl 拆分**：`cmd_import`（256 行）拆成 6 个、`cmd_export`（148 行）拆成 3 个、`cmd_doctor`（134 行）拆成 12 个 `doctor_check_*` 加编排循环、`cmd_upgrade`（107 行）与 `cmd_plugins_reset`（89 行）各拆 2 个；`render_unit` 的单元模板与 `ensure_shell_rc` 的 rc 代码块提为常量。
- **镜像函数统一**：两段的 nvm 加载统一为 `try_load_nvm`（详细版）+ `load_nvm`（薄包装）+ `load_nvm_soft`（安静版），双方都保留 `unset PREFIX`。
- **清理函数统一**：两段的 `cleanup_tmp` 统一使用 `rm -rf`（注册项可能含 `mktemp -d` 目录）。
- **诊断提示一致性（力度 1）**：npm 安装失败的补救建议按镜像模式区分；缺少「下一步」的报错补全为「现象 + 原因 + 下一步」三段式。
- **不改变**：CLI 选项与退出码、配置键与环境变量名与优先级、systemd 单元的渲染结果（提取常量但取值不变）、用户可见文案的既有措辞。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无。这是纯结构重构：所有外部可观察契约（选项、退出码、配置文件、环境变量优先级、单元文件内容、命令输出语义）均保持不变。按 spec-driven schema 的规定，以 `.openspec.yaml` 的 `skip_specs: true` 显式声明不改动任何规格，而不是为满足校验虚构一条需求。

一处需要说明的边界：诊断提示的措辞与建议确实会变（npm 失败时按镜像模式给出不同建议，部分报错补上「下一步」），但现有规格只约束「SHALL 报告失败/给出提示」这一语义，从未把具体文案写成契约，因此这是实现层的可读性改进，不是需求变更。诊断输出不属于配置键或环境变量覆盖范围。

## Impact

- `install.sh`：文件整体重排与拆分；内嵌 dshctl 段（L30-2178）与安装器主体（L2185-3219）均被改写。`--print-dshctl` 仍逐字节输出内嵌段，内嵌段仍是 dshctl 的唯一来源。
- `tests/run.sh`：作为回归安全网运行；预期断言无需改动，若诊断断言咬到被调整的文案则同步更新。
- `README.md`：对外契约未变，仅需在描述内嵌 dshctl 的段落补充常量区与文件布局说明。
- 兼容性：重跑幂等不变——已完成的步骤仍被跳过，既有配置文件取值与用户对单元的修改仍被保留；临时文件仍由单一 `EXIT` trap 在每条退出路径清理（`rm -rf` 覆盖文件与目录）。
