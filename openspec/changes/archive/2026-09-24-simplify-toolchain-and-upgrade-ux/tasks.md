# Tasks

## 1. 移除构建工具链功能

- [x] 1.1 删除安装器选项循环中的 `WITH_BUILD_TOOLS` 变量与 `--with-build-tools` 分支；验证 `bash install.sh --with-build-tools` 以未知参数错误退出 1，且不执行任何安装步骤。
- [x] 1.2 删除 `detect_pkg_manager`、`distro_name`、`ensure_build_tools` 以及 `ensure_build_tools` 调用点；验证 `bash -n install.sh` 通过，且用 grep 搜索 `with-build-tools`、`BUILD_TOOLS`、`apt-get`、`dnf`、`yum` 找不到残留的安装器代码。
- [x] 1.3 更新 `install.sh` 的用法文本、头部注释与构建工具摘要行，并对步骤列表重新编号；验证 `bash install.sh --help` 不提及任何构建工具链，且其步骤编号与摘要与已实现的流水线一致。
- [x] 1.4 更新 `README.md`：从安装步骤表中删除构建工具链那一行并对其余步骤重新编号，从要求与选项参考中删除该标志，并保留一条简短说明告知用户在需要时自行安装编译器；验证 README 不再包含 `with-build-tools`，且其步骤编号连续。
- [x] 1.5 更新 `openspec/config.yaml` 中的项目上下文，使其不再写着 Node 22，也不再将被移除的标志称为 `sudo` 路径；验证 `openspec context` 打印出更新后的上下文且无警告。
- [x] 1.6 更新 `tests/run.sh`：删除 `--help` 与 dry-run 的构建工具链断言，新增一个断言被移除的标志作为未知选项以非零退出；验证 `bash tests/run.sh` 仍报告所有断言通过。

## 2. 默认 Node 主版本 24 并保留现有安装

- [x] 2.1 将安装器的 Node 主版本默认值从 22 改为 24，并更新头部与用法文本来记录 24；验证在没有 `--node-major` 且没有已记录 Node 时解析出的默认值为 24，且 `bash install.sh --help` 显示 24。
- [x] 2.2 新增保留规则：当缺少 `--node-major` 且加载的配置记录了带有可执行 `node` 的 `DSH_SERVICE_NODE_BIN_DIR` 时，从该二进制推导主版本并用它替代默认值，同时报告所保留的版本以及如何切换主版本；验证在 Node 二进制目录指向一个现有 Node 的沙箱配置下，不会尝试任何下载，且渲染出的 unit 中保留所记录的目录。
- [x] 2.3 确认显式 `--node-major` 路径仍优先于默认值与已记录的 Node，且缺失或不可执行的已记录目录会回退到 24；验证在测试沙箱中运行安装器覆盖每种情况。
- [x] 2.4 扩展 `tests/run.sh`，新增一个全新 home 场景断言请求的是 Node 24，并新增一个重跑场景断言较旧的已记录 Node 被保留、不发生下载且 unit 不变；验证 `bash tests/run.sh` 通过。
- [x] 2.5 更新 `README.md`，说明新安装使用 Node 24、Node 22 仍受支持，以及如何切换主版本（`--node-major 24`、`dshctl upgrade-node 24`）；验证所记录的命令与 `--help` 输出一致。

## 3. 新增 `dshctl upgrade --list`

- [x] 3.1 在 `cmd_upgrade` 中于已安装 dsh 检查之前实现 `--list [N]` 处理：应用镜像设置，查询版本与 dist-tag，按最新在前打印版本并带上 dist-tag 标记，默认使用有界数量，并对非数字或非正数的数量以 1 退出；针对 registry 手动验证打印顺序为最新在前且数量限制被遵守。
- [x] 3.2 确保列出路径不执行任何安装与任何服务操作，并且在 dsh 未安装时也能工作；在测试沙箱中验证 `dshctl upgrade --list` 以 0 退出，且未记录到任何 `systemctl` 或 `npm install` 调用。
- [x] 3.3 以网络/registry 提示报告 registry 获取失败并以 1 退出；用桩造的 registry 失败验证消息指明了原因且退出状态为 1。
- [x] 3.4 更新 `dshctl` 的用法文本、README 命令表与升级章节以记录 `--list [N]`；验证所记录的示例输出形态与实现一致。
- [x] 3.5 扩展 `tests/run.sh` 以覆盖列出顺序、dist-tag 标记、数量限制、无效数量、未安装 dsh 的情况以及 registry 失败的退出；验证 `bash tests/run.sh` 通过。

## 4. 校验升级目标并暴露版本未找到提示

- [x] 4.1 为显式请求的版本或 dist-tag 新增预校验：向 registry 查询该 spec，返回版本时继续，当输出为空且带有未找到诊断时在安装前失败，并指明所请求的目标、`--list` 命令以及当前最新版本；验证 `dshctl upgrade <nonexistent>` 以 1 退出且不运行 `npm install`。
- [x] 4.2 将任何其他查询失败视为“无法确认”——给出警告并继续进入现有的安装/验证/回滚流程；用桩造的网络失败验证会尝试安装，且运行不会在校验处中止。
- [x] 4.3 新增安装失败安全网：在仍流式输出的同时把安装命令的合并输出捕获到已注册的临时文件，检测无匹配版本的诊断，并打印同一条提示而不触发回滚；验证退出时临时文件被删除，且当桩安装以该诊断失败时提示出现。
- [x] 4.4 更新 README 的升级与故障排查章节，记录预校验行为、该提示以及 `--list`；验证所记录的行为与命令输出一致。
- [x] 4.5 扩展 `tests/run.sh`，新增以下场景：不存在的版本（未尝试安装、打印提示）、registry 不可达的校验仍然执行安装，以及带有未找到诊断的安装失败（打印提示、不回滚）；验证 `bash tests/run.sh` 通过。

## 5. 集成验证

- [x] 5.1 在最终代码树上端到端运行 `bash tests/run.sh`，并确认通过/失败摘要报告零失败。
- [x] 5.2 在干净的临时 home 中运行 `bash install.sh --dry-run`，并确认打印的计划包含 Node 24、不包含构建工具链步骤，且不修改任何内容。
- [x] 5.3 验证内嵌的 `dshctl` 仍是唯一来源：`bash install.sh --print-dshctl` 与 heredoc 块逐字节一致（测试套件的字节一致性断言通过）。
- [x] 5.4 运行 `openspec validate "simplify-toolchain-and-upgrade-ux"` 与 `openspec validate --specs`，并确认二者都报告无失败。
