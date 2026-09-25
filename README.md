# dsh-service

在 Linux（Ubuntu / Debian / AlmaLinux 等 + systemd）上一键安装 **DeepSeek Harness Web GUI**，并注册为**用户级 systemd 服务**，附带服务管理工具 `dshctl`。

当前版本：**v0.1.0**

- **一键安装**：单文件、幂等的 `install.sh`，自动准备 nvm / Node / dsh 并注册服务。
- **用户级服务**：由 `systemd --user` 托管，支持开机自启（linger），全程无需 root。
- **日常管理**：`dshctl` 负责状态、日志、登录链接、配置、升级与自检。
- **迁移与卸载**：可导出 / 导入整套配置与会话，卸载时按需保留数据。

---

## 目录

- [1. 快速开始](#1-快速开始)
- [2. 环境要求](#2-环境要求)
- [3. 安装](#3-安装)
  - [3.1 安装脚本做了什么](#31-安装脚本做了什么)
  - [3.2 安装选项](#32-安装选项)
- [4. 服务管理](#4-服务管理)
  - [4.1 dshctl 命令](#41-dshctl-命令)
  - [4.2 文件位置](#42-文件位置)
  - [4.3 配置文件](#43-配置文件)
  - [4.4 命令补全](#44-命令补全)
- [5. 访问与配置](#5-访问与配置)
  - [5.1 远程访问](#51-远程访问)
  - [5.2 配置模型密钥](#52-配置模型密钥)
  - [5.3 配置代理](#53-配置代理)
- [6. 升级与迁移](#6-升级与迁移)
  - [6.1 升级与回滚](#61-升级与回滚)
  - [6.2 重置插件](#62-重置插件)
  - [6.3 导出与导入](#63-导出与导入)
  - [6.4 卸载](#64-卸载)
- [7. 故障排查](#7-故障排查)
- [8. 安全说明](#8-安全说明)

---

## 1. 快速开始

**方式一：直接管道执行**

```sh
curl -fsSL https://raw.githubusercontent.com/Haraella-AI/dsh-service/main/install.sh | bash
```

**方式二：克隆后本地执行**

```sh
git clone https://github.com/Haraella-AI/dsh-service.git
cd dsh-service && bash install.sh
```

> 脚本只监听 `127.0.0.1`（上游 `dsh web` 出于安全考虑拒绝 `--host 0.0.0.0`）；远程访问见 [远程访问](#51-远程访问)。
> 脚本**不处理 API Key**，模型密钥请在 Web 界面中配置（见 [配置模型密钥](#52-配置模型密钥)）。
> 请用 `bash install.sh` 或 `curl … | bash -s --` 执行；`bash < install.sh`（从标准输入执行）不受支持。

## 2. 环境要求

- 用户级 systemd 可用（`systemctl --user`）。
- `sudo`（仅用于 `loginctl enable-linger`；可跳过）。
- 网络：默认使用国内镜像（npm 与 Node 二进制走 npmmirror，nvm 走 Gitee），不需要访问 `raw.githubusercontent.com` / `nodejs.org`；需要官方源时加 `--no-mirror`，单项也可用 `DSH_SERVICE_NPM_REGISTRY` / `DSH_SERVICE_NODE_MIRROR` 覆盖。系统包管理器（`apt`/`dnf`/`yum`）的软件源一律不改动。
- 编译工具链不是必需项：dsh 及其依赖都使用预编译产物。若将来某个依赖需要本地编译，请自行用发行版包管理器安装 `gcc`/`g++`/`make`（Debian 系 `sudo apt-get install -y build-essential`；AlmaLinux / RHEL / CentOS / Fedora 系 `sudo dnf install -y gcc gcc-c++ make`）。
- 不要用 `root` 运行（确需时加 `--allow-root`）。

## 3. 安装

### 3.1 安装脚本做了什么

`install.sh` 是单文件、幂等的脚本：每一步在已完成时会自动跳过，重复执行安全。

| # | 步骤 | 说明 |
|---|---|---|
| 1 | 端口预检 | 检查 `--port`（默认 3080）是否被占用；被占用则自动改用后续空闲端口并写回配置（`--strict-port` 改为直接报错退出） |
| 2 | 安装依赖 | 安装 nvm、Node 与全局 `@deepseek-ai/dsh`（新安装默认通道为 dist-tag `next`）；`pnpm` 为可选的附加工具，安装失败只告警，不影响服务 |
| 3 | 用户级入口 | 生成 `~/.local/bin/dsh` 与 `~/.local/bin/dshctl`，安装 bash 补全脚本到 `~/.local/share/bash-completion/completions/dshctl`（`--no-completion` 可跳过），并在 `~/.bashrc` 写入带标记的 `NVM_DIR` / nvm 加载 / PATH / 补全加载配置块（`--no-rc` 可跳过） |
| 4 | systemd 单元 | 写入 `~/.config/systemd/user/dsh.service`，执行 `daemon-reload` 并 `enable --now` |
| 5 | linger | `loginctl enable-linger $USER`，使服务在开机未登录时也能启动（`--no-linger` 可跳过） |
| 6 | 校验 | 等待服务进入 `active`（启动即崩溃会报错），并从日志中取出登录链接 |

几点与后续维护相关的行为：

- **重跑不会迁移已有安装**：配置里记录了现有 Node 主版本与 dsh 版本时，未显式传 `--node-major` / `--dsh-version` 就继续沿用；升级请用 `dshctl upgrade` / `dshctl upgrade-node`。
- Node 下限为 22（默认 24），dsh 默认通道为 `next`（`latest` 通常落后）；`--dsh-version latest` 或 `dshctl upgrade latest` 可切回 latest。
- 若 `--name` 与上次不同，脚本会在新单元渲染成功后停用并删除旧单元，避免两个实例抢同一端口。

### 3.2 安装选项

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
--no-completion       不安装 bash 补全脚本（默认安装到用户数据目录）
--force               强制重装 dsh 与 pnpm
--strict-port         端口被占用时直接报错，不自动改用其它端口
--dry-run             只打印动作，不做任何修改
--allow-root          允许以 root 运行（用户级服务不推荐）
```

相关环境变量：`DSH_SERVICE_MIRROR`（1=国内镜像、0=官方源，写入配置后 `dshctl upgrade` / `upgrade-node` 同样生效）、`DSH_SERVICE_NPM_REGISTRY` / `DSH_SERVICE_NODE_MIRROR`（自定义 npm registry 与 Node 下载源）。

## 4. 服务管理

### 4.1 dshctl 命令

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
| `dshctl upgrade [next\|<版本>] [--check] [--yes] [--no-restart]` | 升级 dsh（省略目标时用默认通道 next） |
| `dshctl upgrade --list [N]` | 列出 registry 上的可用版本（最新在前，标记 dist-tag） |
| `dshctl upgrade-node [<主版本>]` | 升级 Node，并按默认通道 next 重装 dsh（pnpm 一并重装）、重写单元 |
| `dshctl run [-- 参数...]` | 前台运行 `dsh web`，便于调试 |
| `dshctl plugins list` | 列出当前 profile 已安装的插件 |
| `dshctl plugins reset [--yes] [--no-restart]` | 移除当前 profile 全部已安装插件（保留配置） |
| `dshctl export [-o FILE] [--no-sessions] [--with-secrets] [--no-attachments] [--force]` | 把服务配置与 DSH_HOME 导出为 tar.gz |
| `dshctl import <归档.tar.gz> [--yes] [--no-config] [--no-restart] [--install-plugins] [--dry-run]` | 在新环境导入归档 |
| `dshctl uninstall [--purge] [--remove-dsh-home] [--remove-node] [--yes]` | 卸载 |
| `dshctl completion [bash]` | 输出 bash 补全脚本（安装由 `install.sh` 完成，见 [命令补全](#44-命令补全)） |

### 4.2 文件位置

| 路径 | 内容 |
|---|---|
| `~/.local/bin/dshctl` | 服务管理工具 |
| `~/.local/bin/dsh` | 指向全局 dsh 的稳定入口（不随 nvm 默认版本漂移） |
| `~/.local/share/bash-completion/completions/dshctl` | bash 补全脚本（`XDG_DATA_HOME` 生效时跟随；`--no-completion` 不安装） |
| `~/.config/dsh-service/config` | dshctl / install.sh 共用配置 |
| `~/.config/systemd/user/dsh.service` | systemd 单元（改动前会备份为 `dsh.service.bak`） |
| `~/.dsh/` | DSH_HOME：profile（插件在 `profiles/<profile>/`）、会话、凭证等 |

### 4.3 配置文件

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

> **代理不在这里配置**：dsh 只读启动时的环境变量，用 systemd drop-in 注入，见 [配置代理](#53-配置代理)。
>
> 配置文件会被 shell `source` 执行（这是 `: "${VAR:=...}"` 语法的前提），等同一段可执行代码：请勿使用来自不可信来源的配置文件，也不要写入 `$(...)` / 反引号。

### 4.4 命令补全

`install.sh` 默认安装 bash 补全：脚本写到 `~/.local/share/bash-completion/completions/dshctl`，并在 `~/.bashrc` 的 dsh-service 代码块里加载。**新开终端**或执行 `exec bash` 后生效。目前只支持 bash；脚本不依赖 `bash-completion` 软件包，补全过程也不联网。

```sh
dshctl <TAB>              # 子命令
dshctl upgrade -<TAB>     # 该命令接受的选项
dshctl plugins <TAB>      # 二级子命令：list / ls / reset
dshctl config <TAB>       # edit
dshctl import <TAB>       # 归档文件路径
dshctl export -o <TAB>    # 输出文件路径
```

- 补全项由 `dshctl` 的命令表统一生成，因此不会出现「补全提示了某个命令、敲下去却报未知命令」。
- 隐藏的内部命令（`_render-config` / `_render-unit` / `_enable` / `_linger`）不出现在补全里。
- `dshctl upgrade <TAB>` 只提示 `next` / `latest` 两个常用通道，**这只是提示**：registry 上任意 dist-tag 都可用，可用版本以 `dshctl upgrade --list` 为准。
- 手动安装（例如没跑过 `install.sh`，或想放到别的目录）：`dshctl completion bash > <路径>`，再把该路径 `source` 进 `~/.bashrc`。
- 两个开关互相独立：`--no-completion` 不安装脚本；`--no-rc` 不写 `~/.bashrc`（脚本仍会安装，可自行 source 一行）。

## 5. 访问与配置

### 5.1 远程访问

服务只监听回环地址，推荐用 SSH 端口转发：

```sh
ssh -N -L 3080:127.0.0.1:3080 <主机>
```

然后在本机浏览器打开 `dshctl url` 输出的链接。**不要**把端口直接暴露到公网：`dsh web` 没有 TLS，且浏览器 cookie 未标记 `Secure`。

### 5.2 配置模型密钥

在 Web 界面打开 **设置 → 模型**，填入 `DEEPSEEK_API_KEY`。密钥由 `dsh-credentials-local` 保存在 `~/.dsh/.credentials.yaml`，不经过任何安装脚本。

### 5.3 配置代理

dsh 没有代理配置文件，只读**进程环境变量**，并且**只在启动时读取一次**——改完必须重启服务（`dshctl restart`）。变量名小写优先：

| 变量 | 说明 |
|---|---|
| `http_proxy` / `HTTP_PROXY` | `http://` 目标使用的代理 |
| `https_proxy` / `HTTPS_PROXY` | `https://` 目标使用的代理；未设置时依次回退到 `http_proxy`、`all_proxy` |
| `all_proxy` / `ALL_PROXY` | 兜底值 |
| `no_proxy` / `NO_PROXY` | 不走代理的列表；`localhost`、`127.0.0.1`、`::1` 会自动加入，也可写 `*` 全部绕过 |

地址必须是 `http://` 或 `https://`：`socks5://` 不受支持，会被忽略、只在日志里留一条诊断，然后**直连**。经代理的请求由代理解析目标域名，dsh 不再做公网 IP 校验——这也是解决 [故障排查](#7-故障排查) 里 `resolves to a non-public IP address` 报错的方式。

**systemd 服务（推荐）**：`dshctl restart` 会**重写** `~/.config/systemd/user/dsh.service`，所以不要直接改单元文件，用 drop-in（`install.sh` / `dshctl` 都不会覆盖它）：

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

**前台运行（临时验证）**：

```sh
HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 dshctl run
```

**验证**：

```sh
# 代理本身可达：返回任意 HTTP 状态码都说明隧道建立成功
curl -x http://127.0.0.1:7897 -sS -o /dev/null -w '%{http_code}\n' https://raw.githubusercontent.com/robots.txt

# dsh 侧没有“代理被忽略”的诊断（SOCKS / 非法 URL 会以 `dsh: ` 前缀写日志）
dshctl logs -n 40 | grep -i proxy || echo "无代理相关诊断"
```

生效范围与副作用：

- 经代理的是 dsh 主进程的**全部**出站 HTTP，不只是网页抓取，**包括模型 API 请求**；自建 / 内网模型端点请加进 `NO_PROXY`。条目按主机名匹配（`example.com` 也匹配其子域，可写 `主机:端口`），**不支持 CIDR**，网段要逐个写主机名。
- 回环地址永远绕过代理，Web UI（`127.0.0.1:3080`）与本地服务不受影响。
- 模型生成的脚本运行在独立 worker 线程中，**不会**继承代理。
- 代理需要认证时写 `http://user:pass@host:port`；`Environment=` 里的双引号需转义为 `\"`，密码含 `%` 需写成 `%%`。
- 只有**走了代理**的目标才跳过域名解析与公网 IP 校验；被 `NO_PROXY` 命中而直连的目标照旧校验，因此把域名绕过代理、又恰好解析到 fake-ip 时仍会报那个错。
- `dshctl uninstall` 只删除主单元文件，会残留 `dsh.service.d/`：不再需要代理时执行 `rm -rf ~/.config/systemd/user/dsh.service.d` 再 `daemon-reload`，否则下次以同名单元重装时会静默套用旧代理。

## 6. 升级与迁移

### 6.1 升级与回滚

```sh
dshctl upgrade --list           # 列出可用版本（最新在前，标记 latest/next 等 dist-tag，默认 20 条）
dshctl upgrade --list 5         # 只看最近 5 个版本
dshctl upgrade --check          # 只看是否有新版本
dshctl upgrade                  # 升级到默认通道 next 并重启服务
dshctl upgrade latest           # 显式升级到 latest（dist-tags 里的任意 tag 都可用）
dshctl upgrade 0.1.5-rc.1       # 升级/切换到指定版本
dshctl upgrade-node 24          # 换 Node 主版本，并按默认通道 next 重装 dsh（pnpm 一并重装）
```

- `--list` 是只读查询：不安装、不重启服务，也不要求已安装 dsh。
- 省略目标时跟随**默认通道 `next`**；显式指定的版本或 dist-tag 会**在安装前**先向 registry 校验，不存在时立即报错退出，不会改动已安装的 dsh。通道解析失败（registry 不可达）同样报错退出 1，不会静默换成别的版本。
- `upgrade` 的流程是：记录当前版本 → 安装目标版本 → 校验版本 → 刷新入口 → 重启并等待 `active`；任何一步失败都会**自动回滚到之前的版本**并返回非 0。
- `upgrade-node` 重装的是**默认通道 `next` 指向的版本**，而不是升级前的旧版本；需要停在某个版本时请在该命令后用 `dshctl upgrade <版本>` 指定。

### 6.2 重置插件

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

### 6.3 导出与导入

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
| `manifest` | 导出元数据与可移植的服务配置 |
| `config/dsh-service.config` | 源机器的配置副本，仅供查看（导入只读 `manifest`） |
| `dsh-home/...` | DSH_HOME 内容：`settings.yaml`、`profiles/`、`sessions/`、`attachments/`、`storages/` 等 |

- **默认不含凭证**：`.credentials.yaml`（内含 `DEEPSEEK_API_KEY` 等）只在 `--with-secrets` 时导出，届时归档权限收紧为 `0600` 并给出告警；也可以照旧在新环境用 Web 界面重新填密钥。
- **不含 `node_modules`**：插件依赖不打包。导入后会提示执行 `dsh plugin --profile <profile> install`，或用 `dshctl import --install-plugins` 自动完成。
- **配置只应用可移植项**：`profile` / `host` / `port` / `extra args` 会从归档写入；`DSH_HOME`、nvm 目录、node bin 目录与单元名保留新环境的取值——它们指向具体主机的路径，照搬旧值会让新环境起不来。
- **合并而非清空**：DSH_HOME 按文件合并，被覆盖的文件就地备份为 `<文件>.~1~`，原配置备份为 `config.bak-<时间戳>`。
- 导入默认「停服务 → 落盘 → 重启」；`--no-restart` 只落盘不动服务，`--no-config` 只导入 DSH_HOME；非交互式环境必须加 `--yes`。
- 归档可能包含会话内容（敏感数据），请只通过可信通道传输。

> 会话目录名由工作目录路径编码（如 `--mnt-d-Documents-Workspace-foo--`）；新机器上工作目录路径不同时，会话仍会保留，只是按新的路径归档显示。

### 6.4 卸载

```sh
dshctl uninstall                        # 停服务、删单元、入口与补全脚本
dshctl uninstall --purge                # 连同配置和 ~/.bashrc 中的块一起清理（补全 source 行随之移除）
dshctl uninstall --purge --remove-dsh-home   # 再删除 ~/.dsh（会话/凭证）
```

npm 全局包与 nvm 默认保留；`pnpm` 是通用工具，`dshctl uninstall` 不会卸载它：

```sh
npm uninstall -g @deepseek-ai/dsh
npm uninstall -g pnpm          # 如不再需要 pnpm 再手动卸载
```

## 7. 故障排查

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

安装器会自动重试；默认已使用国内镜像（npmmirror）。若该镜像也不可达，可换其它镜像或切回官方源后重跑：

```sh
DSH_SERVICE_NODE_MIRROR=https://<镜像>/node bash install.sh   # 换其它 Node 镜像
bash install.sh --no-mirror                                    # 全部切回官方源
```

- `~/.nvm` 下已经装好同主版本的 Node 时，重跑 `install.sh` 会直接复用、不再联网（要升级到该主版本的最新补丁用 `dshctl upgrade-node 24`）。默认主版本为 Node 24，但已装 Node 22 的机器重跑时仍沿用 22（`dshctl doctor` 接受 22 及以上）。
- 若 `~/.nvm` 是上次中断安装留下的残缺目录（`nvm.sh` 不完整），删除 `~/.nvm` 后重跑即可。

**`dshctl upgrade <版本>` 报「版本在 registry 上不存在」**

指定的版本或 dist-tag 在 registry 上不存在时，`upgrade` 会在安装前就拒绝，并给出默认通道 `next` 的当前版本，不会改动已安装的 dsh：

```sh
dshctl upgrade --list           # 看有哪些版本（最新在前，标记 latest/next 等 dist-tag）
dshctl upgrade                  # 直接升到默认通道 next
```

如果提示的是「无法确认版本 X 是否存在（registry 查询失败）」，那是 registry/网络查询本身失败（代理、镜像不可达等），命令会继续尝试安装；此时也可改用 `dshctl upgrade <具体版本>` 绕过通道解析。

**登录链接拿不到**：token 只在服务启动时打印一次（cookie 有效期 30 天）。`dshctl logs -n 50` 查看，或 `dshctl url --wait 30`；仍拿不到就 `dshctl restart` 重新打印。

**端口被占用**：安装时会被自动顺延并写回配置（`--strict-port` 改为报错）。装好后 `dshctl status` / `dshctl doctor` 会显示监听情况；之后改端口用 `DSH_SERVICE_PORT=3081 dshctl restart` 或改配置文件。

**服务起来就退出**：`dshctl logs -n 30`；常见原因是 `dsh web --dump-config` 失败（profile/依赖问题）。

**提示 DSH_HOME 位于 `/mnt`**：WSL 的 drvfs 符号链接不可靠，建议 `DSH_SERVICE_DSH_HOME=/home/<用户>/.dsh`。

**抓取网页报 `URL hostname "…" resolves to a non-public IP address`**

dsh 的网页工具在**直连**时会先解析域名并拒绝任何非公网结果（防 DNS 重绑定）。如果系统 DNS 被代理软件的 fake-ip 接管（典型的解析结果是 `198.18.0.0/16`），这个报错必然出现——但**网络其实是通的**，用 `curl` 直接访问同一地址可以正常返回。`getent hosts <域名>` 看到 `198.18.x.x` 即可确认原因。

两种解法，二选一（也可叠加）：

1. 让 dsh 走代理，域名交给代理解析（代理路径不做该校验），见 [配置代理](#53-配置代理)；
2. 在 Clash / mihomo 的 `dns.fake-ip-filter` 中加入目标域名（如 `+.githubusercontent.com`、`+.github.com`），使这些域名返回真实公网 IP。

**`dshctl run`** 可以在前台直接运行，用来看第一手报错。

## 8. 安全说明

- 服务以你的用户身份运行；通过 Web 界面能做的事情等同于该用户终端里的 shell，请勿把端口暴露到不可信网络。
- 仅回环 HTTP，无 TLS；远程请走 SSH 隧道。
- 安装脚本不读取、不写入、不打印任何密钥。
- 通过 [配置代理](#53-配置代理) 注入的代理 URL 会留在 systemd 单元环境与进程环境中（`systemctl --user show dsh.service -p Environment` 可见）：若代理需要认证，别把长期凭据写进 drop-in，或至少限制该文件的权限。
- `@deepseek-ai/dsh` 与 `pnpm` 来自 npm registry，可用 `--dsh-version <版本>` / `--pnpm-version <版本>` 固定版本。默认经国内镜像（npmmirror / Gitee）获取这些内容，`--no-mirror` 可切回官方源；系统包管理器的软件源不会被脚本修改。
