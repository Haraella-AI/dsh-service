# Design

## Context

现状（见 `proposal.md` 的 Why）：`install.sh` 与内嵌 `dshctl` 各自把「跟随 `latest`」硬编码在两处——
安装器的 `DSH_VERSION="${OPT_DSH_VERSION:-latest}"` 与 `cmd_upgrade` 的 `local spec='latest'`；两者的
dist-tag 解析也都只识别字面量 `latest`（`ensure_dsh` 的 `if [ "$target" = latest ]`、
`resolve_target` 的 `if [ "$spec" = latest ]`）。

约束（来自 `openspec/config.yaml` 的项目上下文与本仓库既有约定）：

- 幂等是第一约束：重跑 `install.sh` 必须安全；已有安装的 `Node` 版本已在
  `simplify-toolchain-and-upgrade-ux` 中确立了「默认值只影响新安装，重跑保留既有版本」的先例。
- 安装器主体与内嵌 `dshctl` 是两段独立 Bash，彼此不能 `source`；`dshctl` 以 heredoc 内嵌在
  `install.sh` 中且是唯一来源，`--print-dshctl` 的字节一致性必须保持。既有的 `normalize_version`、
  `strip_v_prefix` 就是这么各自定义一份的。
- 具体版本路径目前不访问网络（`resolve_target` 对非 `latest` 直接返回 spec），离线测试用例
  （「校验期间 registry 不可达」）依赖这一点。
- `tests/run.sh` 的 npm 桩按 `npm view <pkg> <field>` 与 `npm install -g <pkg>@<spec>` 建模，
  只把字面量 `latest` 映射为具体版本。

## Goals / Non-Goals

**Goals:**

- 让「默认通道 = `next`」成为安装器与 `dshctl` 中版本默认值的唯一语义，并在两段脚本中保持一致。
- 让默认值只影响新安装：已有安装重跑时保留其版本（与 Node 保留规则同构）。
- 把 dist-tag 解析从 `latest` 泛化到 `dist-tags` 中的任意 tag，且不改变具体版本路径的零网络行为。

**Non-Goals:**

- 不引入配置键、环境变量或持久化的「通道」状态（proposal 的非目标）。
- 不重构安装器与 `dshctl` 的公共函数（例如把 `strip_v_prefix` 抽成共享库）——内嵌单一来源的结构
  不变，重复的小函数维持现状。
- 不改变 `dshctl upgrade --list` 的排序、标记与计数语义。
- 不改变 `--dsh-version` / `--pnpm-version` 的字符集校验。

## Decisions

### 1. 默认通道用脚本内常量表达，不新增配置键

在安装器与 `dshctl` 中各自定义一个具名常量（安装器侧 `DSH_DEFAULT_CHANNEL='next'`，`dshctl` 侧
`DSH_DEFAULT_CHANNEL='next'`），默认值由它派生：`DSH_VERSION="${OPT_DSH_VERSION:-$DSH_DEFAULT_CHANNEL}"`、
`cmd_upgrade` 的 `local spec="$DSH_DEFAULT_CHANNEL"`。

- 理由：通道本质是「默认值」，而本仓库的默认值分两类——服务配置类走
  `~/.config/dsh-service/config`，安装器/维护工具的版本默认值一直是脚本内的字面量（`pnpm` 的
  `latest` 同样不在配置里）。新增 `DSH_SERVICE_DSH_CHANNEL` 会把一次默认值翻转变成新的配置契约，
  还要同步 `config` 查看、导入/导出与 README 配置表，收益不抵成本。
- 备选：新增 `DSH_SERVICE_DSH_CHANNEL` 配置键（可被环境变量覆盖）。被否：扩大配置面、需要新的
  校验与文档，且用户的切换诉求已由 `--dsh-version` / `dshctl upgrade <spec>` 满足。

### 2. 「显式指定」以选项是否出现来判定，而不是比较版本

安装器保留规则的条件是：`OPT_DSH_VERSION` 为空、`FORCE != 1`、且检测到已安装 dsh。`dshctl` 侧改用
`spec_explicit` 标志（只有在解析到位置参数或 `--latest` 时置 1）替代原来的
`[ "$spec" != latest ]`，因为默认值不再是 `latest`，"不等于 latest" 不再等价于"用户显式给出"。

- 理由：只有用户显式表达意图时才覆盖既有安装；把判定绑在默认值字面量上会让默认值变更再次改动语义。
- 备选：在配置文件里记录「上次安装通道」再比较。被否：引入持久化状态与新的幂等面，且与「不新增配置键」
  冲突。

### 3. dist-tag 解析：按形态分流，只有非版本形态才查 registry

两段脚本各实现一个小函数（例如 `resolve_dist_tag`）：

1. 若 spec 形如 `v?<数字>...`（以数字开头或以 `v`+数字开头）→ 直接去 `v` 前缀返回，不访问网络。
2. 否则查询 `npm view @deepseek-ai/dsh dist-tags --json`，在输出中查找该 tag 名，命中则返回其版本。
3. 未命中或查询失败 → 返回空/回退字面量（安装路径：告警后按字面 tag 安装；升级路径：沿用现状，
   报告无法解析目标并以 1 退出）。

- 理由：保持具体版本路径的零网络行为（离线用例依赖），同时让 `next`/`latest`/`alpha` 走同一条解析
  路径，`latest` 不再有特殊分支。
- 备选：`npm view @deepseek-ai/dsh@<spec> version`。被否：对具体版本也会发请求，破坏零网络路径，
  且在 registry 不可达时改变现有降级行为。

### 4. 安装以 tag、比较用解析值

安装命令仍然传用户/默认给的 spec（`npm install -g "@deepseek-ai/dsh@$DSH_VERSION"`），只有「是否需要
安装」的比较使用解析出的具体版本。

- 理由：与现状一致（现状也是装 `@latest`、比较时解析），并让 `--dsh-version next` 在重跑时保持幂等。
- 备选：解析后安装具体版本。被否：会改变安装日志与 npm 行为，且让 tag 的后续移动不可见。

### 5. `upgrade-node` 的重装目标改为默认通道

`cmd_upgrade_node` 保留「必须已安装 dsh」的前置检查，但重装的 spec 由已安装版本改为解析默认通道。

- 理由：用户已确认「全部入口统一 next」；否则 `install.sh` 与 `dshctl upgrade` 走 `next` 而
  `upgrade-node` 会把 dsh 拉回旧版本，通道语义自相矛盾。
- 影响：`upgrade-node` 从「只换 Node、保持 dsh 版本」变成「换 Node 并把 dsh 带到默认通道」。
  该命令本身已是显式维护动作，风险可控，但必须在 README 与用法文本中写明。

### 6. 用户可见文案统一为「默认通道」

`--help`、`dshctl` 用法文本、README 与 `upgrade_target_not_found_hint` 都称 `next` 为「默认通道」，
提示里给出默认通道的当前版本与切换命令；`pnpm` 的 `latest` 文案不动。

## Risks / Trade-offs

- [已有安装重跑不再自动跟上默认通道，用户可能以为安装器失效] → 安装器在保留路径打印明确的
  `dsh <版本> 已安装，保留现有版本（默认通道 next…）` 提示并指向 `--dsh-version next` /
  `dshctl upgrade`；README 同步说明。
- [`next` 是预发布通道，不如 `latest` 稳] → 这是用户显式选择的默认；README 给出切回
  `--dsh-version latest` / `dshctl upgrade latest` 的方法，且显式目标路径行为不变。
- [`upgrade-node` 语义变化（不再保留 dsh 版本）] → 在 proposal 与 README 中显式记录；若评审认为不可接受，
  可在 apply 前通过 update-change 收窄到「仅 install.sh + upgrade」。
- [两段脚本的常量与解析函数重复，可能漂移] → 两处都加交叉引用注释；`tests/run.sh` 的字节一致断言与
  默认通道断言覆盖两侧。
- [npm 桩若不认识 `next` 目标，幂等断言会假通过] → 桩在写 `VERSION` 前先把 dist-tag 映射为具体版本
  （`latest` → `STUB_NPM_VIEW_VERSION`，其余 tag → `dist-tags` 中该 tag 的值）。
- [delta 规格与尚未归档的 `simplify-toolchain-and-upgrade-ux` 改同一组需求] → 本变更的 delta 已按该变更
  归档后的内容为基线编写；归档顺序为 simplify 先、本变更后（见 proposal 的 Impact）。

## Migration Plan

1. 先归档 `simplify-toolchain-and-upgrade-ux`（其行为已实现并已由测试覆盖）。
2. 应用本变更：安装器默认值与保留规则 → 内嵌 `dshctl`（默认通道、`spec_explicit`、`resolve_target`、
   `upgrade-node`、用法与提示）→ `tests/run.sh` → `README.md`。
3. 验收：`bash tests/run.sh` 全绿；`bash install.sh --dry-run` 在空 home 打印
   `npm install -g @deepseek-ai/dsh@next`；`openspec validate` 通过。
4. 回滚：改动集中在两个脚本的默认值与解析分支，`git revert` 即可；不涉及配置键或用户数据迁移，
   无需要回滚的持久化状态。
