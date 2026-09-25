# Proposal

## Why

`dshctl` 已有 18 个公开子命令与几十个选项，用户只能靠记忆敲写，发现途径仅有 README 与 `--help`；补全是这类命令行工具的标配。

更根本的问题是：公开命令集当前存在两处独立手写副本（`main()` 的分派 `case`、`usage()` 的帮助文本），任何一处漏改都会造成"帮助里有、敲下去报未知命令"，而补全功能会引入第三处。本变更把命令面收敛为单一来源，顺带消除这一类漂移。

## What Changes

- 在内嵌 dshctl 中引入命令表 `DSHCTL_COMMANDS`（每条命令：名称、分组、帮助左列与描述、选项、二级子命令、位置参数类型），作为**公开命令面的唯一来源**：
  - 由它渲染 `usage()` 帮助文本；
  - 由它生成 bash 补全脚本；
  - 由它校验并分派公开子命令（`cmd_${name//-/_}` + `declare -F` 守卫），`main()` 的 `case` 只保留 `help|-h|--help`、`-V|--version`、四个隐藏命令与兜底。
- 新增 `dshctl completion [bash]` 子命令：把补全脚本打印到 stdout。**不**新增 `completion install` / `completion uninstall` 动词。
- `install.sh` 默认部署补全：把 `dshctl completion bash` 的输出落盘到 `~/.local/share/bash-completion/completions/dshctl`（复用 `write_file` 的 `cmp -s` 幂等与原子替换），并在现有的 `# >>> dsh-service >>>` 标记块中追加一行 `[ -r <补全文件> ] && . <补全文件>`。新增 `--no-completion` 退订补全文件；`--no-rc` 仍只管辖 rc 代码块，两者互不替代。
- 补全行为：公开子命令、二级子命令（`plugins list|ls|reset`、`config edit`）、各命令选项、`import`/`export -o` 的文件路径；隐藏命令 `_render-config`/`_render-unit`/`_enable`/`_linger` 永不出现；TAB 时不发起网络请求。
- 卸载：补全脚本文件随本地入口点一起在默认卸载中删除；块内 source 行随 `--purge` 移除（该行有 `[ -r ... ]` 守卫，残留时天然无害）。
- 用户可见的排版变化：`usage()` 改由命令表渲染后，`upgrade-node [<主版本>]` 与 `run [-- 参数...]` 两条帮助行的描述改为另起一行、缩进到第 33 列（`upgrade`、`plugins reset`、`export`、`import`、`uninstall` 五条本来已是这种排版）。
- 测试与文档：`tests/run.sh` 新增补全生成与补全行为的离线覆盖、命令表一致性守卫；`README.md` 更新安装选项、文件位置、命令表并新增补全章节。

## 非目标（Non-goals）

- **不为其它 shell 生成补全**：只做 bash，不写 `~/.zshrc` / fish / PowerShell 配置。
- **不补全上游命令**：不为 `dsh` 自身的子命令生成补全，也不补 `dshctl run --` 之后的 dsh 参数。
- **TAB 时不联网**：不查询 npm registry 的版本列表；`upgrade` 只静态提示 `next`/`latest`（注释与文档写明这只是提示，任意 dist-tag 仍可用）。
- **不在 dshctl 中提供 `completion install` / `completion uninstall`**：部署与卸载统一归 `install.sh`，避免两个写者争抢同一个 `.bashrc` 与标记块。
- **不把三份散文式子帮助改为表渲染**：`plugins_usage` / `export_usage` / `import_usage` 保持手写，改用测试守卫其选项与命令表一致。
- **不引入多 shell 的 generator / factory 抽象**，也**不新增任何配置键或环境变量覆盖**。

## Capabilities

### New Capabilities

- `shell-completion`: dshctl 的公开命令面由单一命令表定义（帮助、分派、补全同源）；`dshctl completion bash` 输出补全脚本；补全对公开子命令、二级子命令、选项与文件路径的行为契约；隐藏命令不被暴露。

### Modified Capabilities

- `installation`: 「CLI 选项契约与校验」增加 `--no-completion`；「Shell rc 代码块管理」增加对补全文件的 source 行；补全脚本作为安装产物与本地入口点同级落盘。
- `maintenance`: 「卸载范围」把补全脚本文件纳入默认卸载，并覆盖 purge 时随同一对标记的 rc 代码块一并移除补全 source 行（块移除本身的行为不变）。
- `offline-tests`: 新增补全脚本生成与补全行为的离线覆盖、命令表一致性守卫（表↔分派、表↔选项解析、子帮助 ⊆ 表、隐藏命令不泄漏），以及补全文件的落盘 / 幂等 / 退订 / 卸载覆盖。

## Impact

**受影响的 dshctl 子命令**

- 新增 `completion [bash]`。
- `help` / `-h` / `--help` 的输出改由命令表渲染；其中两条帮助行的描述换行位置变化（见上）。
- `main()` 分派改为表驱动；未收录的命令仍报告"未知命令"并以退出码 2 打印用法。
- `uninstall` 增加删除补全脚本文件。
- 其余子命令的参数与输出不变。

**受影响的 install.sh 步骤**

- 新增 `--no-completion` 选项（参数解析、`--help` 用法文本、安装摘要）。
- 步骤 5（用户级入口点）附近：在 dshctl 就位后调用 `dshctl completion bash` 落盘补全脚本。
- 步骤 6（shell 配置）：标记块内容增加一行 source。
- 卸载路径：删除补全脚本文件。
- 安装摘要与"下一步"提示：说明补全已就绪、如何重载。

**新增文件与配置**

- 新增文件：`~/.local/share/bash-completion/completions/dshctl`（遵循 `XDG_DATA_HOME`；文件名与命令名一致，是 bash-completion 的用户级约定目录）。
- 无新增配置键、无新增环境变量覆盖；`~/.config/dsh-service/config` 的既有取值不受影响。

**兼容性影响**

- **重跑幂等**：补全脚本内容来自 dshctl 的确定性输出，`write_file` 在内容相同时报告"未变化"且不重写；rc 标记块仍按生成内容逐字节比对，因此首次升级会因新增 source 行重写一次 `~/.bashrc`，其后保持稳定。
- **既有配置取值**：不变；`--no-completion` 是安装期开关，不写入配置文件，也不改变任何 `DSH_SERVICE_*` 语义。
- **内嵌 dshctl 单一来源约定**：命令表与补全生成器都留在 `install.sh` 的 heredoc 内嵌段内（`--print-dshctl` 仍与源码内嵌段逐字节一致），安装器只通过调用 `dshctl completion bash` 取内容，不复制命令表，因此不存在两份命令表。
- **未知命令与隐藏命令**：`dshctl <未知命令>` 仍向标准错误报告并退出 2 并打印用法；四个隐藏命令仍可被 `install.sh` 以原名称调用，只是不出现在帮助与补全中。
