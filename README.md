# dsh-service

在 Linux（Ubuntu / Debian / AlmaLinux 等 + systemd）上一键安装 **DeepSeek Harness Web GUI**，并注册为**用户级 systemd 服务**，附带服务管理工具 `dshctl`。

当前版本：**v0.1.0**（`install.sh` 的 `INSTALLER_VERSION` 与内嵌 `dshctl` 的 `DSHCTL_VERSION` 同源同值，由 [scripts/bump-version.sh](scripts/bump-version.sh) 统一维护，见 [版本管理](#版本管理)）

**方式一：直接管道执行**（把 URL 换成你的仓库 raw 地址）

```sh
curl -fsSL https://raw.githubusercontent.com/Haraella-AI/dsh-service/main/install.sh | bash
```

**方式二：克隆后本地执行**

```sh
git clone https://github.com/Haraella-AI/dsh-service.git
cd dsh-service && bash install.sh
```

> 脚本只监听 `127.0.0.1`（上游 `dsh web` 出于安全考虑拒绝 `--host 0.0.0.0`）；远程访问见 [远程访问](#远程访问)。
> 脚本**不处理 API Key**，模型密钥请在 Web 界面中配置（见 [配置模型密钥](#配置模型密钥)）。

---

## 目录

- [安装脚本做了什么](#安装脚本做了什么)
- [环境要求](#环境要求)
- [文件位置](#文件位置)
- [dshctl 命令](#dshctl-命令)
- [配置文件](#配置文件)
- [远程访问](#远程访问)
- [配置模型密钥](#配置模型密钥)
- [配置代理](#配置代理)
- [升级与回滚](#升级与回滚)
- [重置插件](#重置插件)
- [导出与导入](#导出与导入)
- [卸载](#卸载)
- [故障排查](#故障排查)
- [install.sh 选项](#installsh-选项)
- [测试](#测试)
- [版本管理](#版本管理)
- [安全说明](#安全说明)

---

## 安装脚本做了什么

`install.sh` 是单文件、幂等的脚本；每一步在已完成时会自动跳过，重复执行安全：

| # | 步骤 | 说明 |
|---|---|---|
| 0 | 端口预检 | 安装前检查 `--port`（默认 3080）是否被占用；被占用则自动改用后续空闲端口并写回配置（`--strict-port` 改为直接报错退出） |
| 1 | 安装 nvm | 未检测到 `~/.nvm/nvm.sh` 时下载 `nvm-sh/nvm/v0.40.1/install.sh` 到临时文件后执行；默认从 Gitee 镜像（`https://gitee.com/mirrors/nvm`）获取，`--no-mirror` 时走 `raw.githubusercontent.com`。打印脚本 `sha256`，可用 `DSH_NVM_INSTALL_SHA256` 固定校验（两处内容一致） |
| 2 | 安装 Node 24 | `nvm install -b 24`、`nvm alias default 24`、`nvm use --silent 24`。`-b` 表示二进制下载失败时**不**静默转为源码编译；失败按 `DSH_SERVICE_NODE_ATTEMPTS`（默认 3 次）重试。`~/.nvm` 下已有同主版本时直接复用，不再联网解析版本。**重跑不会迁移现有安装**：配置里记录了 Node 二进制目录时，未显式传 `--node-major` 就沿用该主版本（Node 22 仍受支持，下限为 22；要升级用 `dshctl upgrade-node 24` 或 `install.sh --node-major 24`） |
| 3 | 安装 dsh | `npm install -g @deepseek-ai/dsh@next`（**默认通道 next**：上游把最新构建放在 dist-tag `next` 上，`latest` 常常落后；默认经 npmmirror registry，`--no-mirror` 为官方 registry）。**重跑不会迁移已有安装**：未显式传 `--dsh-version` 时保留已安装版本，只有新安装才走 next；`--dsh-version latest` 或 `dshctl upgrade latest` 可切回 latest，`--force` 强制重装 |
| 4 | 安装 pnpm | `npm install -g pnpm@latest`（同上走镜像 registry）；已安装同版本则跳过（`--pnpm-version` 指定版本，`--no-pnpm` 跳过）。pnpm 是可选的附加工具：安装失败只告警，不影响 dsh 服务 |
| 5 | 用户级入口 | `~/.local/bin/dsh` → 全局 dsh 的符号链接；写入 `~/.local/bin/dshctl` |
| 6 | shell 配置 | 在 `~/.bashrc` 写入带标记的块：`NVM_DIR`、nvm 加载、`~/.local/bin` 入 PATH；重跑时若 `--prefix` 等取值变化会重写该块（`--no-rc` 可跳过） |
| 7 | systemd 单元 | 写入 `~/.config/systemd/user/dsh.service`，`systemctl --user daemon-reload` + `enable --now` |
| 8 | linger | `loginctl enable-linger $USER`，使服务在开机未登录时也能启动；优先免密 `sudo`，失败再回退到无特权（polkit）/ 交互式 `sudo`（`--no-linger` 可跳过） |
| 9 | 校验 | 等待服务进入 `active`（启动即崩溃会报错），并从日志中取出登录链接 |

安装脚本中的 dshctl 只有一份来源：它内嵌在 `install.sh` 里，可以用 `bash install.sh --print-dshctl` 导出比对。

`install.sh` 的布局刻意保持「阅读顺序 == 执行顺序」：**常量区 → 内嵌 dshctl → 安装器函数定义 → 文件末尾的 `main "$@"`**。
两段脚本不能互相 `source`，因此各自的常量区里有一份同名同值的 `DEFAULT_*`（以及镜像地址），改动一处时要同步另一处。
注意：`bash < install.sh`（从标准输入执行）不受支持——内嵌 heredoc 会与脚本本身争夺 stdin；请用 `bash install.sh` 或 `curl -fsSL <url> | bash -s --`。

## 环境要求

- 编译工具链不是必需项：dsh 及其依赖都使用预编译产物，安装器不会安装、也不再提供任何安装选项。如果将来某个依赖需要本地编译，请自行用发行版包管理器安装 `gcc`/`g++`/`make`（Debian 系 `sudo apt-get install -y build-essential`；AlmaLinux / RHEL / CentOS / Fedora 系 `sudo dnf install -y gcc gcc-c++ make`）。
- 用户级 systemd 可用（`systemctl --user`）。
- `sudo`（仅用于 `loginctl enable-linger`；可跳过）。
- 网络：默认使用国内镜像（npm 与 Node 二进制走 npmmirror，nvm 的安装脚本与仓库走 Gitee），不需要访问 `raw.githubusercontent.com` / `nodejs.org`；需要官方源时加 `--no-mirror`，单项也可用 `DSH_SERVICE_NPM_REGISTRY` / `DSH_SERVICE_NODE_MIRROR` 覆盖。系统包管理器（`apt`/`dnf`/`yum`）的软件源一律不改动。
- 不要用 `root` 运行（确需时加 `--allow-root`）。

## 文件位置

| 路径 | 内容 |
|---|---|
| `~/.local/bin/dshctl` | 服务管理工具 |
| `~/.local/bin/dsh` | 指向全局 dsh 的稳定入口（不随 nvm 默认版本漂移） |
| `~/.config/dsh-service/config` | dshctl / install.sh 共用配置 |
| `~/.config/systemd/user/dsh.service` | systemd 单元（改动前会备份为 `dsh.service.bak`） |
| `~/.dsh/` | DSH_HOME：profile（插件在 `profiles/<profile>/`）、会话、凭证等 |

## dshctl 命令

| 命令 | 作用 |
|---|---|
| `dshctl status` | 服务状态 + dsh/node 版本 + 监听端口 |
| `dshctl start` / `stop` / `restart` | 启停；`restart` 会先按配置重写单元 |
| `dshctl enable` / `disable` | 开机自启的开/关 |
| `dshctl url [--plain] [--wait N]` | 打印带 token 的登录链接；`--plain` 去掉 token，`--wait` 等待启动 |
| `dshctl logs [-f] [-n N]` | 查看日志（透传 `journalctl --user`） |
| `dshctl doctor [--fix]` | 环境自检；`--fix` 修复可自动修复项 |
| `dshctl version` | 版本信息 |
| `dshctl config [edit]` | 查看 / 编辑配置 |
| `dshctl upgrade [next\|<版本>] [--check] [--yes] [--no-restart]` | 升级 dsh（省略目标时用默认通道 next，见下） |
| `dshctl upgrade --list [N]` | 列出 registry 上的可用版本（最新在前，标记 dist-tag） |
| `dshctl upgrade-node [<主版本>]` | 升级 Node，并按默认通道 next 重装 dsh（pnpm 一并重装）、重写单元 |
| `dshctl run [-- 参数...]` | 前台运行 `dsh web`，便于调试 |
| `dshctl plugins list` | 列出当前 profile 已安装的插件 |
| `dshctl plugins reset [--yes] [--no-restart]` | 移除当前 profile 全部已安装插件（保留配置，见下） |
| `dshctl export [-o FILE] [--no-sessions] [--with-secrets] [--no-attachments] [--force]` | 把服务配置与 DSH_HOME 导出为 tar.gz（见下） |
| `dshctl import <归档.tar.gz> [--yes] [--no-config] [--no-restart] [--install-plugins] [--dry-run]` | 在新环境导入归档（见下） |
| `dshctl uninstall [--purge] [--remove-dsh-home] [--remove-node] [--yes]` | 卸载 |

## 配置文件

`~/.config/dsh-service/config` 中每项都是「默认值」语义（`:=`），因此**环境变量优先**：

```sh
# 临时换端口重启
DSH_SERVICE_PORT=4000 dshctl restart
# 永久修改
dshctl config edit && dshctl restart
```

| 键 | 默认值 | 说明 |
|---|---|---|
| `DSH_SERVICE_NAME` | `dsh` | 单元名（`dsh.service`） |
| `DSH_SERVICE_PROFILE` | `web` | 启动的 profile |
| `DSH_SERVICE_HOST` | `127.0.0.1` | 监听地址（仅支持回环，`0.0.0.0` 请自行写 patch） |
| `DSH_SERVICE_PORT` | `3080` | 监听端口 |
| `DSH_SERVICE_DSH_HOME` | `~/.dsh` | DSH_HOME（`DSH_*` 不能写进 `.env`，只能由单元环境提供） |
| `DSH_SERVICE_NVM_DIR` | `~/.nvm` | nvm 目录 |
| `DSH_SERVICE_NODE_BIN_DIR` | 安装时解析 | Node bin 目录，写入单元的 `PATH` |
| `DSH_SERVICE_LOCAL_BIN` | `~/.local/bin` | 用户级可执行目录 |
| `DSH_SERVICE_EXTRA_ARGS` | 空 | 追加到 `dsh web` 的参数，如 `--trusted-host example.com`；按 systemd `ExecStart` 语法书写（含空格的参数要加引号），字面量 `%` 会被自动转义为 `%%` |
| `DSH_SERVICE_MIRROR` | `1` | `1`=国内镜像、`0`=官方源；`dshctl upgrade` / `upgrade-node` 据此选择 npm registry 与 Node 下载源 |
| `DSH_SERVICE_NPM_REGISTRY` | `https://registry.npmmirror.com` | npm registry（`DSH_SERVICE_MIRROR=0` 时为 `https://registry.npmjs.org`） |
| `DSH_SERVICE_NODE_MIRROR` | `https://npmmirror.com/mirrors/node` | nvm 下载 Node 二进制的镜像（空=官方 `nodejs.org`） |

> **代理不在这里配置**：dsh 只读启动时的环境变量，用 systemd drop-in 注入，见 [配置代理](#配置代理)。
>
> 配置文件的取值会由 shell `source` 执行（这是 `: "${VAR:=...}"` 语法的前提），等同一段可执行代码：请勿使用来自不可信来源的配置文件，也不要写入 `$(...)`/反引号。
>
> 重跑 `install.sh` 时若 `--name` 与上次不同，脚本会在新单元渲染成功后停用并删除旧单元，避免两个实例抢同一端口。

## 远程访问

服务只监听回环地址，推荐用 SSH 端口转发：

```sh
ssh -N -L 3080:127.0.0.1:3080 <主机>
```

然后在本机浏览器打开 `dshctl url` 输出的链接。**不要**把端口直接暴露到公网：`dsh web` 没有 TLS，且浏览器 cookie 未标记 `Secure`。

## 配置模型密钥

在 Web 界面打开 **设置 → 模型**，填入 `DEEPSEEK_API_KEY`。密钥由 `dsh-credentials-local` 保存在 `~/.dsh/.credentials.yaml`，不经过任何安装脚本。

## 配置代理

dsh 没有代理配置文件，只读**进程环境变量**，并且**只在启动时读取一次**——改完必须重启服务（`dshctl restart`）。变量名小写优先：

| 变量 | 说明 |
|---|---|
| `http_proxy` / `HTTP_PROXY` | `http://` 目标使用的代理 |
| `https_proxy` / `HTTPS_PROXY` | `https://` 目标使用的代理；未设置时依次回退到 `http_proxy`、`all_proxy` |
| `all_proxy` / `ALL_PROXY` | 兜底值 |
| `no_proxy` / `NO_PROXY` | 不走代理的列表；`localhost`、`127.0.0.1`、`::1` 会自动加入，也可写 `*` 全部绕过 |

地址必须是 `http://` 或 `https://`：`socks5://` 不受支持，会被忽略、只在日志里留一条诊断，然后**直连**。经代理的请求由代理解析目标域名，dsh 不再做公网 IP 校验——这也是解决 [故障排查](#故障排查) 里 `resolves to a non-public IP address` 报错的方式。

### systemd 服务（推荐）

`dshctl restart` 会**重写** `~/.config/systemd/user/dsh.service`，所以不要直接改单元文件，用 drop-in（`install.sh` / `dshctl` 都不会覆盖它）：

```sh
mkdir -p ~/.config/systemd/user/dsh.service.d
cat > ~/.config/systemd/user/dsh.service.d/proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7897"
Environment="HTTPS_PROXY=http://127.0.0.1:7897"
Environment="http_proxy=http://127.0.0.1:7897"
Environment="https_proxy=http://127.0.0.1:7897"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF

systemctl --user daemon-reload
systemctl --user restart dsh.service
systemctl --user show dsh.service -p Environment   # 确认变量已注入
```

把 `7897` 换成实际端口：Clash Verge 默认混合端口是 `7897`，Clash for Windows / mihomo 常见为 `7890` / `7892`；**混合端口（HTTP 与 SOCKS 同一个端口）可以直接当 HTTP 代理填**。

> WSL 里代理跑在 Windows 侧时：镜像网络模式下 `127.0.0.1` 可直接用；NAT 模式要填 Windows 主机 IP，并让代理程序接受来自局域网的连接（Clash 侧 `allow-lan: true`）。

### 前台运行（临时验证）

```sh
HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 dshctl run
```

### 验证

```sh
# 代理本身可达：返回任意 HTTP 状态码都说明隧道建立成功
curl -x http://127.0.0.1:7897 -sS -o /dev/null -w '%{http_code}\n' https://raw.githubusercontent.com/robots.txt

# dsh 侧没有“代理被忽略”的诊断（SOCKS / 非法 URL 会以 `dsh: ` 前缀写日志）
dshctl logs -n 40 | grep -i proxy || echo "无代理相关诊断"
```

生效范围与副作用：

- 经代理的是 dsh 主进程的**全部**出站 HTTP，不只是网页抓取，**包括模型 API 请求**。国内流量仍按上游分流规则直连；自建 / 内网模型端点请加进 `NO_PROXY`——条目按主机名匹配（`example.com` 也匹配其子域，可写 `主机:端口`），**不支持 CIDR**，网段要逐个写主机名。
- 回环地址永远绕过代理，Web UI（`127.0.0.1:3080`）与本地服务不受影响。
- 模型生成的脚本运行在独立 worker 线程中，**不会**继承代理（避免把可能含凭据的代理 URL 交给不可信脚本）。
- 代理需要认证时写 `http://user:pass@host:port`。systemd 会对 `%` 做说明符展开，密码含 `%` 需写成 `%%`；`Environment=` 里的双引号需转义为 `\"`。
- 只有**走了代理**的目标才跳过域名解析与公网 IP 校验；被 `NO_PROXY` 命中而直连的目标照旧校验，因此把域名绕过代理、又恰好解析到 fake-ip 时仍会报那个错。
- `dshctl uninstall` 只删除主单元文件，会残留 `dsh.service.d/`：不再需要代理时执行 `rm -rf ~/.config/systemd/user/dsh.service.d` 再 `daemon-reload`，否则下次以同名单元重装时会静默套用旧代理。

## 升级与回滚

```sh
dshctl upgrade --list           # 列出可用版本（最新在前，标记 latest/next 等 dist-tag，默认 20 条）
dshctl upgrade --list 5         # 只看最近 5 个版本
dshctl upgrade --check          # 只看是否有新版本
dshctl upgrade                  # 升级到默认通道 next 并重启服务
dshctl upgrade latest           # 显式升级到 latest（dist-tags 里的任意 tag 都可用）
dshctl upgrade 0.1.5-rc.1       # 升级/切换到指定版本
dshctl upgrade-node 24          # 换 Node 主版本，并按默认通道 next 重装 dsh（pnpm 一并重装）
```

`--list` 是只读查询：不安装、不重启服务，也不要求已安装 dsh，可用于确认某个版本或 dist-tag 是否存在。

`--yes` 只是为脚本兼容而保留（该命令本身不提问）。

省略目标时 `upgrade` 跟随**默认通道 `next`**（查询 registry 的 dist-tags 解析成具体版本），与 `install.sh` 新安装的默认通道一致；`dshctl upgrade latest` 或具体版本可显式覆盖。默认通道解析失败（registry 不可达）时会报错退出 1，不会静默换成别的版本。显式指定的版本或 dist-tag 会**在安装前**先向 registry 校验：不存在时立即报错（退出 1），并提示 `dshctl upgrade --list` 与默认通道 `next` 的当前版本，不会去动已安装的 dsh。校验期间 registry 不可达时只告警并继续安装；若 `npm install` 仍以「无匹配版本」失败，也会打印同一提示作为兜底。

`upgrade` 的流程是：记录当前版本 → 安装目标版本 → 校验版本 → 刷新入口 → 重启并等待 `active`；任何一步失败都会**自动回滚到之前的版本**并返回非 0。

`upgrade-node` 会在换 Node 主版本后重装 dsh 与 pnpm（pnpm 与 dsh 一样装在当前 Node 的全局 npm 前缀下，换 Node 后需要重装；pnpm 重装失败只告警）。重装的 dsh 是**默认通道 `next` 指向的版本**，而不是升级前的旧版本；需要停在某个版本时请在该命令后用 `dshctl upgrade <版本>` 指定。

## 重置插件

profile 的插件以依赖形式记录在 `~/.dsh/profiles/<profile>/package.json` 中。`dshctl plugins reset` 会移除其中**全部**已安装插件并恢复随附 bundle，但**不触碰配置**：

```sh
dshctl plugins list                        # 先看看装了哪些
dshctl plugins reset                       # 交互确认后：停服务 → 清理 → 重启
dshctl plugins reset --yes                 # 非交互（脚本 / CI）
dshctl plugins reset --yes --no-restart    # 只清理，稍后自行 dshctl restart
```

清理范围：插件依赖、它们在 `dsh.profile.bundles` 中的条目、`profiles/<profile>/node_modules` 与 `pnpm-lock.yaml`；原 manifest 会备份为 `package.json.bak`。以下内容保持不变：

- `~/.config/dsh-service/config`（端口、DSH_HOME 等）
- `~/.dsh/settings.yaml` 与 `~/.dsh/.credentials.yaml`（模型密钥等）
- `~/.dsh/profiles/<profile>/cordis.patch.yml`（profile 的用户 patch 层）

> 若 patch 层引用了已被移除的插件，重启后按 `dshctl logs -n 30` 的提示调整该文件即可。

## 导出与导入

把一台机器上的服务配置与 DSH_HOME（会话、附件、profile、settings）打包，在新环境还原：

```sh
# 源机器：导出（默认不含凭证）
dshctl export                                        # ./dsh-service-export-<主机>-<时间>.tar.gz
dshctl export -o /tmp/dsh.tgz                        # 指定路径
dshctl export --with-secrets                         # 连同 ~/.dsh/.credentials.yaml（API Key）一起导出
dshctl export --no-sessions                          # 只要配置，不要会话

# 传输到新机器（先跑过 install.sh），再导入
scp /tmp/dsh.tgz 新主机:/tmp/
dshctl import /tmp/dsh.tgz --dry-run                 # 先看会做什么
dshctl import /tmp/dsh.tgz --yes                     # 应用配置 + DSH_HOME，然后重启
dshctl import /tmp/dsh.tgz --yes --install-plugins   # 顺便重装 profile 插件
```

归档内容（tar.gz）：

| 条目 | 内容 |
|---|---|
| `manifest` | 导出元数据与可移植的服务配置（纯 `KEY=VALUE` 文本，导入时逐行读取，绝不 source） |
| `config/dsh-service.config` | 源机器的配置副本，仅供查看（导入只读 `manifest`） |
| `dsh-home/...` | DSH_HOME 内容：`settings.yaml`、`profiles/`、`sessions/`、`attachments/`、`storages/` 等 |

- **默认不含凭证**：`.credentials.yaml`（内含 `DEEPSEEK_API_KEY` 等）只在 `--with-secrets` 时导出，届时归档权限收紧为 `0600` 并给出告警；也可以照旧在新环境用 Web 界面重新填密钥。
- **不含 `node_modules`**：插件依赖不打包（体积大，且可能需要在目标平台重新构建）。导入后会提示执行 `dsh plugin --profile <profile> install`，或用 `dshctl import --install-plugins` 自动完成。
- **配置只应用可移植项**：`profile` / `host` / `port` / `extra args` 会从归档写入；`DSH_HOME`、nvm 目录、node bin 目录与单元名保留新环境的取值——它们指向具体主机的路径，照搬旧值会让新环境起不来。
- **合并而非清空**：DSH_HOME 按文件合并，被覆盖的文件就地备份为 `<文件>.~1~`，原配置备份为 `config.bak-<时间戳>`；归档里没有的文件（如已装好的 `node_modules`）保持不变。
- 导入默认「停服务 → 落盘 → 重启」；`--no-restart` 只落盘不动服务，`--no-config` 只导入 DSH_HOME；非交互式环境必须加 `--yes`。
- 归档可能包含会话内容（敏感数据），请只通过可信通道传输。

> 会话目录名由工作目录路径编码（如 `--mnt-d-Documents-Workspace-foo--`）；新机器上工作目录路径不同时，会话仍会保留，只是按新的路径归档显示。

## 卸载

```sh
dshctl uninstall                        # 停服务、删单元与入口
dshctl uninstall --purge                # 连同配置和 ~/.bashrc 中的块一起清理
dshctl uninstall --purge --remove-dsh-home   # 再删除 ~/.dsh（会话/凭证）
```

npm 全局包与 nvm 默认保留；`pnpm` 是通用工具，`dshctl uninstall` 不会卸载它：

```sh
npm uninstall -g @deepseek-ai/dsh
npm uninstall -g pnpm          # 如不再需要 pnpm 再手动卸载
```

## 故障排查

**`无法连接用户级 systemd`**

- WSL：在 `/etc/wsl.conf` 加入

  ```ini
  [boot]
  systemd=true
  ```

  然后 `wsl --shutdown` 重开终端；再执行 `bash install.sh`。
- SSH / CI 等非登录会话：`sudo loginctl enable-linger $USER`，或改在本机登录终端运行。
- 容器：需要以 systemd 为 PID 1 运行。

**开机后服务没起来**：确认 `loginctl show-user $USER -p Linger` 为 `yes`；`dshctl doctor` 会检查这一项。

**`dshctl logs` 报 `No journal files were opened due to insufficient permissions`**

- AlmaLinux / RHEL 系默认使用持久化 journal（`/var/log/journal`），普通用户必须属于 `systemd-journal` 组才能读取：

  ```sh
  sudo usermod -aG systemd-journal "$USER"   # 重新登录后生效
  ```
- `dshctl logs` / `dshctl url` 会自动回退到 `sudo -n journalctl -t dsh`（单元设置了 `SyslogIdentifier=dsh`）；免密 sudo 不可用时，会提示手动执行 `sudo journalctl -t dsh -n 50 --no-pager`。
- `dshctl doctor` 会检查 journal 是否可读。

**Node 下载失败（`curl: (56) ... unexpected eof`、`Version '22' not found`）**

`nvm install 22` 需要联网把 “22” 解析成最新的 22.x，网络中断 / 被重置时就会失败。安装器会自动重试 `DSH_SERVICE_NODE_ATTEMPTS` 次（默认 3，间隔 `DSH_SERVICE_NODE_RETRY_DELAY` 秒）。默认已使用国内镜像（npmmirror），若该镜像也不可达，可换其它镜像或切回官方源后重跑：

```sh
DSH_SERVICE_NODE_MIRROR=https://<镜像>/node bash install.sh   # 换其它 Node 镜像
bash install.sh --no-mirror                                    # 全部切回官方源
```

- `~/.nvm` 下已经装好同主版本的 Node 时，重跑 `install.sh` 会直接复用、不再联网（要升级到该主版本的最新补丁用 `dshctl upgrade-node 24`）。默认主版本为 Node 24，但已装 Node 22 的机器重跑时仍沿用 22（`dshctl doctor` 接受 22 及以上）。
- 若 `~/.nvm` 是上次中断安装留下的残缺目录（`nvm.sh` 不完整），删除 `~/.nvm` 后重跑即可。

**`dshctl upgrade <版本>` 报「版本在 registry 上不存在」**

指定了 registry 上不存在的版本或 dist-tag（例如 `1.7.0-rc.1`）时，`upgrade` 会在安装前就拒绝，并给出默认通道 `next` 的当前版本与查看全部版本的命令，不会改动已安装的 dsh：

```sh
dshctl upgrade --list           # 看有哪些版本（最新在前，标记 latest/next 等 dist-tag）
dshctl upgrade                  # 直接升到默认通道 next
```

如果提示的是「无法确认版本 X 是否存在（registry 查询失败）」，那是 registry/网络查询本身失败（代理、镜像不可达等），命令会继续尝试安装，不会因此阻断升级。省略目标时相反：连默认通道 `next` 都解析不出来会直接报「无法解析目标版本」并退出 1，此时改用 `dshctl upgrade <具体版本>` 可绕过通道解析。

**登录链接拿不到**：token 只在服务启动时打印一次（cookie 有效期 30 天）。`dshctl logs -n 50` 查看，或 `dshctl url --wait 30`；仍拿不到就 `dshctl restart` 重新打印。

**端口被占用**：安装脚本会先做端口预检，被占用时自动改用后续空闲端口（如 3080 → 3081）并写回配置；想让它直接报错而不是自动切换，加 `--strict-port`。装好后 `dshctl status` / `dshctl doctor` 会显示监听情况；之后改端口用 `DSH_SERVICE_PORT=3081 dshctl restart` 或改配置文件。

**服务起来就退出**：`dshctl logs -n 30`；常见原因是 `dsh web --dump-config` 失败（profile/依赖问题）。

**提示 DSH_HOME 位于 `/mnt`**：WSL 的 drvfs 符号链接不可靠，建议 `DSH_SERVICE_DSH_HOME=/home/<用户>/.dsh`。

**抓取网页报 `URL hostname "…" resolves to a non-public IP address`**

dsh 的网页工具在**直连**时会先解析域名并拒绝任何非公网结果（防 DNS 重绑定）。如果系统 DNS 被代理软件的 fake-ip 接管（典型的解析结果是 `198.18.0.0/16`），这个报错必然出现——但**网络其实是通的**，用 `curl` 直接访问同一地址可以正常返回。`getent hosts <域名>` 看到 `198.18.x.x` 即可确认原因。

两种解法，二选一（也可叠加）：

1. 让 dsh 走代理，域名交给代理解析（代理路径不做该校验），见 [配置代理](#配置代理)；
2. 在 Clash / mihomo 的 `dns.fake-ip-filter` 中加入目标域名（如 `+.githubusercontent.com`、`+.github.com`），使这些域名返回真实公网 IP。

**`dshctl run`** 可以在前台直接运行，用来看第一手报错。

## install.sh 选项

```
--port N              Web 监听端口（默认 3080）
--name NAME           systemd 单元名（默认 dsh）
--node-major N        Node 主版本（默认 24；已有安装重跑时沿用配置记录的现有主版本）
--nvm-version V       nvm 版本标签（默认 v0.40.1）
--dsh-version V       @deepseek-ai/dsh 版本或 dist-tag（默认 next；已有安装重跑时保留当前版本）
--pnpm-version V      pnpm 版本或 dist-tag（默认 latest；也可用 DSH_PNPM_VERSION）
--prefix DIR          用户级可执行目录（默认 $HOME/.local/bin）
--mirror              使用国内镜像（默认；npm/Node 走 npmmirror，nvm 走 Gitee）
--no-mirror           使用官方源（registry.npmjs.org / nodejs.org / GitHub）
--no-pnpm             不安装 pnpm
--no-service          只安装并写入单元，不启用/启动服务
--no-linger           不设置 linger
--no-rc               不修改 ~/.bashrc（nvm 官方安装脚本首次安装时仍会写 ~/.bashrc）
--force               强制重装 dsh 与 pnpm
--strict-port         端口被占用时直接报错，不自动改用其它端口
--dry-run             只打印动作，不做任何修改
--allow-root          允许以 root 运行（用户级服务不推荐）
--print-dshctl        输出内嵌的 dshctl 后退出
```

相关环境变量：`DSH_SERVICE_MIRROR`（1=国内镜像、0=官方源，写入配置后 `dshctl upgrade` / `upgrade-node` 同样生效）、`DSH_SERVICE_NPM_REGISTRY` / `DSH_SERVICE_NODE_MIRROR`（自定义 npm registry 与 Node 下载源）、`DSH_NVM_INSTALL_URL` / `DSH_NVM_SOURCE`（自定义 nvm 安装脚本与仓库地址）、`DSH_NVM_INSTALL_SHA256`（固定 nvm 安装脚本摘要）、`DSH_SERVICE_NODE_ATTEMPTS` / `DSH_SERVICE_NODE_RETRY_DELAY`（Node 下载重试次数与间隔秒数）。

## 测试

```sh
bash tests/run.sh
```

测试完全离线：用桩命令（`systemctl`/`journalctl`/`npm`/`node`/`loginctl`/`ss`）在临时 HOME 中走完安装、幂等、`dshctl url`、升级回滚、`doctor`、启动崩溃检测、插件重置、导出/导入等路径，不需要网络、systemd 或 root。

## 版本管理

dsh-service 的版本号只有一个来源：`install.sh` 顶部的 `INSTALLER_VERSION` 与内嵌 `dshctl` 的 `DSHCTL_VERSION`（两者必须同值），README 顶部的版本行跟随显示。`dshctl version` / `dshctl --version` 以及导出归档 `manifest` 里的 `DSHCTL_VERSION` 都由这两个常量在运行时生成，无需单独维护。

```sh
bash scripts/bump-version.sh --check                   # 校验各处版本号一致（只读，不改文件）
bash scripts/bump-version.sh patch                     # 0.1.0 -> 0.1.1（也可用 minor / major）
bash scripts/bump-version.sh 0.2.0-rc.1                # 指定版本号；默认拒绝回退，回退需 --force
bash scripts/bump-version.sh patch --dry-run           # 只演练，不写文件
bash scripts/bump-version.sh patch --stage             # 写完后 git add install.sh README.md
```

`install.sh` 一旦有改动，提交时**自动递增 patch**：仓库自带 pre-commit 钩子，按下面方式启用（只改本仓库的本地 git 配置）：

```sh
bash scripts/install-hooks.sh             # 设置 core.hooksPath=.githooks
bash scripts/install-hooks.sh --status    # 查看状态
bash scripts/install-hooks.sh --uninstall # 停用
```

钩子行为：

- 本次提交改了 `install.sh` 而版本号未变时，自动 `patch` 递增并暂存 `install.sh` / `README.md`；
- 已手动 bump（暂存版本与 `HEAD` 不同）时只校验各处是否一致，不一致就中断提交；
- `install.sh` 存在**未暂存**改动时拒绝自动改写，避免把不打算提交的内容一并 `git add`；
- 跳过：`git commit --no-verify`，或 `DSH_SERVICE_SKIP_VERSION_BUMP=1 git commit ...`。

`bash tests/run.sh` 会校验 `install.sh` 两处常量、README 版本行与导出归档 `manifest` 的版本字段一致，并在临时仓库里验证钩子的自动递增。

## 安全说明

- 服务以你的用户身份运行；通过 Web 界面能做的事情等同于该用户终端里的 shell，请勿把端口暴露到不可信网络。
- 仅回环 HTTP，无 TLS；远程请走 SSH 隧道。
- 安装脚本不读取、不写入、不打印任何密钥。
- 通过 [配置代理](#配置代理) 注入的代理 URL 会留在 systemd 单元环境与进程环境中（`systemctl --user show dsh.service -p Environment` 可见）：若代理需要认证，别把长期凭据写进 drop-in，或至少限制该文件的权限。
- 脚本会把 nvm 安装脚本先下载到临时文件再执行，并打印其 `sha256`；需要固定时设置 `DSH_NVM_INSTALL_SHA256=<64 位十六进制>` 重新运行（校验不通过会中止）。`@deepseek-ai/dsh`、`@deepseek-ai/dsh-web-frontend` 与 `pnpm` 来自 npm registry，可用 `--dsh-version <版本>` / `--pnpm-version <版本>` 固定版本。默认经国内镜像（npmmirror / Gitee）获取这些内容，`--no-mirror` 可切回官方源；系统包管理器的软件源不会被脚本修改。
