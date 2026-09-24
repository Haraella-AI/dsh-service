# Tasks

> 每个阶段结束都必须 `bash -n install.sh`、`bash install.sh --print-dshctl | bash -n` 与 `bash tests/run.sh` 全绿，再进入下一阶段；不绿则回退该阶段而不是继续叠加（见 design.md - Risks）。

## 1. 基线与安全网

- [x] 1.1 记录重构前基线：运行 `bash tests/run.sh` 并记录通过对/失败数，确认失败数为 0
- [x] 1.2 捕获 `bash install.sh --print-dshctl` 输出到 `/tmp/dshctl.before`，作为后续 `--print-dshctl` 零差异的比对基准
- [x] 1.3 用临时 HOME 与固定配置分别渲染单元并保存：`bash install.sh --dry-run` 无法产出单元，改为用 `--print-dshctl` 导出的副本调用 `_render-unit`，把渲染结果保存为 `/tmp/unit.before`
- [x] 1.4 记录幂等基线：在临时 HOME 连续运行两次 `install.sh`，第二次必须报告配置/单元/rc/dshctl 未变化，并记录关键文件哈希

## 2. P1 常量提取（两段各建常量区）

- [x] 2.1 在 install.sh 头部建立常量区，提取 `DEFAULT_NAME/PROFILE/HOST/PORT/NODE_MAJOR/NVM_VERSION/DSH_CHANNEL/PNPM_VERSION` 与 `NODE_ATTEMPTS_DEFAULT/NODE_RETRY_DELAY_DEFAULT/DEFAULT_URL_WAIT_SEC`，验证：取值与现状一致（逐项对照 design.md - D2 清单），`bash tests/run.sh` 全绿
- [x] 2.2 把 install.sh 的镜像 URL 提为常量（`MIRROR_NPM_REGISTRY`/`MIRROR_NODE_MIRROR`/`OFFICIAL_NPM_REGISTRY`/`MIRROR_NVM_REPO`/两个 install URL 基址），验证：`--no-mirror` 与默认两条路径的 URL 与重构前逐字相同
- [x] 2.3 在 install.sh 内嵌段内建立常量区，提取 `DSH_DEFAULT_CHANNEL`（从 L121 上移）、`EXPORT_FORMAT`（从 L1604 上移）与 systemd 单元策略 `UNIT_RESTART_SEC/UNIT_STOP_TIMEOUT_SEC/UNIT_START_LIMIT_INTERVAL_SEC/UNIT_START_LIMIT_BURST`，验证：`bash tests/run.sh` 全绿
- [x] 2.4 两处常量区都写「与另一段脚本保持一致、不能合并、因为两段不能互相 source」的注释，并标注具体同步对象；验证：注释存在且列出全部 6 个同名默认值
- [x] 2.5 阶段收尾：`bash -n install.sh`、`bash install.sh --print-dshctl | bash -n`、`bash tests/run.sh` 全绿

## 3. P2 install.sh 主体函数化

- [x] 3.1 新增 `setup_colors`，消除 L2249-2254 与 L123-127 两份重复的颜色判断，验证：非 tty 与 tty 两种情况下 `log/warn/err` 输出前缀与重构前一致
- [x] 3.2 新增 `parse_args` 收编 L2257-2287 的参数解析，验证：`--port 3080` 与 `--port=3080` 两种形式、`--help`、`--print-dshctl`、未知参数退出 1 的行为与重构前一致
- [x] 3.3 新增 `init_config`（HOME 检查 + 载入配置 + `:=` 默认值）与 `validate_options`（6 段 case 校验），验证：`--port abc`、`--port 70000`、`--port 0`、`--node-major '22;rm'`、`--name 'a/b'`、非绝对 `--prefix` 均退出 1
- [x] 3.4 新增 `init_derived_values` 收编派生变量与 `NODE_MAJOR_KEPT` 沿用逻辑（含 L2398-2400 的 `UNIT_NAME/UNIT_FILE/DSHCTL_BIN`），函数头注释列出它设置的全局变量；验证：`--port 080` 归一化为 80、已记录 Node 目录时沿用其主版本
- [x] 3.5 新增 `init_mirrors` 收编 L2402-2441（镜像模式 + `NVM_INSTALL_URL` + `NVM_SOURCE_EFFECTIVE` + 无 git 时清空），验证：默认/`--no-mirror`/`--mirror` 三种模式下 `DSH_SERVICE_*` 与 `NVM_*` 取值与重构前一致
- [x] 3.6 新增 `print_summary` 收编 L3159-3219 的汇总与后续步骤，验证：摘要字段顺序与文案逐字不变（比对重构前两次运行的输出 diff）
- [x] 3.7 新增 `main` 编排 3.2-3.6 与既有步骤函数，把 `main "$@"` 放到文件最后一行，使顶层只剩常量、内嵌 heredoc 与函数定义，验证：`bash -n install.sh` 通过、`--print-dshctl` 输出与源码内嵌段逐字节一致（cmp）、`bash tests/run.sh` 全绿
- [x] 3.8 单元渲染守卫：用 `/tmp/dshctl.before` 导出的副本按 1.3 的同样配置渲染并 `cmp` `/tmp/unit.before`，必须零差异
- [x] 3.9 在 install.sh 头部注释说明文件布局（常量区 → 内嵌 dshctl 边界 → 安装器函数 → `main "$@"`）与"内嵌块物理位置在中间、执行入口在末尾"的原因，并注明 `bash < install.sh`（stdin 执行）不受支持；验证：注释覆盖这两点

## 4. P3 内嵌 dshctl 拆分

- [x] 4.1 统一 nvm 加载：两段都实现 `try_load_nvm`（详细版）+ `load_nvm`（薄包装，失败 die）+ `load_nvm_soft`（静默版），保留双方的 `unset PREFIX`；验证：`bash tests/run.sh` 第 11 节 PREFIX 用例通过、nvm 缺失时 doctor --fix 不中断
- [x] 4.2 统一 `cleanup_tmp` 使用 `rm -rf`（两段），验证：正常完成与中途失败两种场景下配置/单元目录无残留，且中途失败仍以非零退出
- [x] 4.3 把 `cmd_import`(256) 拆为 `parse_import_args`/`verify_archive_members`/`extract_archive`/`read_import_manifest`/`stage_imported_home`/`apply_imported_config`，验证：`bash tests/run.sh` 的导出导入用例全绿，且拒绝畸形归档（越界成员、`..`、格式版本不符、非数字端口）的退出码仍为 1
- [x] 4.4 把 `cmd_export`(148) 拆为 `parse_export_args`/`collect_export_config`/`pack_export_archive`，验证：导出归档布局（`manifest`/`config/`/`dsh-home/`）与失败处理用例全绿
- [x] 4.5 把 `cmd_doctor`(134) 拆为 12 个 `doctor_check_*`（返回 0/1/2）加 `doctor_report`（独占计数器与配色）；检查函数只输出消息、不直接调用 `pass/fail/note`；验证：`dshctl doctor` 与 `doctor --fix` 的通过/失败计数与重构前一致
- [x] 4.6 把 `cmd_upgrade`(107) 的安装与校验-回滚两段拆为 `install_upgraded_dsh`/`verify_or_rollback`（复用既有 `rollback_upgrade`），验证：升级成功、装后校验失败自动回滚、安装失败不回滚三类用例全绿
- [x] 4.7 把 `cmd_plugins_reset`(89) 拆为 `backup_plugins_manifest`/`prune_installed_plugins`，验证：插件重置用例全绿且 manifest 备份到 `package.json.bak-*`
- [x] 4.8 把 `ensure_shell_rc`(70) 的 rc 代码块提为常量 `RC_BLOCK`，保留标记替换逻辑；验证：`bash tests/run.sh` 中 rc 代码块不重复、不覆盖用户自定义内容的用例全绿
- [x] 4.9 阶段收尾：`bash -n install.sh`、`bash install.sh --print-dshctl | bash -n`、单元渲染 `cmp` 零差异、`bash tests/run.sh` 全绿

## 5. P4 诊断提示一致性（力度 1）

- [x] 5.1 把 npm 安装失败的补救建议改为按 `DSH_SERVICE_MIRROR` 区分镜像/官方源，与 `ensure_node` 的 Node 下载失败提示对称；验证：两种模式下各跑一次失败用例，建议与当前模式匹配
- [x] 5.2 排查所有 `err`/`die` 调用，把只有"现象"的补成「现象 + 原因 + 下一步」三段式；验证：逐条列出改动清单，确认没有新增或删除任何退出码分支
- [x] 5.3 确认汇总块的字段宽度与 `doctor` 的 `✓/✗/!` 标记在拆分后仍统一；验证：`dshctl doctor` 输出与重构前仅在被 5.1/5.2 覆盖的行上有差异
- [x] 5.4 运行 `bash tests/run.sh`，逐条确认失败断言的性质属于"文案调整"而非"行为回归"；若确有断言咬到新文案，同步更新断言并说明；验证：最终全绿且断言数不少于 1.1 的基线
- [x] 5.5 更新 README.md 中描述内嵌 dshctl 的段落（第 61 行附近），补充常量区与文件布局说明，并说明 `bash < install.sh` 不受支持；验证：按 README 描述的命令实际执行可行

## 6. 集成验收

- [x] 6.1 幂等验收：在临时 HOME 连续运行两次 `install.sh`（相同选项），第二次报告配置/单元/rc/dshctl 未变化，且关键文件哈希与 1.4 基线的第二轮一致
- [x] 6.2 `--print-dshctl` 契约验收：改用「输出 == 源码内嵌段」逐字节比对（P1 已按设计改写内嵌段，重构前的字节基线不再适用），且 `--print-dshctl` 与 `--help` 都在任何安装步骤之前以退出码 0 完成（在空 HOME 下验证）
- [x] 6.3 顶层结构验收：确认安装器主体已无顶层可执行语句（除常量赋值、内嵌 heredoc 与末尾 `main "$@"`），最长函数不超过 design.md - D6 的拆分目标
- [x] 6.4 输出契约验收：用同一份临时 HOME 比对重构前后的 `install.sh` 完整输出与 `dshctl status/url/version/config/doctor` 输出，差异仅限 5.1/5.2 明确列出的行
- [x] 6.5 最终全量测试：`bash tests/run.sh` 报告通过与失败数，失败数为 0

## 条件规则说明

- tasks 规则「为新增行为扩展 tests/run.sh 的离线覆盖」：本次为纯结构重构，没有新增行为。以 1.1 的基线、各阶段的全量测试、6.1/6.4 的契约比对作为回归覆盖；5.4 在文案确有调整时同步更新断言。
- tasks 规则「参数、配置键或用户可见输出变化时更新 README.md 与 `--help`/usage 文本」：参数、配置键与 `--help`/usage 文本均未变化，故不适用；用户可见输出仅有 5.1/5.2 的措辞调整，README 的更新由 5.5 承担。
