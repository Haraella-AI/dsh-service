# Design

## Context

动机见 proposal.md；本文件只记录塑造实现方式的现状约束与实测证据。

**现状：公开命令面有三处手写副本，且没有任何"命令定义"这样的数据结构。**

```
install.sh
 |-- L235..276   usage()          手写 heredoc：3 个分组 + 22 条帮助行，描述统一从第 33 显示列开始
 |-- L2490..2510 main()           手写 case：22 个臂（18 公开 + 4 隐藏）
 |-- L1676       plugins_usage()  散文化子帮助
 |-- L1849       export_usage()   散文化子帮助（选项 + 「归档内容：」段落）
 |-- L2065       import_usage()   散文化子帮助
 |-- L3315       install_tools()  写 ~/.local/bin/dshctl（write_file：cmp -s 幂等 + 原子 mv）
 |-- L3330       rc_block_content() 生成 # >>> dsh-service >>> 标记块
 +-- L2420       cmd_uninstall()  删 unit / dsh / dshctl；--purge 才 remove_rc_block

tests/run.sh  32 个 section，全离线（桩 systemd/npm/node + 临时 HOME）
  section 1   bash -n 语法检查（install.sh 与 --print-dshctl 导出物）
  section 4   幂等重跑：文件/dshctl 哈希比对
  section 18  --print-dshctl 与源码内嵌段逐字节一致
```

**约束**：无编译步骤、无第三方运行时依赖（`coreutils / systemd / journalctl`）；内嵌 dshctl 是唯一来源；幂等是第一约束；行为改动必须同时扩展 `tests/run.sh` 与 `README.md`。

**参考实现实测（OpenSpec 1.13.2，`~/.local/share/bash-completion/completions/openspec`）**：

| 观察 | 证据 | 对本设计的影响 |
|---|---|---|
| registry 不驱动 `--help` | `COMMAND_REGISTRY`（22 顶层条目）与 commander 的 `.command()/.description()` 是两份手写定义 | 无现成范本可抄；表驱动 usage 比参考实现更彻底 |
| 补全脚本用 `complete -F` + 独立文件 + rc 标记块 | `bash-installer.js`：路径 `~/.local/share/bash-completion/completions/<cmd>`，内容相同即不重写，`# OPENSPEC:START/END` 块 source 整个目录 | 抄形态，但复用 dshctl 已有的标记块，不引入第二对标记 |
| 动态候选靠反调 CLI | 生成脚本调 `openspec __complete <type>`，Node 冷启动约 50–100ms | dshctl 无廉价动态候选，整层砍掉 |
| 生成脚本在 `set -u` 下崩溃 | 实测 `words[2]: unbound variable`（生成脚本第 23 行） | 我们的生成脚本必须 `set -u` 安全，并为此写测试 |
| bash 冷启动成本 | 实测 20× 空 `bash -c ':'` = 0.04s（2ms/次）；20× `dshctl -V` = 0.08s（4ms/次）；`dshctl version` = 0.12s 是它 fork 了 node/npm | "每次 TAB 起进程"不构成否决理由，但静态表仍是更优 UX |

**实测：离线补全测试手法可行**，且不依赖 `bash-completion` 包（非交互 `bash -c` 中 `_init_completion` 不存在，脚本走手动回退）：

```
$ bash -c '. <生成的脚本>; COMP_WORDS=(openspec co); COMP_CWORD=1; _openspec_completion; echo "${COMPREPLY[*]}"'
context completion config
```

## Goals / Non-Goals

**Goals**

- 公开命令集只有一个定义来源，帮助文本、分派与补全都由它产生；新增或删除命令时不需要同步改三处。
- 补全在**不安装 `bash-completion` 软件包**、**不联网**、**用户 shell 开启 `set -u`** 的环境下都可用。
- 生成物可离线、确定性地验证：补全行为直接断言 `COMPREPLY`，不需要交互式 TTY。
- 复用已有的幂等与卸载机制，不引入新的配置键或环境变量。

**Non-Goals（设计层面）**

- 不做多 shell 的 generator/factory 抽象，不为 zsh/fish/PowerShell 预留接口。
- 不引入构建期生成步骤（无 `scripts/gen-*.sh`）：所有渲染都在运行时完成，保持"单文件、无编译步骤"。
- 不在纯 bash 中实现 CJK 显示宽度计算。
- 不把三份散文化子帮助改为表渲染；它们与表的一致性靠测试守卫。
- 不改变 `~/.config/dsh-service/config` 的任何键，不为补全增加 `DSH_SERVICE_*` 覆盖。

## Decisions

### D1. 命令表的形态：运行时渲染，放在内嵌 dshctl 内

表以每行一条命令的字符串数组存在（`name|group|left|desc|flags|subcommands|positional`），在 dshctl 启动时读入。`usage()` 由它渲染，补全脚本由它生成，分派由它校验。

- **为什么不用构建期生成**：项目约定"无编译步骤"，且内嵌 dshctl 必须自包含——构建期生成会引入一个必须先跑、且结果必须与源码同步的中间物，反而增加漂移面。
- **为什么初始化在启动时**：dshctl 每次调用都要读表，但解析 22 行字符串的代价远小于它已有的配置加载（实测 `-V` 路径约 4ms）。
- **备选**：把表写成 `pkg|func|...` 的 TSV heredoc，用 `while IFS='|' read` 解析。被否：heredoc 会与 `set -Eeuo pipefail` 的子 shell 语义纠缠，而数组解析更直白且无子 shell。

### D2. 分派由表驱动，`main()` 只保留特殊臂

```
main()
  help|-h|--help   -> usage
  -V|--version     -> 版本
  _render-config|_render-unit|_enable|_linger -> 原实现（不进表）
  *  -> fn="cmd_${cmd//-/_}"; 表内 && declare -F "$fn" -> "$fn" "$@"
       否则 err 未知命令 + usage >&2 + exit 2
```

- 18 个公开命令的函数名**已全部**满足 `cmd_<name，短横线换下划线>`（含 `cmd_upgrade_node`），所以不需要映射表。
- `declare -F` 守卫是关键：否则表里写错函数名会以 bash 的 127「command not found」泄漏出去，而契约要求退出 2 + 用法。
- **备选**：保留手写 `case` + 一条"表↔case 臂"测试。被否：用户明确选择让表成为唯一来源；且该测试要解析 shell 源码，脆弱度高于 `declare -F`。

### D3. 补全机制：`complete -F` + 独立文件 + 现有标记块中的一行 source

```
~/.local/share/bash-completion/completions/dshctl   <- dshctl completion bash 的输出
~/.bashrc  # >>> dsh-service >>> 块内新增一行：
  [ -r "<该路径>" ] && . "<该路径>"
```

- **为什么用 `-F` 而不是 `complete -C 'dshctl _complete'`**：`-C` 的 `-o filenames` / `-o nospace` 是静态注册的，无法按位置动态切换，`import` / `export -o` 的路径补全要自己实现目录列举与转义；`-F` 配 `compgen -f` 是原生行为。代价（每次 TAB 起进程）实测只有约 4ms，而 `-F` 是进程内，更快。
- **为什么用独立文件而不是内联进 `.bashrc`**：参考实现的形态；且 `.bashrc` 常是指向 dotfiles 仓库的符号链接，install.sh 已专门处理这种情况，往里塞几十行生成代码会造成噪声 diff。独立文件还让"手动 source 一次"成为可用路径。
- **为什么不引入第二对标记**：`install.sh` 已经拥有 `# >>> dsh-service >>>` 块；第二对标记意味着两个写者改同一个文件。source 行放进现有块，`remove_rc_block` 与 `--purge` 语义直接复用。
- **为什么不抄参考实现的"source 整个 completions 目录"**：那等于替 `bash-completion` 软件包接管其它工具的文件；只 source 自己那一个文件，边界清晰。
- **重复注册是无害的**：若用户装了 `bash-completion`，该文件可能被自动加载一次，我们的块再 source 一次；`complete -F` 只是重新注册同一个函数。

### D4. 补全脚本由 dshctl 手写渲染，不做 generator 框架

单 shell、18 个扁平命令 + 一层子命令，渲染器就是一段字符串拼接：顶层命令、每个命令的子命令/选项分支、`import` 与 `export -o` 的路径分支、末尾 `complete -F`。

- `_init_completion` 存在时**不使用**：两条实现路径意味着行为随机器变化，也意味着测试只能覆盖其中一条。统一走手动回退（`cur`/`prev`/`words`/`cword`），行为确定、可测。
- 所有对 `COMP_WORDS` 的索引访问用防御性展开（`${COMP_WORDS[COMP_CWORD]:-}`、`${words[i]:-}`），保证 `set -u` 下不崩——这正是参考实现实测崩溃的位置。
- 脚本头部注明"自动生成，请勿手工编辑"，与 `~/.local/bin/dshctl` 的头部注释风格一致。

### D5. 帮助排版：ASCII 左列 + 第 33 列，描述超宽则另起一行

渲染规则（从现有输出反推，保证除两行外逐字保持）：

```
左列（命令与参数）纯 ASCII 且 2 + len(左列) < 33  -> printf '  %-31s%s'  左列 描述
否则                                            -> 左列单独一行，
                                                   再 printf '  %-31s%s' '' 描述
```

- `printf '%-31s'` 按**字符**补齐；只要同行渲染的左列是纯 ASCII，字符数就等于终端列数，第 33 列严格成立。
- **为什么不实现 CJK 宽度计算**：bash 没有 east-asian-width 内建；`(bytes-chars)/2` 这类启发式依赖 locale 且对拉丁扩展字符会偏。项目风格偏好直白实现。
- **代价**：`upgrade-node [<主版本>]`（左列含 CJK）与 `run [-- 参数...]` 两行的描述从同行改为另起一行；`upgrade`、`plugins reset`、`export`、`import`、`uninstall` 五条本来就是另起一行。无既有测试断言该帮助文本的逐字节内容，README 用的是自己那张表。
- **备选**：把这两条的左列改成纯 ASCII（`<version>`、`ARGS...`）。被否：会改变用户可见的语法文本，且与 README 的 `<版本>` 写法不一致。

### D6. 补全粒度：静态、离线、只覆盖真正接受的选项

| 命令 | 补全内容 |
|---|---|
| 全部公开命令 | 命令名（顶层位置） |
| `config` | `edit` |
| `plugins` | `list`、`ls`、`reset`；`reset` 后补 `--yes`/`-y`/`--no-restart` |
| 以 `-` 开头 | 该命令接受的选项（来自表） |
| `upgrade` | 位置参数补 `next`、`latest`（注释与文档写明只是提示，任意 dist-tag 仍可用；`--list` 才是权威来源） |
| `logs` | `-f`、`-n`（与帮助里的 `[-f] [-n N]` 一致，不假装覆盖 journalctl 全集） |
| `import` / `export -o` | `compgen -f`，不按扩展名过滤 |
| 隐藏命令、`run` 之后的参数 | 不补 |

不联网是硬约束：TAB 里发起网络请求会在离线/代理环境下造成卡顿与超时噪音。参考实现之所以敢反调 CLI，是因为它的动态候选（change/spec id）来自本地目录且它本身是 Node 进程。

### D7. 部署与卸载的职责切分

| 动作 | 归属 | 机制 |
|---|---|---|
| 生成脚本 | dshctl | `dshctl completion [bash]` → stdout |
| 落盘补全文件 | install.sh | `write_file`（已有 `cmp -s` 幂等 + 原子 `mv` + `--dry-run` 报告），内容 = `"$DSHCTL_BIN" completion bash` |
| 加 source 行 | install.sh | `rc_block_content`，受 `--no-completion` 与 `--no-rc` 双重管辖 |
| 删除补全文件 | dshctl `uninstall` | 与 `~/.local/bin/dshctl` 同级：都是安装产物，默认卸载即删 |
| 删除 source 行 | dshctl `uninstall --purge` | 随整个标记块移除；`[ -r ... ]` 守卫让残留行无害 |

- **为什么 dshctl 不提供 `completion install/uninstall`**：那会让 dshctl 与 install.sh 同时改写 `.bashrc` 与标记块，产生两个写者。参考实现需要这三个动词，是因为它的补全是 opt-in 且没有安装器。
- **两个开关互相独立**：`--no-completion` 管文件，`--no-rc` 管 `.bashrc`。用户可以用 `--no-rc` 拿到文件自行 source，这正是不提供 `install` 动词时的逃生通道。

### D8. 一致性守卫的抽取策略

- **表 ↔ 分派**：遍历表并实际执行 `dshctl <cmd> --help` 之类的最小调用，断言不是"未知命令"。比解析 `case` 文本更可靠。
- **表 ↔ 选项解析**：正向（表里的每个选项必须在对应命令的函数体中出现）无假阳性；反向（每个被解析的选项都在表里）只统计**严格匹配参数解析行**的 token（形如 `^\s*--?[a-z-]+(\)|\|)`），避免把消息文本里出现的 `--flag` 当成被解析的选项。
- **子帮助 ⊆ 表**：从 `plugins_usage` / `export_usage` / `import_usage` 的输出里提取 `--flag`，断言都在表中；单向即可，因为子帮助是用户可以 `-h` 得到的承诺。
- **隐藏命令不泄漏**：在表、`--help` 输出与补全脚本输出三处断言四个名字都不出现。

## Risks / Trade-offs

- **帮助文本两条换行变化** → 属用户可见变化；`README.md` 的命令表沿用其自身排版（不受影响），但需在 README 的补全章节说明帮助文本由命令表渲染。测试只断言结构性契约（第 33 列），不断言整段文本，避免把排版锁死到无法演进。
- **表驱动分派丢失实现** → `declare -F` 守卫把失败模式收敛为"未知命令 + 退出 2 + 用法"，并有 D8 的表↔分派测试兜底；不会泄漏 bash 的 127。
- **生成脚本在 `set -u` 下崩溃**（参考实现的实测缺陷） → 所有数组索引使用防御性展开；`补全生成与行为覆盖` 有一条专门的 `set -u` 场景。
- **补全脚本内容随 dshctl 版本变化** → 内容由表决定，改表即改文件；`cmp -s` 只在实际内容不同时才重写，因此重跑幂等成立，升级时重写一次属预期。
- **首次升级会重写一次 `~/.bashrc`**（新增 source 行） → 与现有"值变化时重写块"的行为一致（`配置值发生变化` 场景）；差分仅一行，且不会被重复添加。
- **`--no-rc` 用户拿到文件却无 source 行** → 文档在补全章节给出可粘贴的 source 行；`--help` 文本记录两个开关的独立性。
- **同一文件可能被 `bash-completion` 自动加载一次** → 重复 `complete -F` 注册同一函数，无副作用；只 source 我们自己那一个文件，不接管整个目录。
- **改表的收益与成本不对称**：新增命令时仍需提供 `cmd_*` 实现函数（这是分派契约，表无法替代）。表消除的是"忘记同步帮助与补全"，不是"忘记写实现"。
- **补全候选不是语法校验**：`upgrade` 静态提示 `next`/`latest` 可能让用户以为只有两个 dist-tag → 在脚本注释、`--help` 与 README 中都写明"仅提示，任意 dist-tag 可用，`upgrade --list` 是权威来源"。

## Migration Plan

无数据迁移，也无配置迁移。部署顺序与回滚：

1. 修改内嵌 dshctl（表 + 渲染 + 补全生成 + 分派）与 install.sh 主体（选项、落盘、rc 行、卸载、摘要），扩展 `tests/run.sh`，更新 `README.md`。
2. `bash tests/run.sh` 全绿后再重跑 `install.sh`：首次运行会写补全文件并在 rc 块中新增 source 行（`~/.bashrc` 被重写一次，带 `.dsh-service.bak` 保护仅发生在移除路径）。
3. 用户在已打开的 shell 中执行 `exec bash` 生效；未重跑 install.sh 的老安装没有补全，也不会有任何报错。
4. 回滚：`rm -f ~/.local/share/bash-completion/completions/dshctl` 并重跑旧版 `install.sh`（会把 rc 块恢复成不含 source 行的旧内容，`cmp -s` 检测到差异后重写），或 `dshctl uninstall --purge` 彻底清理。

## Open Questions

- `completion` 在 `--help` 中归入哪个分组（「查看」还是为工具类命令单开一组）：只影响一行排版，实现时定即可，不改变任何契约。
- 未来是否扩展 zsh：`dshctl completion <shell>` 的参数形态已经为此留了位置（当前只接受 `bash`），但补全脚本渲染器是 bash 专用，扩展时需要独立渲染路径与测试——留待有真实需求时再评估。
