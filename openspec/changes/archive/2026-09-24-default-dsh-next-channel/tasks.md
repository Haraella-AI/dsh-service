# Tasks

## 1. 安装器默认通道与保留规则

- [x] 1.1 归档前置变更：确认 `simplify-toolchain-and-upgrade-ux` 已实现并先归档它；验证 `openspec list` 中不再出现该变更、`openspec/specs/installation/spec.md` 已是 Node 24 且无构建工具链需求。
- [x] 1.2 在 `install.sh` 中引入默认通道常量（`next`）并据此改写 `DSH_VERSION="${OPT_DSH_VERSION:-...}"`，同步头部注释与 `--help` 中的 `--dsh-version` 文案（`--pnpm-version` 保持 `latest`）；验证 `bash install.sh --help` 把 `next` 记为 dsh 默认值、把 `latest` 记为 pnpm 默认值，且 `bash -n install.sh` 通过。
- [x] 1.3 在 `ensure_dsh` 中加入保留规则：`OPT_DSH_VERSION` 为空、`FORCE != 1` 且检测到已安装 dsh 时跳过 npm 安装并报告所保留的版本与切换方式（`--dsh-version next` / `dshctl upgrade`）；未检测到已安装 dsh 时才安装默认通道；验证在已有 dsh 的临时 home 中重跑 `install.sh` 不产生 `npm install @deepseek-ai/dsh` 调用且输出保留提示。
- [x] 1.4 泛化 `ensure_dsh` 的 dist-tag 解析：以 spec 形态分流（`v?<数字>` 直接去前缀、不访问网络），否则查询 `npm view @deepseek-ai/dsh dist-tags --json` 找同名 tag；解析失败时告警并回退字面 tag；验证 `--dsh-version next` 在已安装 next 指向版本时被判定为「已安装」而跳过安装，`--dsh-version 0.1.0` 不产生任何 registry 查询。
- [x] 1.5 扩展 `tests/run.sh` 的 npm 桩与断言：桩把 `@next` 之类目标按 `dist-tags` 映射为具体版本后再写 `VERSION`；dry-run 断言改为 `[dry-run] npm install -g @deepseek-ai/dsh@next`；新增「新装默认通道」「重跑保留已安装 dsh」「显式 `--dsh-version next` 幂等」「`--force` 按默认通道重装」场景；验证 `bash tests/run.sh` 报告零失败。
- [x] 1.6 更新 `README.md`：安装步骤表第 3 步改为默认通道 `next`（并说明已有安装重跑会保留版本）、`install.sh` 选项参考中 `--dsh-version` 的默认值改为 `next`、补充切回 `latest` 的写法；验证 README 中不再出现「默认 latest」的 dsh 默认值表述，且示例或说明与 `--help` 一致。

## 2. 内嵌 dshctl 的默认通道

- [x] 2.1 在 `dshctl` 中引入默认通道常量（`next`）并把 `cmd_upgrade` 的 `local spec='latest'` 改由它派生；用 `spec_explicit` 标志记录用户是否显式给出目标，替换装前校验处的 `[ "$spec" != latest ]` 判定；验证 `dshctl upgrade` 解析 `dist-tags` 中 `next` 的版本、`dshctl upgrade latest` 解析 `latest`、显式版本仍原样使用。
- [x] 2.2 泛化 `resolve_target`：具体版本形态直接去 `v` 前缀返回，dist-tag 形态查询 `dist-tags` 解析为具体版本，解析失败保持「无法解析目标版本」并以 1 退出；同时把 `upgrade_target_not_found_hint` 的措辞改为报告默认通道当前版本；验证 registry 不可达时显式版本路径仍不额外查询、不改变原有告警与非回滚行为。
- [x] 2.3 修改 `cmd_upgrade_node`：保留「必须已安装 dsh」的前置检查，但重装目标改为默认通道解析出的版本；验证在桩环境下 `upgrade-node` 调用的是 `npm install -g @deepseek-ai/dsh@<next 版本>` 而不是升级前的版本。
- [x] 2.4 更新 `dshctl` 用法文本（`upgrade` 与 `upgrade-node` 的目标说明、默认通道）；验证 `dshctl --help` 指明省略目标时使用 `next`，且提示文本与 README 一致。
- [x] 2.5 扩展 `tests/run.sh` 的 dshctl 分节：`upgrade --check` 与 `upgrade` 省略目标时以 `next` 为目标、`upgrade latest` 仍解析 `latest`、dist-tag 解析出的版本触发「无需升级」、不存在的版本提示默认通道版本、`upgrade-node` 按默认通道重装；验证 `bash tests/run.sh` 报告零失败。
- [x] 2.6 更新 `README.md` 的升级与回滚、故障排查章节：`dshctl upgrade` 默认目标改为默认通道 `next`，说明 `dshctl upgrade latest` / 指定版本仍然可用，并记录 `upgrade-node` 现在会把 dsh 带到默认通道；验证文档中的命令与 `dshctl` 实际输出一致。

## 3. 集成验证

- [x] 3.1 在最终代码树上端到端运行 `bash tests/run.sh`，确认通过/失败摘要为零失败。
- [x] 3.2 在干净的临时 home 中运行 `bash install.sh --dry-run`，确认计划中的 dsh 安装动作为 `@next`、pnpm 仍为 `@latest`，且不存在任何写入。
- [x] 3.3 确认内嵌 `dshctl` 仍是唯一来源：`bash install.sh --print-dshctl` 与 heredoc 块逐字节一致（测试套件的字节一致性断言通过）。
- [x] 3.4 运行 `openspec validate "default-dsh-next-channel"` 与 `openspec validate --specs`，确认二者都报告无失败。
