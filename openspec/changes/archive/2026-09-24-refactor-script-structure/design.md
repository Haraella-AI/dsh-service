# Design

## Context

见 proposal.md - Why。约束来自项目现状，都会直接影响拆分方式：

- **内嵌 dshctl 是 heredoc 字面量**。赋值 `IFS= read -r -d '' DSHCTL_SRC <<'DSHCTL_EMBED_EOF'` 是**运行时**行为，不是解析期行为。实测把整段块移到文件末尾后 `bash -n` 通过，但执行时报 `DSHCTL_SRC: unbound variable`。
- **两段脚本不能互相 `source`**。dshctl 会被写到 `<prefix>/dshctl` 独立分发，install.sh 只能通过 `--print-dshctl` 导出它的源码；因此任何"共享常量"都只能在两处各存一份。
- **内嵌段必须自包含**。它不能引用 install.sh 主体里定义的任何东西（因为作为独立文件运行时那些不存在）。
- **单文件契约**：README 与规格都承诺 `curl -fsSL <raw> | bash` 与 `bash install.sh` 两种用法，不允许拆成多文件或引入构建步骤。
- **测试是唯一安全网**：tests/run.sh 完全离线、285 条断言，覆盖安装、幂等、升级回滚、doctor、导出导入等路径。

## Goals / Non-Goals

**Goals:**

- 让 install.sh 的阅读顺序与执行顺序一致：常量 → 内嵌 dshctl（明确边界）→ 安装器函数定义 → `main "$@"`。
- 消除顶层散装语句：文件顶层只剩函数定义、常量、内嵌 heredoc 与末尾一次 `main "$@"`。
- 把最长函数降到可在一个屏幕内读完的粒度。
- 让两段脚本中语义相同的函数**同名同分工**，并把刻意的重复标注清楚。
- 保持所有外部可观察契约逐字节不变（单元文件、配置、退出码、选项）。

**Non-Goals:**

- 不合并两段脚本、不抽公共库、不引入构建步骤（破坏单文件与唯一来源契约）。
- 不改 CLI 选项、退出码、配置键名、环境变量名与优先级。
- 不重写用户可见文案（只做力度 1 的一致性修补）。
- 不改 `cmd_*` 命名风格、不改配置文件名与 systemd 单元渲染结果。
- 不新增 shellcheck 配置、CI 或测试框架。

## Decisions

### D1. 文件布局：内嵌块物理位置不动，安装器以 `main "$@"` 收尾

采用方案 A：

```
install.sh（重构后）
+---------------------------------------------------------------+
| 0. 头部注释 + set -Eeuo pipefail + LC_ALL export               |
+---------------------------------------------------------------+
| 1. 常量区（新增）                                              |
|      setup_colors / 版本号 / DEFAULT_* / 镜像 URL / 行为参数     |
|      附一张「配置键（可被环境变量覆盖） vs 内部常量」对照注释     |
+---------------------------------------------------------------+
| 2. 内嵌 dshctl（唯一来源；赋值 → 内容 → 去尾换行）              |
|      段首段尾各留一条明显分隔注释，标识这是边界而非遗漏         |
+---------------------------------------------------------------+
| 3. 安装器主体：全部函数定义                                    |
|      3a I/O    log warn err die / usage                        |
|      3b 参数   parse_args                                      |
|      3c 初始化 init_config / validate_options                  |
|                init_derived_values / init_mirrors              |
|      3d 工具   run / write_file / rc_q / resolve_port ...      |
|      3e 步骤   ensure_nvm / ensure_node / ensure_dsh           |
|                ensure_pnpm / install_tools / ensure_shell_rc    |
|                render_via_dshctl / retire_previous_unit         |
|                apply_service                                   |
|      3f 汇总   print_summary                                   |
|      3g 入口   main                                            |
+---------------------------------------------------------------+
| 4. main "$@"   <-- 文件最后一行                                |
+---------------------------------------------------------------+
```

**为什么不让 heredoc 物理上排到最末**：那样必须把 `IFS= read ... <<'EOF'` 的头留在文件前部、内容留在尾部，靠 bash 解析期读取 heredoc 内容来"缝合"。语法能通过、`--print-dshctl` 也不会坏（实测），但一个跨 2000 行的 heredoc 头尾分离，比"内嵌块整体在中间"更难读，且编辑时极易破坏。用末尾 `main "$@"` 同样能达到"执行入口在文件末尾、顶层无散装语句"的效果。

**为什么把 `main` 独立成函数而不是继续写顶层语句**：`--print-dshctl` 与 `--help` 必须在任何安装步骤之前完成，而 `DSHCTL_SRC` 在顶层赋值后即可用；把它们放进 `main` 的分支里，语义与现在完全一致，同时让"先定义后执行"的边界明确。

**已知代价（需在 README/注释中标注）**：`bash < install.sh`（从 stdin 执行）这种未文档化的用法会因为 heredoc 内容来自 stdin 而失效。文档化的两种用法（本地文件、`curl | bash -s --`）不受影响。

### D2. 常量区：两段各一份，判别标准明确

判别标准：**能被配置文件或环境变量覆盖的，不是常量**，继续留在配置块；不能覆盖的才进常量区。

install.sh 常量区（名称与取值，取值均与现状一致）：

```
readonly INSTALLER_VERSION        <- L23 移入（去掉 readonly 前的 let 语义不变）
DEFAULT_NAME='dsh'                <- L2313 的默认值
DEFAULT_PROFILE='web'             <- L2314
DEFAULT_HOST='127.0.0.1'          <- L2315
DEFAULT_PORT=3080                 <- L2316
DEFAULT_NODE_MAJOR=24             <- L2335
DEFAULT_NVM_VERSION='v0.40.1'     <- L2350
DEFAULT_DSH_CHANNEL='next'        <- L2354
DEFAULT_PNPM_VERSION='latest'     <- L2357
MIRROR_NPM_REGISTRY / MIRROR_NODE_MIRROR / OFFICIAL_NPM_REGISTRY   <- L2416-2421
MIRROR_NVM_REPO='https://gitee.com/mirrors/nvm'                    <- L2436
MIRROR_NVM_INSTALL_URL_BASE / OFFICIAL_NVM_INSTALL_URL_BASE        <- L2427-2429
DEFAULT_URL_WAIT_SEC=30           <- L3181 的裸字面量
NODE_ATTEMPTS_DEFAULT=3           <- L2768
NODE_RETRY_DELAY_DEFAULT=5        <- L2769
C_GREEN/C_YELLOW/C_RED/C_RESET    <- L2249-2254，改用 setup_colors 赋值
```

内嵌 dshctl 常量区（位置：shebang 之后、配置加载之前）：

```
readonly DSHCTL_VERSION='0.1.0'                    <- L39 移入
DEFAULT_*（与上面同名同值的 6 个，注释注明与安装器一致但故意各存一份）
DSH_DEFAULT_CHANNEL='next'                         <- L121 上移
readonly EXPORT_FORMAT=1                           <- L1604 上移
readonly UNIT_RESTART_SEC=3                        <- L514 裸字面量
readonly UNIT_STOP_TIMEOUT_SEC=45                  <- L515
readonly UNIT_START_LIMIT_INTERVAL_SEC=300         <- L512
readonly UNIT_START_LIMIT_BURST=5                  <- L513
readonly LISTENER_PROBE_GRACE_SEC=2                <- L595 的 local grace 默认值
```

**为什么不合并成一处**：Context 里的两条约束（两段脚本不能互相 `source`、内嵌段必须自包含）使合并必须借助构建步骤或多文件，直接违反单文件契约。可接受的代价是约 6 个默认值在两处各存一份——用注释明确标注"故意重复"来防止后人误改。`DSH_DEFAULT_CHANNEL` 也一样，L120 已有注释说明「两段脚本不能互相 source」，重构后保留该注释。

**为什么不给 `cmd_url --wait` 造默认值常量**：它的 `--wait` 默认是 `0`，`--wait 30` 只出现在 install.sh 汇总里（L3181）。给 dshctl 造一个 30 的默认值会**改变行为**，明确不做。

### D3. nvm 加载统一为 `try_load_nvm` + `load_nvm` + `load_nvm_soft`

两段都采用 dshctl 现在的分工：

```
try_load_nvm           检查 nvm.sh 存在 → unset PREFIX → export NVM_DIR
                       → with_loose_shell source → 失败安静返回 1
load_nvm               try_load_nvm || die "现象 + 下一步"        (薄包装)
load_nvm_soft          try_load_nvm 的静默包装（install.sh 需要）
```

**为什么选 dshctl 的分工而不是 install.sh 的**：dshctl 的分工把"可恢复路径"与"硬依赖入口"分开命名，调用点自解释——`try_load_nvm` 读起来就知道不会 exit，`load_nvm` 读起来就知道会 die。install.sh 现在的 `load_nvm`（详细版）与 `load_nvm_soft`（安静版）命名不体现这个差别。

**副作用（可接受）**：install.sh 的 `nvm_loadable` 目前自带一份 `with_loose_shell env NVM_DIR=... bash -c` 的探针，保留不动——它在子 shell 里探测，语义与 `try_load_nvm`（在当前 shell source）不同，合并会改变行为。

### D4. 单元渲染：提取常量但输出逐字节不变

`render_unit` 里的 `StartLimitIntervalSec=300` / `StartLimitBurst=5` / `RestartSec=3` / `TimeoutStopSec=45` 提为常量，但**取值不变**，因此渲染出的单元文件逐字节相同。这是"提取常量"与"改行为"的边界，也是可验证的守卫：重构前后对同一份配置渲染出的单元必须 `cmp` 相等。

单元模板本身（那串 `printf` 序列）保持为 `render_unit` 内的连续块，不抽成 `UNIT_TEMPLATE` heredoc 常量。理由：抽出去会把 `%` 转义（`unit_percent`）与插值的上下文分离，读者要来回跳才能确认某一行是否需要转义，反而降低可读性。这是对前期讨论中"模板抽成常量"提议的修正。

### D5. doctor 拆分：检查项返回消息，编排层统一计数与配色

`cmd_doctor`（134 行）现在是 12 段平铺的 `if`。改为：

```
doctor_check_nvm / doctor_check_node / doctor_check_dsh / doctor_check_dsh_config
doctor_check_systemd / doctor_check_unit / doctor_check_linger / doctor_check_listener
doctor_check_journal / doctor_check_path / doctor_check_symlink / doctor_check_dsh_home
                每个函数用 printf 输出一行消息，返回 0（通过）/ 1（失败）/ 2（提示）
doctor_report   ok=0 bad=0 的计数器，按返回码分发到 pass/fail/note 并递增
cmd_doctor      解析 --fix → 依次调用 → 汇总 → 可修复项处理
```

**为什么返回码而不是让检查函数自己调用 pass/fail**：`pass/fail/note` 会修改 `ok`/`bad` 计数器，若 12 个函数各自调用，它们必须能写调用者的 `local`（bash 动态作用域下可行但隐晦）。返回码方案让每个检查函数是纯函数，编排层独占计数与配色，也顺带实现"配色统一"这一力度 1 目标。

**注意**：`pass`/`fail`/`note` 现在定义在 `cmd_doctor` 内部且用闭包改 `local ok bad`。改为函数后计数器需放在 `doctor_report` 的 `local` 里，`cmd_doctor` 通过返回值拿到 `bad` 的计数。

### D6. 拆分粒度：按"可命名的动作"切，不为单调用点造函数

| 函数 | 现状 | 拆分 | 理由 |
|---|---|---|---|
| `cmd_import` | 256 | 6：`parse_import_args` / `verify_archive_members` / `extract_archive` / `read_import_manifest` / `stage_imported_home` / `apply_imported_config` | "读 manifest"与"校验字段"合为一个：后者只依赖前者，单独拆出只有一个调用点，只增加跳转 |
| `cmd_export` | 148 | 3：`parse_export_args` / `collect_export_config` / `pack_export_archive` | 天然三段 |
| `cmd_doctor` | 134 | 12 个检查 + `doctor_report` | 见 D5 |
| `cmd_upgrade` | 107 | 新增 2：`install_upgraded_dsh` / `verify_or_rollback`（复用已有 `rollback_upgrade`） | 目标解析已有 `resolve_target`，不再拆 |
| `cmd_plugins_reset` | 89 | 2：`backup_plugins_manifest` / `prune_installed_plugins` | 天然两段 |
| `ensure_shell_rc` | 70 | rc 代码块提为常量 `RC_BLOCK`，函数保留标记替换逻辑 | 代码块内容与替换逻辑是两件事 |
| `render_unit` | 75 | 仅提取单元策略常量（见 D4） | 模板不抽，理由见 D4 |

## Risks / Trade-offs

- [**大范围机械改写引入回归**] → 分 4 个阶段提交，每阶段结束跑 `bash -n` 与 `bash tests/run.sh`：P1 常量、P2 install.sh 主体函数化、P3 dshctl 拆分、P4 诊断文案。每阶段必须全绿再进入下一阶段；任阶段无法全绿则回退该阶段而非继续叠加。
- [**bash 函数化后局部变量变成全局**] → 现状顶层散装语句里的变量（如 `kept_major`、`NAME`、`PORT`）本身就是全局；收进 `init_*` 函数后若用 `local` 会破坏后续引用。规则：`init_*` 只对**临时**变量用 `local`，对外产出的变量一律显式全局赋值，并在函数头注释列出它设置哪些变量。
- [**`main "$@"` 与 `exit 0` 的交互**] → 现在文件末尾的 `exit 0` 与 `--print-dshctl`/`--help` 的提前 `exit 0` 都要移入 `main`；`DSHCTL_SRC` 的顶层赋值必须在 `main` 调用之前。验收方式是 `--print-dshctl` 输出与重构前 `diff` 为零、且 `bash -n` 通过。
- [**单元渲染被无意改动**] → D4 的守卫：重构前后用同一份临时 HOME 与配置各渲染一次，`cmp` 单元文件必须是零差异。这条作为 P2/P3 的显式验收项。
- [**诊断文案改动咬到测试断言**] → 先跑全绿基线；P4 只在 P1-P3 全绿后进行，改动后逐条核对失败断言属于"文案改了"而非"行为坏了"。预期 0-2 条。
- [**阅读收益被 diff 规模淹没**] → 这是必然代价：约 3200 行文件的大范围移动会产生巨大 diff。缓解手段是分阶段提交，使每个 diff 有单一明确主题，便于 review 与二分定位。
- [**刻意重复的常量被后人误合并**] → 两处常量区都写明"与另一段脚本保持一致，不能合并，因为两段不能互相 source"，并指出具体的同步对象。

## Migration Plan

无需数据迁移；这是一次性源码重构，对外契约不变。

1. P1 常量提取（两段各建常量区，取值不变）→ `bash -n` + 全量测试。
2. P2 install.sh 主体函数化（新增 8 个函数、末尾 `main "$@"`）→ 语法、全量测试、`--print-dshctl` diff 为零、单元 `cmp` 为零。
3. P3 内嵌 dshctl 拆分（D5/D6 的函数）→ 语法、全量测试、单元 `cmp` 为零。
4. P4 诊断提示统一（力度 1）→ 全量测试，逐条确认失败断言的性质。
5. 幂等验收：连续两次 `install.sh`（相同选项），第二次必须报告 config/unit/rc/dshctl 未变化，且两轮后文件哈希一致。
6. 更新 README.md 中描述内嵌 dshctl 与文件布局的段落。

**回滚**：改动跟踪在 git 中，按阶段提交，任一阶段出问题 `git revert` 该阶段提交即可回到上一个已知良好状态；没有任何运行时状态或配置格式被修改，回滚不需要清理用户机器。

## Open Questions

无。所有影响拆分方式与验收标准的决策已在探索阶段与用户确认（方案 A、力度 1、`cleanup_tmp` 统一 `rm -rf`、粒度按最合适定）。
