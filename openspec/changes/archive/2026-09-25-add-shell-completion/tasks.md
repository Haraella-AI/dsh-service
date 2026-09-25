# Tasks

## 1. 命令表、帮助渲染与分派（内嵌 dshctl）

- [x] 1.1 在内嵌 dshctl 中定义 `DSHCTL_COMMANDS` 命令表（`name~group~left~desc~flags~subs~positional~subflags`）与解析函数，录入全部 19 条公开命令及其选项；验证：`bash install.sh --print-dshctl | bash -n` 通过，且 `dshctl --help` 仍列出全部 19 条公开命令
- [x] 1.2 将 `usage()` 改为从命令表渲染，实现第 33 列规则（左列纯 ASCII 且 `2 + len < 33` 时描述同行，否则另起一行）；验证：渲染结果与改造前的帮助文本逐行 `diff`，差异只有新增的 `completion` 行，以及 `upgrade-node [<主版本>]`、`run [-- 参数...]` 两行描述改为另起一行
- [x] 1.3 将 `main()` 收敛为表驱动分派（`cmd_${name//-/_}` + `declare -F` 守卫），只保留 `help|-h|--help`、`-V|--version`、四个隐藏命令与兜底；验证：`dshctl nope` 打印用法并退出 2，19 条公开命令全部可被分派，`dshctl _render-unit` 与 `dshctl _enable` 仍以原名可用
- [x] 1.4 在 `tests/run.sh` 新增「命令表一致性守卫」section（第 33 节）：表↔分派（逐条命令可执行且非未知命令）、表↔选项解析双向比对（反向只统计臂形解析行）、三份子帮助中的选项 ⊆ 表、四个隐藏命令不出现在表/帮助/补全输出；验证：`bash tests/run.sh` 中该 section 全绿，且把 `--fix` 从表中删掉后反向守卫报漏 `--fix`

## 2. 补全脚本生成（内嵌 dshctl）

- [x] 2.1 新增 `dshctl completion [shell]`：渲染 bash 补全脚本（顶层命令、二级子命令、按命令的选项、`import` 与 `export -o|--output` 的 `compgen -f` 路径分支、末尾 `complete -F` 注册），省略参数等价于 `bash`，脚本对 `COMP_WORDS` 的索引一律使用防御性展开；验证：`bash -n` 通过，在未加载 `bash-completion` 的 bash 中 source 后分别断言顶层/`plugins`/`upgrade -`/`import` 的 `COMPREPLY`
- [x] 2.2 实现确定性输出与不支持 shell 的错误处理；验证：连续两次 `dshctl completion bash` 输出逐字节一致，`dshctl completion zsh` 退出 2、标准错误说明仅支持 bash、标准输出为空
- [x] 2.3 在 `tests/run.sh` 新增「补全生成与行为覆盖」section（第 34 节）：输出非空且含注册语句、`bash -n` 通过、顶层与二级候选、选项与路径候选、隐藏命令不出现、`set -u` 下触发补全返回全部命令；验证：`bash tests/run.sh` 中该 section 全绿
- [x] 2.4 更新 `README.md`：在 4.1 命令表加入 `dshctl completion [bash]`，新增 4.4「命令补全」小节说明补全范围、只支持 bash、手动 source 一行即可启用，并写明 `upgrade` 的位置候选只是提示、`upgrade --list` 才是权威来源；验证：按 README 给出的路径 source 安装后的补全脚本可获得补全（第 35 节与端到端检查均覆盖）

## 3. 安装器供给补全（install.sh 主体）

- [x] 3.1 在 install.sh 中新增 `--no-completion` 开关（参数解析、`--help` 用法文本、安装摘要与下一步提示）；验证：`install.sh --help` 列出 `--no-completion`，`install.sh --dry-run --no-completion` 只报告跳过、不报告补全脚本路径
- [x] 3.2 在 dshctl 就位后调用 `dshctl completion bash` 并用 `write_file` 落盘到 `${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/dshctl`；验证：安装后该文件内容等于安装后 dshctl 的 `completion bash` 输出，第二次相同安装报告该文件未变化且哈希不变
- [x] 3.3 在 `rc_block_content` 中为标记块新增一行 `[ -r <补全脚本> ] && . <补全脚本>`，受 `--no-completion` 与 `--no-rc` 各自独立管辖；验证：默认安装后块内含该守卫行，`--no-completion` 时既不写文件也不加行，`--no-rc` 时写入文件但不修改 `~/.bashrc`
- [x] 3.4 在 `cmd_uninstall` 中删除补全脚本文件（与 `~/.local/bin/dshctl` 同级），source 行随 `--purge` 的块移除一并清理；验证：`uninstall --yes` 后补全文件不存在而 rc 块保留，`uninstall --purge --yes` 后含 source 行的块消失
- [x] 3.5 在 `tests/run.sh` 新增「补全部署与卸载覆盖」section（第 35 节）：全新安装文件存在且内容相符、重跑幂等、`--no-completion` 不创建文件、`--no-rc` 创建文件但不改 rc、`--dry-run` 只报告路径、默认卸载删文件、`--purge` 删块；验证：`bash tests/run.sh` 中该 section 全绿
- [x] 3.6 更新 `README.md`：3.2 安装选项加入 `--no-completion` 并说明与 `--no-rc` 的区别、3.1 步骤表补充补全脚本、4.2 文件位置加入补全脚本路径、6.4 卸载说明补全文件的清理时机；验证：README 列出的选项与文件路径和 `install.sh --help`、`dshctl --help` 的输出一致（README 未列 `--print-dshctl` 属既有情况，本次不改）

## 4. 集成验收

- [x] 4.1 运行完整离线套件并报告结果；验证：`bash tests/run.sh` 以 0 退出，报告通过 402 项、失败 0 项
- [x] 4.2 端到端验证补全在真实 shell 中可用；验证：在启用 `set -u` 且未加载 `bash-completion` 的 bash 中 source 安装后的 `~/.bashrc`，顶层/二级子命令/选项/路径四类补全均给出预期候选，且重跑 `install.sh` 后补全脚本哈希不变
- [x] 4.3 验证内嵌 dshctl 单一来源约束未被破坏；验证：`bash install.sh --print-dshctl` 与源码内嵌段逐字节一致（`tests/run.sh` 第 18 节），`bash -n` 对 install.sh 与导出物均通过
- [x] 4.4 验证版本号三处一致；验证：`INSTALLER_VERSION`、内嵌 `DSHCTL_VERSION` 与 README 顶部版本行同为 `0.1.0`，`scripts/bump-version.sh --check` 通过
