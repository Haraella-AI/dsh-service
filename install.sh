#!/usr/bin/env bash
# =============================================================================
#  dsh-service —— DeepSeek Harness 一键安装脚本
#
#  依次完成（可重复执行，幂等）：
#    0. 端口预检（被占用时自动改用后续空闲端口；--strict-port 则报错退出）
#    1. 安装 nvm 并安装 Node.js 24（默认；已有安装沿用其现有 Node 主版本）
#    2. npm 全局安装 @deepseek-ai/dsh（默认通道 next），并在 ~/.local/bin 建立稳定入口
#    3. npm 全局安装 pnpm（可选；失败只告警，不影响 dsh 服务）
#    4. 写入并启用用户级 systemd 服务（dsh web），同时安装 dshctl 管理工具
#
#  用法：
#    bash install.sh [选项]
#    curl -fsSL <本脚本 raw 地址> | bash -s -- [选项]
#    bash install.sh --help
#
#  说明：本脚本不处理 DEEPSEEK_API_KEY，模型密钥请在 Web 界面中配置。
# =============================================================================
set -Eeuo pipefail
LC_ALL=C
export LC_ALL

INSTALLER_VERSION="0.1.0"

# ─────────────────────────────────────────────────────────────────────────────
#  内嵌的 dshctl（唯一来源）。install.sh 会把它写到 <prefix>/dshctl；
#  修改本段后重新运行 install.sh 即可更新（也可用 --print-dshctl 导出比对）。
# ─────────────────────────────────────────────────────────────────────────────
IFS= read -r -d '' DSHCTL_SRC <<'DSHCTL_EMBED_EOF' || true
#!/usr/bin/env bash
# =============================================================================
#  dshctl —— DeepSeek Harness 服务管理工具
#
#  由 dsh-service 的 install.sh 生成；请勿手工编辑（会被覆盖）。
#  配置文件：~/.config/dsh-service/config
# =============================================================================
set -Eeuo pipefail

DSHCTL_VERSION="0.1.0"

# USER 并非在所有环境都存在（cron / 精简容器 / 部分 systemd 会话）；set -u 下直接
# 引用 $USER 会让脚本以 “USER: unbound variable” 崩溃。
: "${USER:=$(id -un 2>/dev/null || printf unknown)}"

# HOME 同理：下面的 $HOME/.config、$HOME/.dsh 默认值会在 set -u 下先于任何检查崩溃。
if [ -z "${HOME:-}" ]; then
	printf 'ERROR 缺少 HOME 环境变量（无法定位 ~/.config 与 ~/.dsh）\n' >&2
	exit 1
fi

# 临时文件登记表：任何退出路径（含报错、Ctrl-C）都会清理，避免残留
# .config.XXXXXX / .dsh-unit.XXXXXX。
TMP_FILES=()
# 条目既可能是 mktemp 文件，也可能是 export/import 用的临时目录，一律用 -rf 清理。
cleanup_tmp() {
	local f
	for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
		rm -rf -- "$f" 2>/dev/null || true
	done
	return 0
}
trap cleanup_tmp EXIT

# ── 配置 ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="${DSHCTL_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-service}"
CONFIG_FILE="$CONFIG_DIR/config"

if [ -r "$CONFIG_FILE" ]; then
	if ! bash -n -- "$CONFIG_FILE" 2>/dev/null; then
		printf 'ERROR 配置文件语法错误: %s\n' "$CONFIG_FILE" >&2
		printf '  修复: %s %s\n' "${EDITOR:-vi}" "$CONFIG_FILE" >&2
		printf '  或删除该文件后重新运行 install.sh\n' >&2
		exit 1
	fi
	# shellcheck source=/dev/null
	. "$CONFIG_FILE"
fi

# := 语义：环境变量优先于配置文件，配置文件优先于内置默认值。
: "${DSH_SERVICE_NAME:=dsh}"
: "${DSH_SERVICE_PROFILE:=web}"
: "${DSH_SERVICE_HOST:=127.0.0.1}"
: "${DSH_SERVICE_PORT:=3080}"
: "${DSH_SERVICE_DSH_HOME:=$HOME/.dsh}"
: "${DSH_SERVICE_NVM_DIR:=$HOME/.nvm}"
: "${DSH_SERVICE_NODE_BIN_DIR:=}"
: "${DSH_SERVICE_LOCAL_BIN:=$HOME/.local/bin}"
: "${DSH_SERVICE_EXTRA_ARGS:=}"

# 镜像：默认走国内源（npm registry 用 npmmirror，nvm 下载 Node 二进制也用
# npmmirror）。系统包管理器（apt/dnf/yum）的软件源不在本工具的管辖范围，绝不修改。
: "${DSH_SERVICE_MIRROR:=1}"
if [ "$DSH_SERVICE_MIRROR" = 0 ]; then
	: "${DSH_SERVICE_NPM_REGISTRY:=https://registry.npmjs.org}"
	: "${DSH_SERVICE_NODE_MIRROR:=}"
else
	: "${DSH_SERVICE_NPM_REGISTRY:=https://registry.npmmirror.com}"
	: "${DSH_SERVICE_NODE_MIRROR:=https://npmmirror.com/mirrors/node}"
fi

# 端口校验（环境变量 / 配置文件都可能给出非法值）。
case "$DSH_SERVICE_PORT" in
	''|*[!0-9]*) printf 'ERROR 端口必须是数字: %s\n' "$DSH_SERVICE_PORT" >&2; exit 1 ;;
esac
if [ "${#DSH_SERVICE_PORT}" -gt 5 ] || [ "$DSH_SERVICE_PORT" -lt 1 ] || [ "$DSH_SERVICE_PORT" -gt 65535 ]; then
	printf 'ERROR 端口必须在 1-65535 之间: %s\n' "$DSH_SERVICE_PORT" >&2
	exit 1
fi
# 归一化前导零：bash 算术会把 080 当八进制（$((080)) 报错 / 010 变成 8），
# 而 awk、test 又是十进制，混用会得到错误端口。
DSH_SERVICE_PORT="$((10#$DSH_SERVICE_PORT))"

# 派生值（不写入配置，改 --name / --prefix 时自动跟随）
DSH_SERVICE_UNIT_NAME="$DSH_SERVICE_NAME.service"
DSH_SERVICE_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$DSH_SERVICE_UNIT_NAME"
DSH_SERVICE_DSH_BIN="$DSH_SERVICE_LOCAL_BIN/dsh"

# dsh 的默认通道：上游把「最新可用构建」放在 npm dist-tag next 上（latest 常常落后），
# 因此省略目标时统一跟随 next；用 `dshctl upgrade latest` 或具体版本可显式覆盖。
# 与 install.sh 安装器主体的 DSH_DEFAULT_CHANNEL 保持一致（两段脚本不能互相 source）。
DSH_DEFAULT_CHANNEL='next'

if [ -t 1 ]; then
	C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
	C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

log()  { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
	cat <<'EOF'
dshctl —— DeepSeek Harness 服务管理工具

用法: dshctl <命令> [选项]

服务控制
  start                          启动服务
  stop                           停止服务
  restart                        重启服务（先按配置重写 systemd 单元）
  status                         查看服务状态
  enable                         开机自启并立即启动
  disable                        取消开机自启

查看
  url [--plain] [--wait N]       打印带 token 的登录链接（--plain 去掉 token）
  logs [-f] [-n N]               查看服务日志（journalctl 透传）
  version                        版本信息
  config [edit]                  查看 / 编辑配置文件
  doctor [--fix]                 环境自检（--fix 修复可自动修复项）

维护
  upgrade [next|<版本>] [--check] [--yes] [--no-restart]
                                 升级 @deepseek-ai/dsh（默认通道 next；失败自动回滚）
  upgrade --list [N]             列出 registry 上的可用版本（最新在前，标记 dist-tag）
  upgrade-node [<主版本>]        升级 Node 并重装 dsh（默认通道 next）/pnpm、重写单元
  run [-- 参数...]               前台运行 dsh web（不走 systemd，便于调试）
  plugins list                   列出当前 profile 已安装的插件
  plugins reset [--yes] [--no-restart]
                                 移除全部已安装插件（保留配置）
  export [-o FILE] [--no-sessions] [--with-secrets] [--no-attachments] [--force]
                                 导出服务配置与 DSH_HOME（会话、附件等）为 tar.gz
  import <归档.tar.gz> [--yes] [--no-restart] [--install-plugins] [--dry-run]
                                 在新环境导入归档（原文件就地备份）
  uninstall [--purge] [--remove-dsh-home] [--remove-node] [--yes]
                                 卸载服务

  -h, --help                     显示本帮助
  -V, --version                  显示 dshctl 版本

环境变量可临时覆盖配置，例如：DSH_SERVICE_PORT=4000 dshctl restart
EOF
}

# ── 基础工具 ─────────────────────────────────────────────────────────────────
ensure_node_env() {
	if ! command -v node >/dev/null 2>&1 && [ -n "$DSH_SERVICE_NODE_BIN_DIR" ] && [ -x "$DSH_SERVICE_NODE_BIN_DIR/node" ]; then
		export PATH="$DSH_SERVICE_NODE_BIN_DIR:$PATH"
	fi
}

# 与 ensure_node_env 不同：无论 node 是否已在 PATH，都把配置里的 node bin 目录
# 前置，使同目录下的 pnpm（dsh plugin 的依赖）也能被找到。
ensure_node_bin_path() {
	if [ -n "$DSH_SERVICE_NODE_BIN_DIR" ] && [ -d "$DSH_SERVICE_NODE_BIN_DIR" ]; then
		case ":$PATH:" in
			*":$DSH_SERVICE_NODE_BIN_DIR:"*) ;;
			*) export PATH="$DSH_SERVICE_NODE_BIN_DIR:$PATH" ;;
		esac
	fi
}

# apply_mirrors：把配置里的镜像设置注入 npm 与 nvm。npm registry 通过
# npm_config_registry 传给所有 npm 子命令，nvm 的 Node 二进制下载源通过
# NVM_NODEJS_ORG_MIRROR 传给 nvm.sh。已经由用户环境显式设置的底层变量优先，
# 不会被默认值覆盖。系统包管理器（apt/dnf/yum）的软件源不在此列。
apply_mirrors() {
	if [ -n "${DSH_SERVICE_NPM_REGISTRY:-}" ] && [ -z "${npm_config_registry:-}" ]; then
		export npm_config_registry="$DSH_SERVICE_NPM_REGISTRY"
	fi
	if [ -n "${DSH_SERVICE_NODE_MIRROR:-}" ] && [ -z "${NVM_NODEJS_ORG_MIRROR:-}" ]; then
		export NVM_NODEJS_ORG_MIRROR="$DSH_SERVICE_NODE_MIRROR"
	fi
}

# nvm.sh 与 `set -u` 不兼容：它的下载失败路径会直接引用未定义的变量（如 TMPDIR），
# 在 dshctl 的 `set -Eeuo pipefail` 下会立刻以 “unbound variable” 退出，把真正的
# 错误掩盖掉。所有 nvm 调用都在临时关闭 -u/-e 后执行，返回后恢复原选项。
with_loose_shell() {
	local had_u=0 had_e=0 rc=0
	case $- in *u*) had_u=1 ;; esac
	case $- in *e*) had_e=1 ;; esac
	set +u +e
	"$@" || rc=$?
	if [ "$had_u" = 1 ]; then set -u; fi
	if [ "$had_e" = 1 ]; then set -e; fi
	return "$rc"
}

# try_load_nvm：nvm 缺失时安静地返回 1，供 doctor --fix / refresh_dsh_symlink 等
# 可恢复路径使用（这些路径不能 exit，否则会中断整个自检）。
try_load_nvm() {
	[ -s "$DSH_SERVICE_NVM_DIR/nvm.sh" ] || return 1
	# nvm 把 PREFIX 当作 node 安装前缀校验；若环境里存在 PREFIX（其他工具常会设置），
	# `nvm install` 会直接失败。本工具不使用该环境变量，先移除。
	unset PREFIX
	export NVM_DIR="$DSH_SERVICE_NVM_DIR"
	# shellcheck source=/dev/null
	with_loose_shell . "$NVM_DIR/nvm.sh" --no-use
}

# load_nvm：nvm 是硬依赖的入口（upgrade / upgrade-node / uninstall --remove-node）。
load_nvm() {
	try_load_nvm || die "找不到 nvm（$DSH_SERVICE_NVM_DIR/nvm.sh）。请先运行 install.sh。"
}

# nvm_install_major：`nvm install -b` + 重试。-b 禁止二进制下载失败后静默转为源码
# 编译；网络抖动时按 DSH_SERVICE_NODE_ATTEMPTS / _RETRY_DELAY 重试（默认 3 次 / 5s）。
nvm_install_major() {
	local major="$1" attempts="${DSH_SERVICE_NODE_ATTEMPTS:-3}" delay="${DSH_SERVICE_NODE_RETRY_DELAY:-5}" attempt=1
	case "$attempts" in ''|*[!0-9]*) attempts=3 ;; esac
	case "$delay" in ''|*[!0-9]*) delay=5 ;; esac
	if [ "$attempts" -lt 1 ]; then attempts=1; fi
	while :; do
		if with_loose_shell nvm install -b "$major"; then
			return 0
		fi
		if [ "$attempt" -ge "$attempts" ]; then
			return 1
		fi
		warn "nvm install $major 失败（第 $attempt/$attempts 次尝试），${delay}s 后重试 ..."
		sleep "$delay"
		attempt=$((attempt + 1))
	done
}

user_systemd_env() {
	if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
		if [ -d "/run/user/$(id -u)" ]; then
			export XDG_RUNTIME_DIR="/run/user/$(id -u)"
		fi
	fi
	if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
		export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
	fi
}

systemctl_user() {
	user_systemd_env
	systemctl --user "$@"
}

have_user_systemd() {
	systemctl_user show-environment >/dev/null 2>&1
}

systemd_hint() {
	cat >&2 <<'EOF'
可能的原因与处理：
  1) WSL / 容器中未启用 systemd：WSL 请在 /etc/wsl.conf 加入
         [boot]
         systemd=true
     然后执行 `wsl --shutdown` 并重新打开终端。
  2) 非登录会话（SSH / CI）：执行 `sudo loginctl enable-linger $USER`，
     或改在本机登录终端中运行 dshctl。
  3) 缺少运行时目录：确认 /run/user/$(id -u) 存在。
EOF
	printf '  当前单元文件：%s\n' "$DSH_SERVICE_UNIT" >&2
}

require_user_systemd() {
	if ! have_user_systemd; then
		err "无法连接用户级 systemd（systemctl --user）。"
		systemd_hint
		exit 1
	fi
}

dsh_bin() {
	if [ -x "$DSH_SERVICE_DSH_BIN" ]; then
		printf '%s\n' "$DSH_SERVICE_DSH_BIN"
		return 0
	fi
	if command -v dsh >/dev/null 2>&1; then
		command -v dsh
		return 0
	fi
	return 1
}

# dsh --version 目前输出裸 semver（如 0.1.5-rc.1）；上游若改成带前缀/后缀的
# 形式，这里仍能提取出版本号，避免升级比较与版本校验误判。
normalize_version() {
	local raw="$1" v
	v="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)?' | head -n 1 || true)"
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
	else
		printf '%s\n' "$raw"
	fi
}

# 目标版本可能写成 v0.1.6-alpha.2（npm/GitHub 习惯，npm 也接受这个前缀），
# 而 `dsh --version` 输出的是裸 semver；直接比较会把「升级成功」误判成
# 「安装后版本校验失败」并触发回滚。比较前统一剥掉前导 v。
strip_v_prefix() {
	local v="${1:-}"
	printf '%s\n' "${v#v}"
}

installed_dsh_version() {
	local bin
	bin="$(dsh_bin)" || return 1
	normalize_version "$("$bin" --version 2>/dev/null || true)"
}

run_dsh() {
	local bin
	bin="$(dsh_bin)" || die "未找到 dsh 可执行文件，请先运行 install.sh。"
	DSH_HOME="$DSH_SERVICE_DSH_HOME" "$bin" "$@"
}

dsh_root() {
	local bin real probe
	bin="$(dsh_bin)" || return 1
	real="$(readlink -f -- "$bin" 2>/dev/null || printf '%s' "$bin")"
	case "$real" in
		*/lib/bin.js)
			printf '%s\n' "${real%/lib/bin.js}"
			return 0
			;;
	esac
	probe="$real"
	while [ "$probe" != "/" ] && [ -n "$probe" ]; do
		if [ -f "$probe/package.json" ]; then
			printf '%s\n' "$probe"
			return 0
		fi
		probe="$(dirname -- "$probe")"
	done
	return 1
}

frontend_dist() {
	local root candidate
	root="$(dsh_root)" || return 1
	for candidate in \
		"$root/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html" \
		"$(dirname -- "$root")/@deepseek-ai/dsh-web-frontend/dist/index.html"; do
		if [ -f "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	find "$(dirname -- "$root")" -maxdepth 4 -path '*dsh-web-frontend/dist/index.html' -print -quit 2>/dev/null
}

node_major() {
	node --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\).*/\1/p'
}

port_listener() {
	if command -v ss >/dev/null 2>&1; then
		# 按冒号切分后比较端口号，避免 ":3080" 同时命中 ":30800"。
		ss -ltn 2>/dev/null | awk -v port="$DSH_SERVICE_PORT" '
			NR > 1 {
				n = split($4, a, ":")
				if (a[n] == port) { print $4; found = 1 }
			}
			END { exit found ? 0 : 1 }'
	elif command -v lsof >/dev/null 2>&1; then
		lsof -nP -iTCP:"$DSH_SERVICE_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }'
	fi
}

# 为配置文件的 `: "${VAR:=<value>}"`（双引号上下文）转义：反斜杠、双引号、$ 与反引号。
# 配置会被 source，若 $()/`` 未被转义，就会在每次 dshctl 运行时被求值执行。
shell_q() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g'
}

# ── 配置与单元渲染 ───────────────────────────────────────────────────────────
render_config() {
	mkdir -p -- "$CONFIG_DIR"
	local tmp v
	for v in "$DSH_SERVICE_NAME" "$DSH_SERVICE_PROFILE" "$DSH_SERVICE_HOST" \
		"$DSH_SERVICE_PORT" "$DSH_SERVICE_DSH_HOME" "$DSH_SERVICE_NVM_DIR" \
		"$DSH_SERVICE_NODE_BIN_DIR" "$DSH_SERVICE_LOCAL_BIN" "$DSH_SERVICE_EXTRA_ARGS" \
		"$DSH_SERVICE_NPM_REGISTRY" "$DSH_SERVICE_NODE_MIRROR"; do
		case "$v" in
			*$'\n'*|*$'\r'*) die "配置值不能包含换行: $v" ;;
		esac
	done
	tmp="$(mktemp "$CONFIG_DIR/.config.XXXXXX")"
	TMP_FILES+=("$tmp")
	{
		printf '%s\n' '# dsh-service 配置 —— 由 dshctl 生成；install.sh 重跑会保留这里未显式指定的取值。'
		printf '%s\n' '# 语法为“默认值”：环境变量优先，例如 DSH_SERVICE_PORT=4000 dshctl restart'
		printf '%s\n' '# 修改后执行 dshctl restart 生效。'
		printf '\n: "${DSH_SERVICE_NAME:=%s}"\n' "$(shell_q "$DSH_SERVICE_NAME")"
		printf ': "${DSH_SERVICE_PROFILE:=%s}"\n' "$(shell_q "$DSH_SERVICE_PROFILE")"
		printf ': "${DSH_SERVICE_HOST:=%s}"\n' "$(shell_q "$DSH_SERVICE_HOST")"
		printf ': "${DSH_SERVICE_PORT:=%s}"\n' "$(shell_q "$DSH_SERVICE_PORT")"
		printf ': "${DSH_SERVICE_DSH_HOME:=%s}"\n' "$(shell_q "$DSH_SERVICE_DSH_HOME")"
		printf ': "${DSH_SERVICE_NVM_DIR:=%s}"\n' "$(shell_q "$DSH_SERVICE_NVM_DIR")"
		printf ': "${DSH_SERVICE_NODE_BIN_DIR:=%s}"\n' "$(shell_q "$DSH_SERVICE_NODE_BIN_DIR")"
		printf ': "${DSH_SERVICE_LOCAL_BIN:=%s}"\n' "$(shell_q "$DSH_SERVICE_LOCAL_BIN")"
		printf ': "${DSH_SERVICE_EXTRA_ARGS:=%s}"\n' "$(shell_q "$DSH_SERVICE_EXTRA_ARGS")"
		printf ': "${DSH_SERVICE_MIRROR:=%s}"\n' "$(shell_q "$DSH_SERVICE_MIRROR")"
		printf ': "${DSH_SERVICE_NPM_REGISTRY:=%s}"\n' "$(shell_q "$DSH_SERVICE_NPM_REGISTRY")"
		printf ': "${DSH_SERVICE_NODE_MIRROR:=%s}"\n' "$(shell_q "$DSH_SERVICE_NODE_MIRROR")"
	} > "$tmp"
	chmod 0644 "$tmp"
	if [ -f "$CONFIG_FILE" ] && cmp -s "$tmp" "$CONFIG_FILE"; then
		rm -f -- "$tmp"
		log "配置未变化: $CONFIG_FILE"
		return 0
	fi
	mv -f -- "$tmp" "$CONFIG_FILE"
	log "已写入配置: $CONFIG_FILE"
}

UNIT_CHANGED=no

# systemd 的 Environment= 使用双引号语法，内部的反斜杠/双引号需要转义。
unit_dq() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 写入单元的值若含换行，会变成一条新指令（例如注入 ExecStartPre），必须拒绝。
# 返回 1 而不是 exit：doctor --fix 等路径需要能继续（由调用方 `|| return 1`）。
unit_no_newline() {
	case "$1" in
		*$'\n'*|*$'\r'*) err "值不能包含换行（会破坏 systemd 单元）: $1"; return 1 ;;
	esac
	return 0
}

# systemd 会对 ExecStart 做 % 说明符展开（%i/%n/...），字面量 % 必须写成 %%。
# 路径或参数里的单个 %（如 /opt/100%）会让单元解析失败或语义被改写。
unit_percent() {
	printf '%s' "$1" | sed -e 's/%/%%/g'
}

render_unit() {
	UNIT_CHANGED=no
	local dir tmp node_bin path_value exec_args target
	dir="$(dirname -- "$DSH_SERVICE_UNIT")"
	mkdir -p -- "$dir"

	node_bin="$DSH_SERVICE_NODE_BIN_DIR"
	if [ -z "$node_bin" ] && command -v node >/dev/null 2>&1; then
		node_bin="$(dirname -- "$(command -v node)")"
	fi
	path_value="$DSH_SERVICE_LOCAL_BIN"
	if [ -n "$node_bin" ]; then
		path_value="$path_value:$node_bin"
	fi
	path_value="$path_value:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

	if [ "$DSH_SERVICE_PROFILE" = web ]; then
		target="web"
	else
		target="--profile $DSH_SERVICE_PROFILE"
	fi
	exec_args="$target --host $DSH_SERVICE_HOST --port $DSH_SERVICE_PORT --no-open"
	if [ -n "$DSH_SERVICE_EXTRA_ARGS" ]; then
		exec_args="$exec_args $DSH_SERVICE_EXTRA_ARGS"
	fi

	unit_no_newline "$DSH_SERVICE_NAME" || return 1
	unit_no_newline "$DSH_SERVICE_DSH_BIN" || return 1
	unit_no_newline "$DSH_SERVICE_DSH_HOME" || return 1
	unit_no_newline "$path_value" || return 1
	unit_no_newline "$exec_args" || return 1
	case "$DSH_SERVICE_DSH_BIN" in
		*' '*) warn "dsh 可执行路径包含空格，systemd 的 ExecStart 可能无法正确解析: $DSH_SERVICE_DSH_BIN" ;;
	esac

	tmp="$(mktemp "$dir/.dsh-unit.XXXXXX")"
	TMP_FILES+=("$tmp")

	{
		printf '%s\n' '[Unit]'
		printf 'Description=DeepSeek Harness Web GUI (%s)\n' "$DSH_SERVICE_UNIT_NAME"
		printf '%s\n' 'Documentation=https://github.com/deepseek-ai/deepseek-harness'
		printf '%s\n' 'Wants=network-online.target'
		printf '%s\n' 'After=network-online.target'
		printf '%s\n' 'StartLimitIntervalSec=300'
		printf '%s\n' 'StartLimitBurst=5'
		printf '\n%s\n' '[Service]'
		printf '%s\n' 'Type=exec'
		printf 'Environment="PATH=%s"\n' "$(unit_dq "$path_value")"
		printf 'Environment="DSH_HOME=%s"\n' "$(unit_dq "$DSH_SERVICE_DSH_HOME")"
		printf 'ExecStart=%s %s\n' "$(unit_percent "$DSH_SERVICE_DSH_BIN")" "$(unit_percent "$exec_args")"
		printf '%s\n' 'Restart=on-failure'
		printf '%s\n' 'RestartSec=3'
		printf '%s\n' 'TimeoutStopSec=45'
		printf '%s\n' 'StandardOutput=journal'
		printf '%s\n' 'StandardError=journal'
		printf 'SyslogIdentifier=%s\n' "$DSH_SERVICE_NAME"
		printf '\n%s\n' '[Install]'
		printf '%s\n' 'WantedBy=default.target'
	} > "$tmp"
	chmod 0644 "$tmp"

	if [ -f "$DSH_SERVICE_UNIT" ] && cmp -s "$tmp" "$DSH_SERVICE_UNIT"; then
		rm -f -- "$tmp"
		log "单元未变化: $DSH_SERVICE_UNIT"
		return 0
	fi
	if [ -f "$DSH_SERVICE_UNIT" ] && [ ! -f "$DSH_SERVICE_UNIT.bak" ]; then
		cp -p -- "$DSH_SERVICE_UNIT" "$DSH_SERVICE_UNIT.bak"
		log "已备份原单元到 $DSH_SERVICE_UNIT.bak"
	fi
	mv -f -- "$tmp" "$DSH_SERVICE_UNIT"
	UNIT_CHANGED=yes
	log "已写入单元: $DSH_SERVICE_UNIT"
}

refresh_dsh_symlink() {
	ensure_node_env
	try_load_nvm || true
	local prefix gbin
	if ! command -v npm >/dev/null 2>&1; then
		err "找不到 npm（nvm 与 node 均不可用），请先运行 install.sh"
		return 1
	fi
	prefix="$(npm prefix -g 2>/dev/null | tail -n 1 || true)"
	if [ -z "$prefix" ]; then
		err "无法获取 npm 全局前缀（npm prefix -g 失败）"
		return 1
	fi
	gbin="$prefix/bin/dsh"
	if [ ! -x "$gbin" ]; then
		err "未找到全局 dsh: $gbin（请先 npm install -g @deepseek-ai/dsh）"
		return 1
	fi
	mkdir -p -- "$DSH_SERVICE_LOCAL_BIN"
	ln -sfn -- "$gbin" "$DSH_SERVICE_DSH_BIN"
	log "$DSH_SERVICE_DSH_BIN -> $gbin"
}

reload_and_restart() {
	local no_restart="${1:-0}"
	if [ "$no_restart" = 1 ]; then
		log "按 --no-restart 跳过服务重启（新版本将在下次启动时生效）"
		return 0
	fi
	if ! have_user_systemd; then
		warn "无法连接用户级 systemd，跳过重启；请稍后手动执行: systemctl --user restart $DSH_SERVICE_UNIT_NAME"
		return 1
	fi
	render_unit || return 1
	if [ "$UNIT_CHANGED" = yes ]; then
		systemctl_user daemon-reload || true
	fi
	if ! systemctl_user restart "$DSH_SERVICE_UNIT_NAME"; then
		err "服务重启失败；请查看 dshctl logs"
		return 1
	fi
	if ! wait_active 3; then
		err "服务重启后未正常运行（状态: $(systemctl_user is-active "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true)），请查看: dshctl logs -n 30"
		return 1
	fi
	log "服务已重启: $DSH_SERVICE_UNIT_NAME"
	return 0
}

# 等待服务进入 active；宽限 $1 秒后仍非 active 视为启动失败（可捕捉启动即崩溃）。
wait_active() {
	local grace="${1:-2}" state i=0
	sleep "$grace"
	while [ "$i" -lt 10 ]; do
		state="$(systemctl_user is-active "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true)"
		case "$state" in
			active) return 0 ;;
			activating|reloading) ;;
			*) return 1 ;;
		esac
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# ── 内部命令（供 install.sh 调用） ───────────────────────────────────────────
internal_enable() {
	render_unit || return 1
	if ! have_user_systemd; then
		err "无法连接用户级 systemd（systemctl --user），服务未启用。"
		systemd_hint
		return 1
	fi
	systemctl_user daemon-reload || true
	if ! systemctl_user enable --now "$DSH_SERVICE_UNIT_NAME"; then
		err "启用服务失败: $DSH_SERVICE_UNIT_NAME"
		return 1
	fi
	if ! wait_active 2; then
		err "服务已启用但未正常运行（状态: $(systemctl_user is-active "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true)）"
		printf '  请查看日志: dshctl logs -n 30\n' >&2
		return 1
	fi
	log "服务已启用并启动: $DSH_SERVICE_UNIT_NAME"
	return 0
}

internal_linger() {
	if ! have_user_systemd; then
		warn "无法连接用户级 systemd，跳过 linger 设置（开机未登录时不会自启）。"
		return 0
	fi
	local state has_sudo=0
	state="$(loginctl show-user "$USER" -p Linger 2>/dev/null | sed -n 's/^Linger=//p' || true)"
	if [ "$state" = yes ]; then
		log "linger 已启用（可开机自启）"
		return 0
	fi
	if command -v sudo >/dev/null 2>&1; then
		has_sudo=1
	fi
	# 1) 免密 sudo 优先：非交互安装（如 curl | bash）不会触发 polkit 认证代理，
	#    可避免最小化系统缺少 /usr/bin/pkttyagent 时打印
	#    “Failed to execute /usr/bin/pkttyagent: No such file or directory”。
	if [ "$has_sudo" = 1 ] && sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
		log "已启用 linger（sudo）"
		return 0
	fi
	# 2) 无特权尝试：桌面会话下由 polkit 弹窗/规则授权。
	if loginctl enable-linger "$USER" 2>/dev/null; then
		log "已启用 linger（可开机自启）"
		return 0
	fi
	# 3) 交互终端：允许 sudo 提示输入密码（脚本其余步骤同样会用到 sudo）。
	if [ "$has_sudo" = 1 ] && [ -t 0 ] && sudo loginctl enable-linger "$USER"; then
		log "已启用 linger（sudo）"
		return 0
	fi
	warn "未能启用 linger：开机且未登录时服务不会自动启动。"
	warn "请手动执行: sudo loginctl enable-linger $USER"
	return 0
}

# ── 服务控制 ─────────────────────────────────────────────────────────────────
cmd_start() {
	require_user_systemd
	if ! systemctl_user start "$DSH_SERVICE_UNIT_NAME"; then
		err "启动失败，请查看 dshctl logs"
		return 1
	fi
	log "已启动: $DSH_SERVICE_UNIT_NAME"
}

cmd_stop() {
	require_user_systemd
	if ! systemctl_user stop "$DSH_SERVICE_UNIT_NAME"; then
		err "停止失败"
		return 1
	fi
	log "已停止: $DSH_SERVICE_UNIT_NAME"
}

cmd_restart() {
	require_user_systemd
	if ! reload_and_restart 0; then
		err "重启失败，请查看 dshctl logs"
		return 1
	fi
}

cmd_enable() {
	internal_enable
}

cmd_disable() {
	require_user_systemd
	if ! systemctl_user disable --now "$DSH_SERVICE_UNIT_NAME"; then
		err "取消失败"
		return 1
	fi
	log "已取消开机自启并停止: $DSH_SERVICE_UNIT_NAME"
}

cmd_status() {
	ensure_node_env
	require_user_systemd
	local rc=0 listener
	systemctl_user status "$DSH_SERVICE_UNIT_NAME" --no-pager || rc=$?
	printf '\n'
	printf 'dsh       : %s\n' "$(installed_dsh_version || printf '未检测到')"
	printf 'node      : %s (%s)\n' "$(node --version 2>/dev/null || printf '未检测到')" "${DSH_SERVICE_NODE_BIN_DIR:-未知}"
	printf '地址      : http://%s:%s\n' "$DSH_SERVICE_HOST" "$DSH_SERVICE_PORT"
	printf 'DSH_HOME  : %s\n' "$DSH_SERVICE_DSH_HOME"
	printf '配置文件  : %s\n' "$CONFIG_FILE"
	printf '单元文件  : %s\n' "$DSH_SERVICE_UNIT"
	listener="$(port_listener || true)"
	if [ -n "$listener" ]; then
		printf '端口监听  : %s\n' "$listener"
	else
		printf '端口监听  : 无\n'
	fi
	return "$rc"
}

# ── 查看 ─────────────────────────────────────────────────────────────────────
# AlmaLinux / RHEL 系默认持久化 journal（/var/log/journal），普通用户不在
# systemd-journal 组时 `journalctl --user` 会以 “No journal files were opened due
# to insufficient permissions” 失败。这里探测一次，失败时回退到
# `sudo -n journalctl -t <name>`（单元设置了 SyslogIdentifier=<name>）。
JOURNAL_USER_OK=''
journal_user_works() {
	if [ -z "$JOURNAL_USER_OK" ]; then
		if journalctl --user -u "$DSH_SERVICE_UNIT_NAME" -n 0 --no-pager >/dev/null 2>&1; then
			JOURNAL_USER_OK=yes
		else
			JOURNAL_USER_OK=no
		fi
	fi
	[ "$JOURNAL_USER_OK" = yes ]
}

# 回退读取：免密 sudo + -t <ident>；无 sudo 或需要密码时安静失败。
sudo_journal() {
	command -v sudo >/dev/null 2>&1 || return 1
	sudo -n journalctl -t "$DSH_SERVICE_NAME" --no-pager "$@"
}

journal_hint() {
	warn "无法以当前用户读取 journal（AlmaLinux/RHEL 常见：需要 systemd-journal 组）。"
	printf '  永久修复（需重新登录）: sudo usermod -aG systemd-journal %s\n' "$USER" >&2
	printf '  临时查看              : sudo journalctl -t %s -n 50 --no-pager\n' "$DSH_SERVICE_NAME" >&2
}

cmd_logs() {
	require_user_systemd
	if journal_user_works; then
		journalctl --user -u "$DSH_SERVICE_UNIT_NAME" --no-pager "$@"
		return $?
	fi
	if sudo_journal "$@" 2>/dev/null; then
		return 0
	fi
	journal_hint
	warn "免密 sudo 不可用，无法自动读取日志。"
	return 1
}

latest_url_line() {
	local line
	if journal_user_works; then
		line="$({
			journalctl --user -u "$DSH_SERVICE_UNIT_NAME" --no-pager -o cat -n 2000 2>/dev/null \
				|| true
		} | grep -F 'dsh web: ' | tail -n 1)"
	else
		line="$({
			sudo_journal -o cat -n 2000 2>/dev/null || true
		} | grep -F 'dsh web: ' | tail -n 1)"
	fi
	if [ -z "$line" ]; then
		return 0
	fi
	printf '%s\n' "$line" | grep -o 'http://[^ ]*token=[^ ]*' | head -n 1 || true
}

cmd_url() {
	local plain=0 wait_secs=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--plain) plain=1; shift ;;
			--wait) wait_secs="${2:?--wait 需要一个秒数}"; shift 2 ;;
			--wait=*) wait_secs="${1#*=}"; shift ;;
			*) die "url: 未知参数 $1" ;;
		esac
	done
	case "$wait_secs" in
		''|*[!0-9]*) die "url: --wait 需要非负整数，收到 '$wait_secs'" ;;
	esac

	local url='' i=0
	while :; do
		url="$(latest_url_line)"
		if [ -n "$url" ]; then
			break
		fi
		i=$((i + 1))
		if [ "$wait_secs" -gt 0 ] && [ "$i" -le "$wait_secs" ]; then
			sleep 1
			continue
		fi
		break
	done

	if [ -z "$url" ]; then
		err "无法从日志中找到登录链接。"
		if ! journal_user_works; then
			journal_hint
		fi
		cat >&2 <<EOF
提示：
  1) dshctl logs -n 50       查看启动日志
  2) dshctl url --wait 30    等待服务启动完成后再取
  3) dshctl restart          重启并重新打印链接
EOF
		return 1
	fi
	if [ "$plain" = 1 ]; then
		printf '%s\n' "${url%%\?token=*}"
	else
		printf '%s\n' "$url"
	fi
}

cmd_version() {
	ensure_node_env
	printf 'dshctl : %s\n' "$DSHCTL_VERSION"
	printf 'dsh    : %s\n' "$(installed_dsh_version || printf '未检测到')"
	printf 'node   : %s\n' "$(node --version 2>/dev/null || printf '未检测到')"
	printf 'npm    : %s\n' "$(npm --version 2>/dev/null || printf '未检测到')"
	printf '单元   : %s\n' "$DSH_SERVICE_UNIT"
	printf '配置   : %s\n' "$CONFIG_FILE"
}

cmd_config() {
	if [ "${1:-}" = edit ]; then
		if [ ! -f "$CONFIG_FILE" ]; then
			die "配置文件不存在: $CONFIG_FILE（先运行 install.sh）"
		fi
		local -a editor_cmd=()
		read -r -a editor_cmd <<<"${EDITOR:-vi}" || true
		if [ "${#editor_cmd[@]}" -eq 0 ]; then
			editor_cmd=(vi)
		fi
		"${editor_cmd[@]}" "$CONFIG_FILE"
		log "修改后执行 dshctl restart 生效"
		return 0
	fi
	printf '配置文件: %s%s\n' "$CONFIG_FILE" "$([ -f "$CONFIG_FILE" ] || printf '（尚未生成）')"
	printf '  DSH_SERVICE_NAME          = %s\n' "$DSH_SERVICE_NAME"
	printf '  DSH_SERVICE_PROFILE       = %s\n' "$DSH_SERVICE_PROFILE"
	printf '  DSH_SERVICE_HOST          = %s\n' "$DSH_SERVICE_HOST"
	printf '  DSH_SERVICE_PORT          = %s\n' "$DSH_SERVICE_PORT"
	printf '  DSH_SERVICE_DSH_HOME      = %s\n' "$DSH_SERVICE_DSH_HOME"
	printf '  DSH_SERVICE_NVM_DIR       = %s\n' "$DSH_SERVICE_NVM_DIR"
	printf '  DSH_SERVICE_NODE_BIN_DIR  = %s\n' "$DSH_SERVICE_NODE_BIN_DIR"
	printf '  DSH_SERVICE_LOCAL_BIN     = %s\n' "$DSH_SERVICE_LOCAL_BIN"
	printf '  DSH_SERVICE_EXTRA_ARGS    = %s\n' "$DSH_SERVICE_EXTRA_ARGS"
	printf '  DSH_SERVICE_MIRROR        = %s\n' "$DSH_SERVICE_MIRROR"
	printf '  DSH_SERVICE_NPM_REGISTRY  = %s\n' "$DSH_SERVICE_NPM_REGISTRY"
	printf '  DSH_SERVICE_NODE_MIRROR   = %s\n' "${DSH_SERVICE_NODE_MIRROR:-（官方源）}"
	printf '派生: 单元=%s\n' "$DSH_SERVICE_UNIT"
	printf '派生: dsh=%s\n' "$DSH_SERVICE_DSH_BIN"
	printf '提示: 环境变量优先于配置文件，例如 DSH_SERVICE_PORT=4000 dshctl restart\n'
}

# ── 自检 ─────────────────────────────────────────────────────────────────────
cmd_doctor() {
	local fix=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--fix) fix=1; shift ;;
			*) die "doctor: 未知参数 $1" ;;
		esac
	done

	local ok=0 bad=0 major
	pass() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; ok=$((ok + 1)); }
	fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; bad=$((bad + 1)); }
	note() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }

	printf 'dshctl doctor —— 环境自检\n'

	if [ -s "$DSH_SERVICE_NVM_DIR/nvm.sh" ]; then
		pass "nvm: $DSH_SERVICE_NVM_DIR/nvm.sh"
	else
		fail "nvm 缺失: $DSH_SERVICE_NVM_DIR/nvm.sh（请运行 install.sh）"
	fi

	ensure_node_env
	if command -v node >/dev/null 2>&1; then
		major="$(node_major)"
		if [ -n "$major" ] && [ "$major" -ge 22 ]; then
			pass "node: $(node --version)（$DSH_SERVICE_NODE_BIN_DIR）"
		else
			fail "node 版本过低: $(node --version)（需要 v22 及以上）"
		fi
	else
		fail "未找到 node（请运行 install.sh）"
	fi

	if command -v dsh >/dev/null 2>&1 || [ -x "$DSH_SERVICE_DSH_BIN" ]; then
		pass "dsh: $(installed_dsh_version || printf '版本未知')（$(dsh_bin)）"
	else
		fail "未找到 dsh（请 npm install -g @deepseek-ai/dsh）"
	fi

	local dist
	dist="$(frontend_dist || true)"
	if [ -n "$dist" ]; then
		pass "前端资源: $dist"
	else
		fail "未找到 @deepseek-ai/dsh-web-frontend 的 dist/index.html（Web 界面无法渲染）"
	fi

	if command -v dsh >/dev/null 2>&1 || [ -x "$DSH_SERVICE_DSH_BIN" ]; then
		if run_dsh web --dump-config >/dev/null 2>&1; then
			pass "配置组合检查: dsh web --dump-config"
		else
			fail "dsh web --dump-config 失败（profile 或依赖有问题，试 dshctl logs）"
		fi
	fi

	if have_user_systemd; then
		pass "用户级 systemd 可用"
	else
		fail "无法连接用户级 systemd"
		systemd_hint
	fi

	if [ -f "$DSH_SERVICE_UNIT" ]; then
		pass "单元文件: $DSH_SERVICE_UNIT"
		if systemctl_user is-enabled "$DSH_SERVICE_UNIT_NAME" >/dev/null 2>&1; then
			pass "已设置开机自启"
		else
			fail "未设置开机自启（dshctl enable）"
		fi
		if [ "$(systemctl_user is-active "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true)" = active ]; then
			pass "服务运行中"
		else
			fail "服务未运行（dshctl start，或 dshctl logs 排查）"
		fi
	else
		fail "单元文件不存在: $DSH_SERVICE_UNIT（请运行 install.sh）"
	fi

	local linger
	linger="$(loginctl show-user "$USER" -p Linger 2>/dev/null | sed -n 's/^Linger=//p' || true)"
	if [ "$linger" = yes ]; then
		pass "linger 已启用（开机自启）"
	else
		fail "未启用 linger（sudo loginctl enable-linger $USER）"
	fi

	local listener
	listener="$(port_listener || true)"
	if [ -n "$listener" ]; then
		pass "端口 $DSH_SERVICE_PORT 正在监听: $listener"
	else
		fail "端口 $DSH_SERVICE_PORT 未监听"
	fi

	if journal_user_works; then
		pass "用户 journal 可读（dshctl logs / dshctl url 可用）"
	elif command -v sudo >/dev/null 2>&1 && sudo_journal -n 0 >/dev/null 2>&1; then
		note "用户 journal 不可读，但可用免密 sudo 回退读取（dshctl logs / url 会自动回退）"
	else
		fail "无法读取服务日志（修复: sudo usermod -aG systemd-journal $USER 后重新登录）"
	fi

	case ":$PATH:" in
		*":$DSH_SERVICE_LOCAL_BIN:"*) pass "$DSH_SERVICE_LOCAL_BIN 已在 PATH 中" ;;
		*) fail "$DSH_SERVICE_LOCAL_BIN 不在 PATH 中（重新登录或 bash install.sh）" ;;
	esac

	if [ -L "$DSH_SERVICE_DSH_BIN" ] && [ -x "$DSH_SERVICE_DSH_BIN" ]; then
		pass "稳定入口: $DSH_SERVICE_DSH_BIN -> $(readlink -f -- "$DSH_SERVICE_DSH_BIN")"
	else
		fail "稳定入口缺失或失效: $DSH_SERVICE_DSH_BIN"
	fi

	case "$DSH_SERVICE_DSH_HOME/" in
		/mnt/*) note "DSH_HOME 位于 /mnt（WSL drvfs 的符号链接不可靠，建议放在 Linux 原生路径）: $DSH_SERVICE_DSH_HOME" ;;
		*) pass "DSH_HOME: $DSH_SERVICE_DSH_HOME" ;;
	esac

	if [ "$fix" = 1 ]; then
		printf '\n开始修复：\n'
		refresh_dsh_symlink || true
		render_unit || true
		if have_user_systemd && [ "$UNIT_CHANGED" = yes ]; then
			systemctl_user daemon-reload || true
		fi
	fi

	printf '\n通过 %d 项，失败 %d 项。\n' "$ok" "$bad"
	if [ "$bad" -gt 0 ]; then
		return 1
	fi
	return 0
}

# ── 升级 ─────────────────────────────────────────────────────────────────────
# 把 dist-tag（next/latest/alpha 等）解析为 registry 上指向的具体版本；
# 具体版本号（v0.1.6 / 0.1.6）原样返回、不访问网络；查询失败或没有该 tag 时输出空。
# 与安装器主体的同名函数保持一致。
resolve_dist_tag() {
	local spec="${1:-}" tags value
	case "$spec" in
		v[0-9]*|[0-9]*) strip_v_prefix "$spec"; return 0 ;;
	esac
	tags="$(npm view @deepseek-ai/dsh dist-tags --json 2>/dev/null || true)"
	if [ -z "$tags" ]; then
		# registry 查询失败：无法判断该 tag 是否存在，用退出码 2 让调用方区分。
		return 2
	fi
	# `|| true`：awk 命中后提前退出可能让上游 tr 收到 SIGPIPE，pipefail 下不应因此失败。
	value="$(printf '%s' "$tags" | tr -d '{}"' | tr ',' '\n' | tr ':' ' ' \
		| awk -v k="$spec" '$1 == k { print $2; exit }' || true)"
	printf '%s\n' "$value"
}

resolve_target() {
	local spec="${1:-}" resolved
	if [ -z "$spec" ]; then
		spec="$DSH_DEFAULT_CHANNEL"
	fi
	# 具体版本号不查网络；dist-tag 需要查询 registry 解析成具体版本。
	case "$spec" in
		v[0-9]*|[0-9]*) strip_v_prefix "$spec"; return 0 ;;
	esac
	# registry 查询失败（退出码 2）时输出空并返回 1，由调用方报错退出；查询成功但没有
	# 该 tag 时按字面 spec 交给装前校验/安装，由其给出「版本不存在」提示。
	resolved="$(resolve_dist_tag "$spec")" || return 1
	if [ -z "$resolved" ]; then
		resolved="$spec"
	fi
	# 用户与 npm view 都可能给带 v 前缀的版本号；统一成裸 semver 再比较，
	# 否则 `upgrade v0.1.6-alpha.2` 会在装好后误判校验失败并回滚。
	strip_v_prefix "$resolved"
}

rollback_upgrade() {
	local version="$1" no_restart="$2"
	apply_mirrors
	if [ -z "$version" ]; then
		warn "没有可回滚的版本，服务保持现状"
		return 1
	fi
	warn "回滚到 @deepseek-ai/dsh@$version"
	if ! npm install -g "@deepseek-ai/dsh@$version"; then
		err "回滚失败！请手动执行: npm install -g @deepseek-ai/dsh@$version"
		return 1
	fi
	refresh_dsh_symlink || true
	reload_and_restart "$no_restart" || true
	log "已回滚到 $version"
	return 0
}

# ── upgrade：版本查询与装前校验 ──────────────────────────────────────────────
# 解析默认通道（next）当前指向的版本（查询失败时输出空）。
upgrade_channel_version() {
	local v
	v="$(resolve_dist_tag "$DSH_DEFAULT_CHANNEL" || true)"
	strip_v_prefix "$(normalize_version "$v")"
}

# registry 查询失败时的排查提示。
upgrade_registry_hint() {
	warn "当前 registry: ${DSH_SERVICE_NPM_REGISTRY:-（npm 默认）}；可用 --no-mirror 或 DSH_SERVICE_NPM_REGISTRY 切换"
	warn "网络不可用时请检查代理设置，或稍后重试"
}

# 版本或 dist-tag 不存在时的提示：指明目标、默认通道当前版本与查看全部版本的命令。
upgrade_target_not_found_hint() {
	local target="$1" channel
	err "版本 $target 在 registry 上不存在（没有该版本或 dist-tag）。"
	channel="$(upgrade_channel_version)"
	if [ -n "$channel" ]; then
		printf '  默认通道 %s 当前版本: %s\n' "$DSH_DEFAULT_CHANNEL" "$channel" >&2
	fi
	printf '  查看可用版本: dshctl upgrade --list\n' >&2
	printf '  安装默认通道版本: dshctl upgrade\n' >&2
}

# upgrade_list_versions：列出 registry 上 @deepseek-ai/dsh 的可用版本（最新在前），
# 并标记 dist-tag 指向的版本。只读操作：不安装、不触碰服务，也不要求已安装 dsh。
upgrade_list_versions() {
	local limit="$1" raw tags ordered tag_pairs line names v
	if ! command -v npm >/dev/null 2>&1; then
		err "找不到 npm 命令，无法查询版本列表"
		return 1
	fi
	raw="$(npm view @deepseek-ai/dsh versions --json 2>/dev/null || true)"
	if [ -z "$raw" ]; then
		err "无法获取 @deepseek-ai/dsh 的版本列表（registry 或网络不可用）。"
		upgrade_registry_hint
		return 1
	fi
	tags="$(npm view @deepseek-ai/dsh dist-tags --json 2>/dev/null || true)"

	# 归一化 JSON/JS 数组输出：去掉括号与引号、去掉空白，再按逗号切分，只保留以数字开头的项。
	# 注意 `read || [ -n ]`：切分结果末尾没有换行符，少了这个判断会丢掉最后一项。
	local versions=()
	while IFS= read -r v || [ -n "$v" ]; do
		case "$v" in
			[0-9]*) versions+=("$v") ;;
		esac
	done < <(printf '%s' "$raw" | tr -d '[]"' | tr -d '[:space:]' | tr ',' '\n')

	if [ "${#versions[@]}" -eq 0 ]; then
		err "registry 未返回任何可用版本。"
		upgrade_registry_hint
		return 1
	fi

	# 最新在前；sort -V 不可用时退回原顺序，仍然成功输出。
	ordered="$(printf '%s\n' ${versions[@]+"${versions[@]}"} | sort -Vr 2>/dev/null || true)"
	if [ -z "$ordered" ]; then
		ordered="$(printf '%s\n' ${versions[@]+"${versions[@]}"})"
	fi
	ordered="$(printf '%s\n' "$ordered" | head -n "$limit")"

	# dist-tags 归一化为「标签 版本」每行一条。
	tag_pairs=''
	if [ -n "$tags" ]; then
		tag_pairs="$(printf '%s' "$tags" | tr -d '{}"' | tr ',' '\n' | tr ':' ' ' \
			| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
	fi

	printf '可用版本（最新在前，最多 %s 个）:\n' "$limit"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		names=''
		if [ -n "$tag_pairs" ]; then
			names="$(printf '%s\n' "$tag_pairs" | awk -v ver="$line" '$2 == ver { printf "%s%s", (n++ ? ", " : ""), $1 }')"
		fi
		if [ -n "$names" ]; then
			printf '  %s  (%s)\n' "$line" "$names"
		else
			printf '  %s\n' "$line"
		fi
	done <<EOF
$ordered
EOF
	return 0
}

# 显式请求的版本/dist-tag 在安装前先确认存在：
#   退出 0 且输出非空 -> 存在，继续；
#   输出为空且带未找到诊断（E404/ETARGET/No matching version）-> 不存在，返回 1；
#   其它失败（DNS/超时/TLS/代理）-> 无法确认，告警后继续走安装/回滚流程。
upgrade_validate_target() {
	local target="$1" res rc=0
	res="$(npm view "@deepseek-ai/dsh@$target" version 2>&1)" || rc=$?
	if [ "$rc" = 0 ] && [ -n "$(printf '%s' "$res" | tr -d '[:space:]')" ]; then
		return 0
	fi
	case "$res" in
		*ETARGET*|*E404*|*"No matching version"*)
			upgrade_target_not_found_hint "$target"
			return 1
			;;
	esac
	warn "无法确认版本 $target 是否存在（registry 查询失败），继续尝试安装"
	return 0
}

cmd_upgrade() {
	local spec="$DSH_DEFAULT_CHANNEL" spec_explicit=0 check=0 no_restart=0 list=0 list_limit=20
	while [ $# -gt 0 ]; do
		case "$1" in
			--check) check=1; shift ;;
			--no-restart) no_restart=1; shift ;;
			--yes|-y) shift ;;
			--list)
				list=1
				shift
				if [ $# -gt 0 ]; then
					case "$1" in
						''|*[!0-9]*) die "upgrade --list: 数量必须是正整数，收到 '$1'" ;;
						0) die "upgrade --list: 数量必须大于 0" ;;
						*) list_limit="$1"; shift ;;
					esac
				fi
				;;
			--list=*)
				list=1
				list_limit="${1#*=}"
				shift
				case "$list_limit" in
					''|*[!0-9]*) die "upgrade --list: 数量必须是正整数，收到 '$list_limit'" ;;
					0) die "upgrade --list: 数量必须大于 0" ;;
				esac
				;;
			latest|--latest) spec=latest; spec_explicit=1; shift ;;
			-*) die "upgrade: 未知参数 $1" ;;
			*) spec="$1"; spec_explicit=1; shift ;;
		esac
	done

	# --list 是只读查询：不要求已安装 dsh，也不安装或触碰服务。
	if [ "$list" = 1 ]; then
		apply_mirrors
		upgrade_list_versions "$list_limit"
		return $?
	fi

	ensure_node_env
	load_nvm
	apply_mirrors

	local before after target
	before="$(installed_dsh_version 2>/dev/null || true)"
	if [ -z "$before" ]; then
		die "未检测到已安装的 dsh，请先运行 install.sh"
	fi

	target="$(resolve_target "$spec" || true)"
	if [ -z "$target" ]; then
		die "无法解析目标版本（网络不可用？）。可指定具体版本：dshctl upgrade 0.1.5-rc.1"
	fi

	# 显式指定的版本/dist-tag：装前先确认它确实存在，避免只给用户看 npm 的 ETARGET。
	# 省略目标时走默认通道，目标已由 registry 解析得到，无需重复校验。
	if [ "$spec_explicit" = 1 ]; then
		upgrade_validate_target "$target" || return 1
	fi

	if [ "$target" = "$before" ]; then
		log "已是最新版本: $before"
		refresh_dsh_symlink || true
		return 0
	fi

	if [ "$check" = 1 ]; then
		log "可升级: $before -> $target"
		return 0
	fi

	log "升级 @deepseek-ai/dsh: $before -> $target"
	# 安装输出同时落一份到临时文件：若 npm 以「无匹配版本」失败，据此给出与装前校验
	# 一致的提示（覆盖校验与安装之间包被下架的竞态）。tee 保持流式输出。
	local install_log='' install_rc=0
	install_log="$(mktemp "${TMPDIR:-/tmp}/dshctl-upgrade.XXXXXX" 2>/dev/null || true)"
	if [ -n "$install_log" ]; then
		TMP_FILES+=("$install_log")
		npm install -g "@deepseek-ai/dsh@$target" 2>&1 | tee "$install_log" || install_rc=$?
	else
		npm install -g "@deepseek-ai/dsh@$target" || install_rc=$?
	fi
	if [ "$install_rc" != 0 ]; then
		err "npm 安装失败，服务未做任何改动（当前仍为 $before）"
		if [ -n "$install_log" ] && grep -qE 'ETARGET|notarget|No matching version' "$install_log" 2>/dev/null; then
			upgrade_target_not_found_hint "$target"
		fi
		return 1
	fi

	after="$(installed_dsh_version 2>/dev/null || true)"
	if [ "$after" != "$target" ]; then
		warn "安装后版本校验失败（期望 $target，实际 ${after:-空}）"
		rollback_upgrade "$before" "$no_restart" || true
		return 1
	fi

	refresh_dsh_symlink || true
	if ! reload_and_restart "$no_restart"; then
		warn "服务重启失败，尝试回滚到 $before"
		rollback_upgrade "$before" "$no_restart" || true
		return 1
	fi
	log "升级完成: $before -> $after"
	return 0
}

cmd_upgrade_node() {
	local major=''
	while [ $# -gt 0 ]; do
		case "$1" in
			-*) die "upgrade-node: 未知参数 $1" ;;
			*) major="$1"; shift ;;
		esac
	done

	ensure_node_env
	load_nvm
	apply_mirrors

	if [ -z "$major" ]; then
		major="$(node_major)"
		if [ -z "$major" ]; then
			die "无法判断当前 Node 主版本，请显式指定：dshctl upgrade-node 24"
		fi
	fi

	local dsh_ver dsh_target new_bin pnpm_ver
	dsh_ver="$(installed_dsh_version 2>/dev/null || true)"
	if [ -z "$dsh_ver" ]; then
		die "未检测到已安装的 dsh，请先运行 install.sh"
	fi
	# 重装目标跟随默认通道（与 install.sh / dshctl upgrade 一致），而不是固定在换 Node
	# 之前的旧版本。无法解析（registry 不可达）时中止，避免静默装成别的版本。
	dsh_target="$(resolve_target "$DSH_DEFAULT_CHANNEL" || true)"
	if [ -z "$dsh_target" ]; then
		die "无法解析默认通道 $DSH_DEFAULT_CHANNEL 的目标版本（registry 不可用？），请检查网络后重试"
	fi
	# pnpm 与 dsh 一样装在「当前 Node 版本」的全局 npm 前缀下：换 Node 后旧版本
	# 的 pnpm 不会自动出现，这里按升级前的版本重装（失败只告警，不阻断升级）。
	pnpm_ver="$(pnpm --version 2>/dev/null || true)"

	log "安装 Node $major ..."
	if ! nvm_install_major "$major"; then
		die "nvm install $major 失败（网络不可用？当前 Node 源为 ${NVM_NODEJS_ORG_MIRROR:-nodejs.org}，可用 DSH_SERVICE_NODE_MIRROR 换源后重试）"
	fi
	with_loose_shell nvm alias default "$major" >/dev/null 2>&1 || true
	with_loose_shell nvm use --silent "$major" >/dev/null 2>&1 || true

	new_bin="$(dirname -- "$(command -v node)")"
	log "重装 @deepseek-ai/dsh@$dsh_target（默认通道 $DSH_DEFAULT_CHANNEL，当前 $dsh_ver）到 Node $major ..."
	npm install -g "@deepseek-ai/dsh@$dsh_target" || die "重装 dsh 失败"

	if [ -n "$pnpm_ver" ]; then
		log "重装 pnpm@$pnpm_ver 到 Node $major ..."
		npm install -g "pnpm@$pnpm_ver" || warn "重装 pnpm 失败（可稍后手动执行: npm install -g pnpm@$pnpm_ver）"
	fi

	DSH_SERVICE_NODE_BIN_DIR="$new_bin"
	render_config
	refresh_dsh_symlink || true
	reload_and_restart 0
	log "Node 升级完成: $major（$new_bin）"
	return 0
}

# ── 前台运行 / 卸载 ──────────────────────────────────────────────────────────
cmd_run() {
	local bin
	bin="$(dsh_bin)" || die "未找到 dsh 可执行文件"
	local -a args=()
	if [ "$DSH_SERVICE_PROFILE" = web ]; then
		args+=(web)
	else
		args+=(--profile "$DSH_SERVICE_PROFILE")
	fi
	args+=(--host "$DSH_SERVICE_HOST" --port "$DSH_SERVICE_PORT")
	if [ $# -gt 0 ]; then
		args+=("$@")
	fi
	log "前台运行: dsh ${args[*]}"
	DSH_HOME="$DSH_SERVICE_DSH_HOME" exec "$bin" "${args[@]}"
}

# ── 插件管理 ─────────────────────────────────────────────────────────────────
# 「已安装插件」= 当前 profile 的 package.json 里的 dependencies。随附 bundle
# （dsh-base / dsh-web-app 等）只出现在 dsh.profile.bundles 里、不作为依赖，
# 因此不会被误删；profile 的用户 patch 层 cordis.patch.yml、~/.dsh/settings.yaml
# 与 dsh-service 配置也都不在清理范围内。
dsh_profile_dir() {
	printf '%s/profiles/%s\n' "$DSH_SERVICE_DSH_HOME" "$DSH_SERVICE_PROFILE"
}

# 读取 manifest 的顶层 dependencies 键（每行一个）。依赖值都是字符串且与键同行，
# 按行解析即可；这里只认顶层 dependencies（devDependencies 等不会命中）。
list_plugin_deps() {
	local manifest="$1"
	awk '
		BEGIN { in_deps = 0 }
		in_deps == 0 && $0 ~ /^[[:space:]]*"dependencies"[[:space:]]*:[[:space:]]*\{/ {
			in_deps = 1
			if ($0 ~ /\}/) in_deps = 0
			next
		}
		in_deps == 1 {
			if ($0 ~ /^[[:space:]]*\}/) { in_deps = 0; next }
			line = $0
			sub(/^[[:space:]]*"/, "", line)
			sub(/".*$/, "", line)
			if (line != "") print line
		}
	' "$manifest"
}

# 生成去掉全部依赖、并从 bundles 中剔除这些依赖名后的 manifest。
# 第一个入参是「一行一个插件名」的临时文件，第二个是原 manifest。
# 行级过滤后统一修掉数组/对象末尾元素被删掉时遗留的逗号。
rewrite_profile_manifest() {
	local names_file="$1" manifest="$2"
	awk -v names_file="$names_file" '
		FILENAME == names_file { plugins[$0] = 1; next }
		{ lines[++n] = $0 }
		END {
			out = 0; in_deps = 0; in_bundles = 0
			for (i = 1; i <= n; i++) {
				line = lines[i]
				if (in_deps == 0 && line ~ /^[[:space:]]*"dependencies"[[:space:]]*:[[:space:]]*\{/) {
					in_deps = 1
					if (line ~ /\}/) in_deps = 0
					keep[++out] = line
					continue
				}
				if (in_deps == 1) {
					if (line ~ /^[[:space:]]*\}/) { in_deps = 0; keep[++out] = line }
					continue
				}
				if (in_bundles == 0 && line ~ /^[[:space:]]*"bundles"[[:space:]]*:[[:space:]]*\[/) {
					in_bundles = 1
					keep[++out] = line
					continue
				}
				if (in_bundles == 1) {
					if (line ~ /^[[:space:]]*\]/) { in_bundles = 0; keep[++out] = line; continue }
					name = line
					sub(/^[[:space:]]*"/, "", name)
					sub(/".*$/, "", name)
					if (name in plugins) continue
					keep[++out] = line
					continue
				}
				keep[++out] = line
			}
			for (i = 1; i <= out; i++) {
				if (keep[i] ~ /,[[:space:]]*$/) {
					j = i + 1
					while (j <= out && keep[j] ~ /^[[:space:]]*$/) j++
					if (j <= out && keep[j] ~ /^[[:space:]]*[}\]]/) sub(/,[[:space:]]*$/, "", keep[i])
				}
			}
			for (i = 1; i <= out; i++) print keep[i]
		}
	' "$names_file" "$manifest"
}

# 重写后的 manifest 必须是合法 JSON。node 是 dsh 的硬依赖，正常安装一定有；
# 万一没有就跳过校验（行级重写只删除整行并修尾逗号，不会引入非法结构）。
manifest_is_valid() {
	ensure_node_env
	command -v node >/dev/null 2>&1 || return 0
	node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' "$1" >/dev/null 2>&1
}

plugins_usage() {
	cat <<EOF
dshctl plugins —— 管理 profile "$DSH_SERVICE_PROFILE" 的插件

用法: dshctl plugins <子命令> [选项]

  list                           列出当前 profile 已安装的插件
  reset [--yes] [--no-restart]   移除全部已安装插件（保留配置）
                                 --yes        不交互确认
                                 --no-restart 不改动服务（需稍后手动 restart）
EOF
}

cmd_plugins_list() {
	if [ $# -gt 0 ]; then
		die "plugins list: 未知参数 $1"
	fi
	local dir manifest names count
	dir="$(dsh_profile_dir)"
	manifest="$dir/package.json"
	printf 'profile  : %s\n' "$DSH_SERVICE_PROFILE"
	printf '目录     : %s\n' "$dir"
	if [ ! -f "$manifest" ]; then
		printf '插件     : 无（profile 尚未初始化）\n'
		return 0
	fi
	names="$(list_plugin_deps "$manifest")"
	if [ -z "$names" ]; then
		printf '插件     : 无\n'
		return 0
	fi
	count="$(printf '%s\n' "$names" | grep -c . || true)"
	printf '插件     : %s 个\n' "$count"
	printf '%s\n' "$names" | sed 's/^/  - /'
}

cmd_plugins_reset() {
	local assume_yes=0 no_restart=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--yes|-y) assume_yes=1; shift ;;
			--no-restart) no_restart=1; shift ;;
			*) die "plugins reset: 未知参数 $1" ;;
		esac
	done

	local dir manifest names count
	dir="$(dsh_profile_dir)"
	manifest="$dir/package.json"
	if [ ! -f "$manifest" ]; then
		log "profile \"$DSH_SERVICE_PROFILE\" 尚未初始化，没有已安装的插件（配置未改动）"
		return 0
	fi
	names="$(list_plugin_deps "$manifest")"
	if [ -z "$names" ]; then
		log "没有已安装的插件（配置未改动）"
		return 0
	fi
	count="$(printf '%s\n' "$names" | grep -c . || true)"

	printf '将移除 profile "%s" 的以下插件（共 %s 个），配置保持不变:\n' "$DSH_SERVICE_PROFILE" "$count"
	printf '%s\n' "$names" | sed 's/^/  - /'

	if [ "$assume_yes" != 1 ]; then
		if [ -t 0 ]; then
			printf '确认继续？[y/N] '
			read -r reply
			case "$reply" in
				y|Y|yes|YES) ;;
				*) log "已取消"; return 0 ;;
			esac
		else
			die "非交互式环境请加 --yes"
		fi
	fi

	local names_file new_manifest stopped=0
	names_file="$(mktemp "$dir/.plugins.XXXXXX")"
	TMP_FILES+=("$names_file")
	new_manifest="$(mktemp "$dir/.package.json.XXXXXX")"
	TMP_FILES+=("$new_manifest")
	printf '%s\n' "$names" > "$names_file"
	rewrite_profile_manifest "$names_file" "$manifest" > "$new_manifest"
	if ! manifest_is_valid "$new_manifest"; then
		rm -f -- "$new_manifest"
		err "重写后的 profile manifest 不是合法 JSON，已中止（插件与配置均未改动）"
		return 1
	fi

	# 先停服务，避免边跑边删导致运行中的进程加载到已被删除的模块。
	if [ "$no_restart" != 1 ] && have_user_systemd \
		&& [ "$(systemctl_user is-active "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true)" = active ]; then
		systemctl_user stop "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true
		stopped=1
		log "已停止服务: $DSH_SERVICE_UNIT_NAME"
	fi

	cp -p -- "$manifest" "$manifest.bak"
	chmod --reference="$manifest" "$new_manifest" 2>/dev/null || true
	mv -f -- "$new_manifest" "$manifest"
	log "已更新 profile manifest: $manifest（备份: $manifest.bak）"

	local modules="$dir/node_modules"
	if [ -d "$modules" ]; then
		rm -rf -- "$modules"
		log "已移除插件目录: $modules"
	fi
	if [ -f "$dir/pnpm-lock.yaml" ]; then
		rm -f -- "$dir/pnpm-lock.yaml"
		log "已移除插件锁文件: $dir/pnpm-lock.yaml"
	fi

	if [ "$no_restart" = 1 ]; then
		warn "按 --no-restart 跳过服务重启；运行中的进程仍持有旧插件，稍后请执行: dshctl restart"
	elif have_user_systemd; then
		if ! reload_and_restart 0; then
			err "服务重启失败，请查看: dshctl logs -n 30"
			return 1
		fi
	elif [ "$stopped" = 1 ]; then
		warn "服务已停止且无法连接用户级 systemd，请稍后手动启动: dshctl start"
	fi
	log "已移除 $count 个插件；配置（含 profile 的 cordis.patch.yml）保持不变。"
	return 0
}

cmd_plugins() {
	local sub="${1:-help}"
	if [ $# -gt 0 ]; then
		shift
	fi
	case "$sub" in
		list|ls) cmd_plugins_list "$@" ;;
		reset) cmd_plugins_reset "$@" ;;
		help|-h|--help) plugins_usage ;;
		*)
			err "plugins: 未知子命令: $sub"
			plugins_usage >&2
			exit 2
			;;
	esac
}

# ── 导出 / 导入 ──────────────────────────────────────────────────────────────
# 归档布局（tar.gz）：
#   manifest                    导出元数据与「可移植」的服务配置（纯 KEY=VALUE 文本）
#   config/dsh-service.config   本机配置副本（仅供查看；导入只读 manifest，绝不 source）
#   dsh-home/...                DSH_HOME 内容（node_modules 等可再生目录除外）
EXPORT_FORMAT=1

# manifest / 摘要里的 0-1 开关
inc_flag() {
	if [ "$1" = 1 ]; then
		printf '包含'
	else
		printf '不含'
	fi
}

export_usage() {
	cat <<'EOF'
dshctl export —— 导出服务配置与 DSH_HOME（会话、附件、profile 等）

用法: dshctl export [选项]

  -o, --output FILE      归档路径（默认 ./dsh-service-export-<主机>-<时间>.tar.gz）
  --no-sessions          不导出 ~/.dsh/sessions（默认导出）
  --no-attachments       不导出 ~/.dsh/attachments（默认导出）
  --with-secrets         导出 ~/.dsh/.credentials.yaml（默认不导出；内含 API Key 等密钥）
  --force                覆盖已存在的归档文件

归档内容：
  manifest                   元数据与可移植的服务配置（纯文本，导入时逐行读取）
  config/dsh-service.config  本机配置副本（仅供查看）
  dsh-home/...               DSH_HOME 内容（node_modules 等可再生目录除外）

node_modules 不会被导出。导入后在新环境执行以下命令重装插件：
  dsh plugin --profile <profile> install
或使用 dshctl import --install-plugins 自动完成。
EOF
}

cmd_export() {
	local output='' with_secrets=0 with_sessions=1 with_attachments=1 force=0
	while [ $# -gt 0 ]; do
		case "$1" in
			-o|--output) output="${2:?export: --output 需要一个文件路径}"; shift 2 ;;
			--output=*) output="${1#*=}"; shift ;;
			--with-secrets) with_secrets=1; shift ;;
			--no-secrets) with_secrets=0; shift ;;
			--with-sessions) with_sessions=1; shift ;;
			--no-sessions) with_sessions=0; shift ;;
			--with-attachments) with_attachments=1; shift ;;
			--no-attachments) with_attachments=0; shift ;;
			--force|-f) force=1; shift ;;
			-h|--help) export_usage; return 0 ;;
			*) die "export: 未知参数 $1" ;;
		esac
	done

	command -v tar >/dev/null 2>&1 || die "找不到 tar（导出需要 tar/gzip）"

	local host stamp
	host="$(uname -n 2>/dev/null || true)"
	[ -n "$host" ] || host=unknown
	host="$(printf '%s' "$host" | tr -c 'A-Za-z0-9._-' '-')"
	stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || true)"
	[ -n "$stamp" ] || stamp="$$"
	if [ -z "$output" ]; then
		output="dsh-service-export-${host}-${stamp}.tar.gz"
	fi
	case "$output" in
		*/) die "export: --output 需要文件路径，而不是目录: $output" ;;
	esac
	local out_dir out_base
	out_dir="$(dirname -- "$output")"
	out_base="$(basename -- "$output")"
	mkdir -p -- "$out_dir" || die "export: 无法创建目录: $out_dir"
	# tar 会在多次 -C 之后运行，这里先把输出路径固化为绝对路径。
	output="$(cd -- "$out_dir" && pwd)/$out_base"
	if [ -d "$output" ]; then
		die "export: 输出路径是一个目录: $output"
	fi
	if [ -e "$output" ] && [ "$force" != 1 ]; then
		die "export: 文件已存在: $output（加 --force 覆盖）"
	fi

	# manifest 是逐行 KEY=VALUE，换行会破坏格式；配置值此前已校验，这里兜底。
	local v
	for v in "$DSH_SERVICE_NAME" "$DSH_SERVICE_PROFILE" "$DSH_SERVICE_HOST" \
		"$DSH_SERVICE_PORT" "$DSH_SERVICE_DSH_HOME" "$DSH_SERVICE_EXTRA_ARGS" "$host"; do
		case "$v" in
			*$'\n'*|*$'\r'*) die "export: 值含换行，无法写入 manifest" ;;
		esac
	done

	local stage
	stage="$(mktemp -d "${TMPDIR:-/tmp}/dshctl-export.XXXXXX")" || die "export: 无法创建临时目录"
	TMP_FILES+=("$stage")
	mkdir -p -- "$stage/config" || die "export: 无法创建临时目录"

	{
		printf '%s\n' '# dsh-service export manifest'
		printf '%s\n' '# 纯 KEY=VALUE 文本；dshctl import 逐行读取，从不 source / eval 本文件。'
		printf 'DSHCTL_EXPORT_FORMAT=%s\n' "$EXPORT_FORMAT"
		printf 'DSHCTL_VERSION=%s\n' "$DSHCTL_VERSION"
		printf 'EXPORTED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
		printf 'EXPORTED_HOST=%s\n' "$host"
		printf 'DSH_VERSION=%s\n' "$(installed_dsh_version 2>/dev/null || true)"
		printf 'SOURCE_DSH_HOME=%s\n' "$DSH_SERVICE_DSH_HOME"
		printf 'SERVICE_NAME=%s\n' "$DSH_SERVICE_NAME"
		printf 'SERVICE_PROFILE=%s\n' "$DSH_SERVICE_PROFILE"
		printf 'SERVICE_HOST=%s\n' "$DSH_SERVICE_HOST"
		printf 'SERVICE_PORT=%s\n' "$DSH_SERVICE_PORT"
		printf 'SERVICE_EXTRA_ARGS=%s\n' "$DSH_SERVICE_EXTRA_ARGS"
		printf 'INCLUDE_SESSIONS=%s\n' "$with_sessions"
		printf 'INCLUDE_ATTACHMENTS=%s\n' "$with_attachments"
		printf 'INCLUDE_SECRETS=%s\n' "$with_secrets"
	} > "$stage/manifest" || die "export: 写入 manifest 失败"

	local have_config=0
	if [ -f "$CONFIG_FILE" ]; then
		if ! cp -p -- "$CONFIG_FILE" "$stage/config/dsh-service.config"; then
			die "export: 复制配置失败: $CONFIG_FILE"
		fi
		have_config=1
	else
		warn "配置文件不存在: $CONFIG_FILE（归档中不含配置副本）"
	fi

	# tar 支持在成员列表中途 -C 切换目录；--transform 只影响以 "." 开头的成员
	# （DSH_HOME 那一组），因此 manifest / config 保持原名，DSH_HOME 统一带前缀。
	local -a tar_cmd=(tar -czf "$output")
	tar_cmd+=(--exclude='*/node_modules' --exclude='*/.dsh-module-fallback' --exclude='*.lock')
	if [ "$with_sessions" != 1 ]; then
		tar_cmd+=(--exclude='./sessions')
	fi
	if [ "$with_attachments" != 1 ]; then
		tar_cmd+=(--exclude='./attachments')
	fi
	if [ "$with_secrets" != 1 ]; then
		tar_cmd+=(--exclude='./.credentials.yaml')
	fi
	tar_cmd+=(-C "$stage" manifest)
	if [ "$have_config" = 1 ]; then
		tar_cmd+=(config)
	fi

	local have_home=0
	if [ -d "$DSH_SERVICE_DSH_HOME" ]; then
		have_home=1
		# 输出文件若位于 DSH_HOME 内必须排除自身，否则 tar 会边写边读同一个文件。
		local home_real out_real
		home_real="$(readlink -f -- "$DSH_SERVICE_DSH_HOME" 2>/dev/null || printf '%s' "$DSH_SERVICE_DSH_HOME")"
		out_real="$(readlink -f -- "$output" 2>/dev/null || printf '%s' "$output")"
		case "$out_real" in
			"$home_real"/*) tar_cmd+=(--exclude="./${out_real#"$home_real"/}") ;;
		esac
		tar_cmd+=(-C "$DSH_SERVICE_DSH_HOME" --transform='s,^\.,dsh-home,' .)
	else
		warn "DSH_HOME 不存在: $DSH_SERVICE_DSH_HOME（归档中不含 DSH_HOME）"
	fi

	if ! "${tar_cmd[@]}"; then
		rm -f -- "$output"
		die "export: 打包失败（tar 退出非 0）"
	fi
	local size
	size="$(du -h -- "$output" 2>/dev/null | awk '{print $1}')"
	# 某些文件系统（drvfs 等）对很小的文件返回 0，退回按字节数显示。
	if [ -z "$size" ] || [ "$size" = 0 ]; then
		size="$(wc -c < "$output" 2>/dev/null | tr -d '[:space:]') 字节"
	fi

	log "已导出: $output（${size:-大小未知}）"
	printf '  来源      : %s@%s（dsh %s）\n' "$USER" "$host" "$(installed_dsh_version 2>/dev/null || printf '未检测到')"
	printf '  服务配置  : profile=%s host=%s port=%s\n' "$DSH_SERVICE_PROFILE" "$DSH_SERVICE_HOST" "$DSH_SERVICE_PORT"
	printf '  内容      : 会话=%s 附件=%s 凭证=%s DSH_HOME=%s\n' \
		"$(inc_flag "$with_sessions")" "$(inc_flag "$with_attachments")" \
		"$(inc_flag "$with_secrets")" "$(inc_flag "$have_home")"
	if [ "$with_secrets" != 1 ]; then
		printf '  提示      : 默认不含凭证；需要一并迁移密钥时加 --with-secrets\n'
	fi
	printf '  导入      : dshctl import %s\n' "\"$output\""
	if [ "$with_secrets" = 1 ]; then
		chmod 0600 -- "$output" 2>/dev/null || true
		warn "归档包含凭证（.credentials.yaml），请仅通过安全通道传输并妥善保管。"
	fi
	return 0
}

import_usage() {
	cat <<'EOF'
dshctl import —— 在新环境导入 dshctl export 生成的归档

用法: dshctl import <归档.tar.gz> [选项]

  --yes, -y           不交互确认（非交互式环境必须显式给出）
  --no-config         不应用归档中的服务配置（profile / host / port / extra args）
  --no-restart        导入后不重启服务
  --install-plugins   导入后执行 dsh plugin ... install 重装 profile 插件
  --dry-run           只显示将要执行的动作，不写入任何文件

行为说明：
  * 只应用「可移植」的配置项（profile / host / port / extra args）；DSH_HOME、
    nvm 目录、node bin 目录与本机单元名保留本机取值。
  * DSH_HOME 按文件合并写入；被覆盖的文件就地备份为 <文件>.~N~。
  * 原配置文件备份为 config.bak-<时间戳>。
EOF
}

cmd_import() {
	local archive='' assume_yes=0 no_restart=0 apply_config=1 install_plugins=0 dry_run=0 reply=''
	while [ $# -gt 0 ]; do
		case "$1" in
			--yes|-y) assume_yes=1; shift ;;
			--no-config) apply_config=0; shift ;;
			--no-restart) no_restart=1; shift ;;
			--install-plugins) install_plugins=1; shift ;;
			--dry-run) dry_run=1; shift ;;
			-h|--help) import_usage; return 0 ;;
			-*) die "import: 未知参数 $1" ;;
			*)
				if [ -n "$archive" ]; then
					die "import: 只能指定一个归档文件"
				fi
				archive="$1"
				shift
				;;
		esac
	done
	if [ -z "$archive" ]; then
		die "import: 缺少归档文件（用法: dshctl import <归档.tar.gz> [--yes]）"
	fi
	if [ ! -f "$archive" ]; then
		die "import: 找不到归档文件: $archive"
	fi
	command -v tar >/dev/null 2>&1 || die "找不到 tar（导入需要 tar/gzip）"

	local archive_abs
	archive_abs="$(cd -- "$(dirname -- "$archive")" && pwd)/$(basename -- "$archive")"

	local stage
	stage="$(mktemp -d "${TMPDIR:-/tmp}/dshctl-import.XXXXXX")" || die "import: 无法创建临时目录"
	TMP_FILES+=("$stage")

	# 先列出全部成员校验：只允许 manifest / config/ / dsh-home/ 三类顶层条目，
	# 且任何位置都不得出现 ".."，避免畸形归档写到 staging 之外。
	if ! tar -tzf "$archive_abs" > "$stage/.members" 2>/dev/null; then
		die "import: 无法读取归档（不是有效的 tar.gz？）: $archive"
	fi
	local member bad=''
	while IFS= read -r member; do
		case "$member" in
			''|manifest|manifest/|config|config/|dsh-home|dsh-home/) ;;
			config/*|dsh-home/*) ;;
			*)
				bad="$member"
				break
				;;
		esac
		case "$member" in
			../*|*/../*|..|*/..)
				bad="$member"
				break
				;;
		esac
	done < "$stage/.members"
	if [ -n "$bad" ]; then
		die "import: 归档含非法条目（可能不是 dshctl export 生成的）: $bad"
	fi
	# --no-same-owner：即使以 root 运行也不让归档里的 uid/gid 生效。
	if ! tar -xzf "$archive_abs" --no-same-owner -C "$stage"; then
		die "import: 解压失败"
	fi
	if [ ! -f "$stage/manifest" ]; then
		die "import: 归档缺少 manifest（不是 dshctl export 生成的归档）"
	fi

	local m_format='' m_version='' m_at='' m_host='' m_dsh='' m_src_home=''
	local m_name='' m_profile='' m_svc_host='' m_port='' m_extra=''
	local m_sessions='' m_attachments='' m_secrets=''
	local line key val
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			''|'#'*) continue ;;
		esac
		case "$line" in
			*=*) ;;
			*) die "import: manifest 格式错误: $line" ;;
		esac
		key="${line%%=*}"
		val="${line#*=}"
		case "$key" in
			''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) die "import: manifest 键名非法: $key" ;;
		esac
		case "$key" in
			DSHCTL_EXPORT_FORMAT) m_format="$val" ;;
			DSHCTL_VERSION) m_version="$val" ;;
			EXPORTED_AT) m_at="$val" ;;
			EXPORTED_HOST) m_host="$val" ;;
			DSH_VERSION) m_dsh="$val" ;;
			SOURCE_DSH_HOME) m_src_home="$val" ;;
			SERVICE_NAME) m_name="$val" ;;
			SERVICE_PROFILE) m_profile="$val" ;;
			SERVICE_HOST) m_svc_host="$val" ;;
			SERVICE_PORT) m_port="$val" ;;
			SERVICE_EXTRA_ARGS) m_extra="$val" ;;
			INCLUDE_SESSIONS) m_sessions="$val" ;;
			INCLUDE_ATTACHMENTS) m_attachments="$val" ;;
			INCLUDE_SECRETS) m_secrets="$val" ;;
			*) warn "import: 忽略未知 manifest 项: $key" ;;
		esac
	done < "$stage/manifest"

	if [ "$m_format" != "$EXPORT_FORMAT" ]; then
		die "import: 不支持的归档格式 ${m_format:-（空）}（本机 dshctl $DSHCTL_VERSION 支持格式 $EXPORT_FORMAT）"
	fi

	if [ -z "$m_name" ]; then m_name="$DSH_SERVICE_NAME"; fi
	case "$m_name" in
		*[!A-Za-z0-9_.@-]*) die "import: 归档中的单元名非法: $m_name" ;;
	esac
	if [ -z "$m_profile" ]; then m_profile="$DSH_SERVICE_PROFILE"; fi
	case "$m_profile" in
		*[!A-Za-z0-9_.@-]*) die "import: 归档中的 profile 名非法: $m_profile" ;;
	esac
	if [ -z "$m_port" ]; then
		m_port="$DSH_SERVICE_PORT"
	fi
	case "$m_port" in
		*[!0-9]*) die "import: 归档中的端口非法: $m_port" ;;
	esac
	if [ "${#m_port}" -gt 5 ] || [ "$((10#$m_port))" -lt 1 ] || [ "$((10#$m_port))" -gt 65535 ]; then
		die "import: 归档中的端口超出范围: $m_port"
	fi
	m_port="$((10#$m_port))"
	if [ -z "$m_svc_host" ]; then m_svc_host="$DSH_SERVICE_HOST"; fi

	local have_home=0
	if [ -d "$stage/dsh-home" ]; then
		have_home=1
	fi

	log "归档: $archive_abs"
	printf '  格式      : %s（dshctl %s，导出时间 %s）\n' "$m_format" "${m_version:-未知}" "${m_at:-未知}"
	printf '  来源      : %s（dsh %s）\n' "${m_host:-未知}" "${m_dsh:-未检测到}"
	printf '  DSH_HOME  : %s\n' "${m_src_home:-未知}"
	printf '              本机为 %s\n' "$DSH_SERVICE_DSH_HOME"
	printf '  服务配置  : profile=%s host=%s port=%s\n' "$m_profile" "$m_svc_host" "$m_port"
	printf '  内容      : 会话=%s 附件=%s 凭证=%s\n' \
		"$(inc_flag "$m_sessions")" "$(inc_flag "$m_attachments")" "$(inc_flag "$m_secrets")"
	if [ "$have_home" = 1 ]; then
		printf '  条目      : %s\n' "$(find "$stage/dsh-home" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | paste -sd ' ' -)"
	fi
	if [ "$m_secrets" = 1 ]; then
		warn "归档包含凭证（.credentials.yaml），导入会覆盖本机凭证（原文件就地备份为 .~N~）。"
	fi
	if [ "$apply_config" = 1 ] && [ "$m_name" != "$DSH_SERVICE_NAME" ]; then
		warn "归档中的单元名是 $m_name，与本机 $DSH_SERVICE_NAME 不同；保留本机单元名。"
	fi

	local do_restart=1
	if [ "$no_restart" = 1 ]; then
		do_restart=0
	fi
	if [ "$dry_run" = 1 ]; then
		log "dry-run：未写入任何文件。"
		printf '  将执行    : 服务配置=%s DSH_HOME=%s 插件安装=%s 服务重启=%s\n' \
			"$(inc_flag "$apply_config")" "$(inc_flag "$have_home")" \
			"$(inc_flag "$install_plugins")" "$(inc_flag "$do_restart")"
		return 0
	fi

	if [ "$assume_yes" != 1 ]; then
		if [ -t 0 ]; then
			printf '确认导入到 %s？[y/N] ' "$DSH_SERVICE_DSH_HOME"
			read -r reply
			case "$reply" in
				y|Y|yes|YES) ;;
				*)
					log "已取消"
					return 0
					;;
			esac
		else
			die "import: 非交互式环境请加 --yes"
		fi
	fi

	# 边跑边换 profile / 会话容易读到半旧半新的状态，先停服务，最后统一重启。
	local stopped=0
	if [ "$no_restart" != 1 ] && have_user_systemd \
		&& [ "$(systemctl_user is-active "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true)" = active ]; then
		systemctl_user stop "$DSH_SERVICE_UNIT_NAME" 2>/dev/null || true
		stopped=1
		log "已停止服务: $DSH_SERVICE_UNIT_NAME"
	fi

	if [ "$apply_config" = 1 ]; then
		if [ -f "$CONFIG_FILE" ]; then
			local cfg_bak
			cfg_bak="$CONFIG_FILE.bak-$(date +%Y%m%d%H%M%S 2>/dev/null || printf '%s' "$$")"
			if cp -p -- "$CONFIG_FILE" "$cfg_bak"; then
				log "已备份原配置: $cfg_bak"
			else
				warn "备份原配置失败: $CONFIG_FILE"
			fi
		fi
		DSH_SERVICE_PROFILE="$m_profile"
		DSH_SERVICE_HOST="$m_svc_host"
		DSH_SERVICE_PORT="$m_port"
		DSH_SERVICE_EXTRA_ARGS="$m_extra"
		# 单元名、DSH_HOME、nvm / node bin / local bin 都保留本机取值：它们指向
		# 具体主机的路径，照搬归档里的值会让新环境无法启动。
		render_config
	fi

	if [ "$have_home" = 1 ]; then
		if ! mkdir -p -- "$DSH_SERVICE_DSH_HOME"; then
			die "import: 无法创建 DSH_HOME: $DSH_SERVICE_DSH_HOME"
		fi
		# 目录内容合并拷贝；被覆盖的文件以 <文件>.~N~ 就地备份，未在归档中的文件保留。
		if ! cp -a --backup=numbered "$stage/dsh-home/." "$DSH_SERVICE_DSH_HOME/"; then
			die "import: 写入 DSH_HOME 失败: $DSH_SERVICE_DSH_HOME"
		fi
		log "已导入 DSH_HOME: $DSH_SERVICE_DSH_HOME（被覆盖的文件备份为 <文件>.~N~）"
	fi

	# profile 的插件依赖不在归档里（node_modules 被排除），需要时可自动重装。
	local manifest deps count
	manifest="$(dsh_profile_dir)/package.json"
	if [ -f "$manifest" ]; then
		deps="$(list_plugin_deps "$manifest")"
		if [ -n "$deps" ]; then
			count="$(printf '%s\n' "$deps" | grep -c . || true)"
			if [ "$install_plugins" = 1 ]; then
				log "重装 profile \"$DSH_SERVICE_PROFILE\" 的插件（$count 个）..."
				ensure_node_bin_path
				if ! run_dsh plugin --profile "$DSH_SERVICE_PROFILE" install; then
					warn "插件安装失败；请稍后手动执行: dsh plugin --profile $DSH_SERVICE_PROFILE install"
				fi
			else
				warn "profile 含 $count 个插件依赖，但归档不含 node_modules。"
				printf '  请稍后执行: dsh plugin --profile %s install\n' "$DSH_SERVICE_PROFILE" >&2
				printf '  或重新导入并加 --install-plugins\n' >&2
			fi
		fi
	fi

	if [ "$no_restart" = 1 ]; then
		if [ "$stopped" = 1 ]; then
			warn "服务已停止；请稍后执行 dshctl start"
		else
			warn "按 --no-restart 跳过服务重启；导入的配置将在下次启动时生效。"
		fi
	elif have_user_systemd; then
		if ! reload_and_restart 0; then
			err "import: 服务重启失败，请查看: dshctl logs -n 30"
			return 1
		fi
	else
		warn "无法连接用户级 systemd，跳过重启；请稍后手动执行: dshctl start"
	fi
	log "导入完成。"
	return 0
}

remove_rc_block() {
	local rc="$HOME/.bashrc" begin='# >>> dsh-service >>>' end='# <<< dsh-service <<<'
	if [ ! -f "$rc" ]; then
		return 0
	fi
	if ! grep -qF "$begin" "$rc"; then
		return 0
	fi
	if ! grep -qF "$end" "$rc"; then
		warn "$rc 中缺少结束标记 $end，跳过自动清理（请手动检查）"
		return 0
	fi
	cp -p -- "$rc" "$rc.dsh-service.bak"
	sed -i '/^# >>> dsh-service >>>$/,/^# <<< dsh-service <<<$/d' "$rc"
	log "已从 $rc 移除 dsh-service 配置（备份: $rc.dsh-service.bak）"
}

cmd_uninstall() {
	local purge=0 remove_home=0 remove_node=0 assume_yes=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--purge) purge=1; shift ;;
			--remove-dsh-home) remove_home=1; shift ;;
			--remove-node) remove_node=1; shift ;;
			--yes|-y) assume_yes=1; shift ;;
			*) die "uninstall: 未知参数 $1" ;;
		esac
	done

	if [ "$assume_yes" != 1 ]; then
		if [ -t 0 ]; then
			printf '确认卸载 %s 服务？[y/N] ' "$DSH_SERVICE_UNIT_NAME"
			read -r reply
			case "$reply" in
				y|Y|yes|YES) ;;
				*) log "已取消"; return 0 ;;
			esac
		else
			die "非交互式环境请加 --yes"
		fi
	fi

	if have_user_systemd; then
		systemctl_user disable --now "$DSH_SERVICE_UNIT_NAME" 2>/dev/null \
			|| systemctl_user stop "$DSH_SERVICE_UNIT_NAME" 2>/dev/null \
			|| true
		systemctl_user daemon-reload 2>/dev/null || true
	fi
	rm -f -- "$DSH_SERVICE_UNIT" "$DSH_SERVICE_UNIT.bak" "$DSH_SERVICE_DSH_BIN"
	# 删除已安装的 dshctl；$0 可能是别处的副本，也一并清理（source 时 $0 为父 shell，不能删）。
	rm -f -- "$DSH_SERVICE_LOCAL_BIN/dshctl" 2>/dev/null || true
	if [ -f "$0" ] && [ "$0" != "$DSH_SERVICE_LOCAL_BIN/dshctl" ] && [ "$(basename -- "$0")" = dshctl ]; then
		rm -f -- "$0" 2>/dev/null || true
	fi
	log "已移除服务单元、dsh 稳定入口与 dshctl"

	if [ "$purge" = 1 ]; then
		rm -rf -- "$CONFIG_DIR"
		remove_rc_block
		log "已移除配置目录: $CONFIG_DIR"
	fi

	if [ "$remove_home" = 1 ]; then
		rm -rf -- "$DSH_SERVICE_DSH_HOME"
		log "已移除 DSH_HOME: $DSH_SERVICE_DSH_HOME"
	fi

	if [ "$remove_node" = 1 ]; then
		load_nvm
		with_loose_shell nvm uninstall "$(node_major)" || warn "nvm uninstall 失败，请手动处理"
	fi

	log "卸载完成。npm 全局包若需移除: npm uninstall -g @deepseek-ai/dsh"
}

# ── 入口 ─────────────────────────────────────────────────────────────────────
main() {
	local cmd="${1:-help}"
	if [ $# -gt 0 ]; then
		shift
	fi
	case "$cmd" in
		start) cmd_start "$@" ;;
		stop) cmd_stop "$@" ;;
		restart) cmd_restart "$@" ;;
		status) cmd_status "$@" ;;
		enable) cmd_enable "$@" ;;
		disable) cmd_disable "$@" ;;
		logs) cmd_logs "$@" ;;
		url) cmd_url "$@" ;;
		version) cmd_version "$@" ;;
		config) cmd_config "$@" ;;
		doctor) cmd_doctor "$@" ;;
		upgrade) cmd_upgrade "$@" ;;
		upgrade-node) cmd_upgrade_node "$@" ;;
		run) cmd_run "$@" ;;
		plugins) cmd_plugins "$@" ;;
		export) cmd_export "$@" ;;
		import) cmd_import "$@" ;;
		uninstall) cmd_uninstall "$@" ;;
		_render-config) render_config "$@" ;;
		_render-unit) render_unit "$@" ;;
		_enable) internal_enable "$@" ;;
		_linger) internal_linger "$@" ;;
		help|-h|--help) usage ;;
		-V|--version) printf 'dshctl %s\n' "$DSHCTL_VERSION" ;;
		*)
			err "未知命令: $cmd"
			usage >&2
			exit 2
			;;
	esac
}

main "$@"
DSHCTL_EMBED_EOF
# read -d '' 会保留结尾换行；去掉它，使 --print-dshctl / write_file 的输出与
# 源码内嵌段逐字节一致（便于 `diff <(bash install.sh --print-dshctl) 源文件段落`）。
DSHCTL_SRC="${DSHCTL_SRC%$'\n'}"
# ── 内嵌 dshctl 结束 ─────────────────────────────────────────────────────────

# =============================================================================
#  install.sh 主体
# =============================================================================
DRY_RUN=0
NO_SERVICE=0
NO_LINGER=0
NO_RC=0
NO_PNPM=0
FORCE=0
ALLOW_ROOT=0
STRICT_PORT=0
SHOW_HELP=0
PRINT_DSHCTL=0
OPT_PORT=""
OPT_NAME=""
OPT_NODE_MAJOR=""
OPT_NVM_VERSION=""
OPT_DSH_VERSION=""
OPT_PNPM_VERSION=""
OPT_PREFIX=""
OPT_MIRROR=""

usage() {
	cat <<'EOF'
dsh-service 一键安装脚本

用法: bash install.sh [选项]

选项:
  --port N              Web 监听端口（默认 3080）
  --name NAME           systemd 单元名，不含 .service（默认 dsh）
  --node-major N        通过 nvm 安装的 Node 主版本（默认 24）
  --nvm-version V       nvm 版本标签（默认 v0.40.1）
  --dsh-version V       @deepseek-ai/dsh 版本或 dist-tag（默认 next）
  --pnpm-version V      pnpm 版本或 dist-tag（默认 latest）
  --prefix DIR          用户级可执行目录（默认 $HOME/.local/bin）
  --mirror              使用国内镜像源（默认；npm/Node 走 npmmirror，nvm 走 Gitee）
  --no-mirror           使用官方源（registry.npmjs.org / nodejs.org / GitHub）
  --no-pnpm             不安装 pnpm
  --no-service          只安装并写入单元，不启用/启动服务
  --no-linger           不设置 loginctl linger（开机未登录时不自启）
  --no-rc               不修改 ~/.bashrc
  --force               即使已是最新版本也重新安装
  --strict-port         端口被占用时直接报错，不自动改用其它端口
  --dry-run             只打印将要执行的动作，不做任何修改
  --allow-root          允许以 root 运行（用户级服务不推荐）
  --print-dshctl        仅输出内嵌的 dshctl 脚本后退出
  -h, --help            显示本帮助

说明:
  * 模型密钥 DEEPSEEK_API_KEY 不由本脚本处理，请在 Web 界面中配置。
  * 默认使用国内镜像：npm 与 Node 二进制走 npmmirror，nvm 安装脚本与仓库走 Gitee；
    系统包管理器（apt/dnf/yum）的软件源一律不改动。需要官方源时加 --no-mirror。
  * 安装前会检查端口：若被占用，自动改用后续空闲端口（--strict-port 则直接报错）。
  * 服务仅监听 127.0.0.1；远程访问请使用 SSH 端口转发：
      ssh -N -L 3080:127.0.0.1:3080 <主机>
  * 重复执行是安全的：已完成的步骤会跳过，自定义配置会被保留。
EOF
}

log()  { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

if [ -t 1 ]; then
	C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
	C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

# ── 参数解析 ─────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
	case "$1" in
		--port) OPT_PORT="${2:?--port 需要一个端口}"; shift 2 ;;
		--port=*) OPT_PORT="${1#*=}"; shift ;;
		--name) OPT_NAME="${2:?--name 需要一个名字}"; shift 2 ;;
		--name=*) OPT_NAME="${1#*=}"; shift ;;
		--node-major) OPT_NODE_MAJOR="${2:?--node-major 需要一个主版本号}"; shift 2 ;;
		--node-major=*) OPT_NODE_MAJOR="${1#*=}"; shift ;;
		--nvm-version) OPT_NVM_VERSION="${2:?--nvm-version 需要一个版本标签}"; shift 2 ;;
		--nvm-version=*) OPT_NVM_VERSION="${1#*=}"; shift ;;
		--dsh-version) OPT_DSH_VERSION="${2:?--dsh-version 需要一个版本}"; shift 2 ;;
		--dsh-version=*) OPT_DSH_VERSION="${1#*=}"; shift ;;
		--pnpm-version) OPT_PNPM_VERSION="${2:?--pnpm-version 需要一个版本}"; shift 2 ;;
		--pnpm-version=*) OPT_PNPM_VERSION="${1#*=}"; shift ;;
		--prefix) OPT_PREFIX="${2:?--prefix 需要一个目录}"; shift 2 ;;
		--prefix=*) OPT_PREFIX="${1#*=}"; shift ;;
		--mirror) OPT_MIRROR=1; shift ;;
		--no-mirror) OPT_MIRROR=0; shift ;;
		--no-pnpm) NO_PNPM=1; shift ;;
		--no-service) NO_SERVICE=1; shift ;;
		--no-linger) NO_LINGER=1; shift ;;
		--no-rc) NO_RC=1; shift ;;
		--force) FORCE=1; shift ;;
		--strict-port) STRICT_PORT=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		--allow-root) ALLOW_ROOT=1; shift ;;
		--print-dshctl) PRINT_DSHCTL=1; shift ;;
		-h|--help) SHOW_HELP=1; shift ;;
		*) die "未知参数: $1（试试 --help）" ;;
	esac
done

if [ "$PRINT_DSHCTL" = 1 ]; then
	printf '%s\n' "$DSHCTL_SRC"
	exit 0
fi
if [ "$SHOW_HELP" = 1 ]; then
	usage
	exit 0
fi

# ── 默认值：先取已有配置，再用命令行覆盖 ─────────────────────────────────────
# HOME 必须在任何 $HOME/... 默认值之前检查：否则 set -u 会先以
# “HOME: unbound variable” 崩溃，给出误导性的报错。
if [ -z "${HOME:-}" ]; then
	die "缺少 HOME 环境变量（无法定位 ~/.config、~/.dsh 与 ~/.nvm）"
fi
CONFIG_DIR="${DSHCTL_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-service}"
CONFIG_FILE="$CONFIG_DIR/config"
if [ -r "$CONFIG_FILE" ]; then
	if ! bash -n -- "$CONFIG_FILE" 2>/dev/null; then
		die "配置文件语法错误: $CONFIG_FILE（请修复或删除后重跑；不会覆盖损坏的文件）"
	fi
	# shellcheck source=/dev/null
	. "$CONFIG_FILE"
fi
: "${DSH_SERVICE_NAME:=dsh}"
: "${DSH_SERVICE_PROFILE:=web}"
: "${DSH_SERVICE_HOST:=127.0.0.1}"
: "${DSH_SERVICE_PORT:=3080}"
: "${DSH_SERVICE_DSH_HOME:=$HOME/.dsh}"
: "${DSH_SERVICE_NVM_DIR:=$HOME/.nvm}"
: "${DSH_SERVICE_NODE_BIN_DIR:=}"
: "${DSH_SERVICE_LOCAL_BIN:=$HOME/.local/bin}"
: "${DSH_SERVICE_EXTRA_ARGS:=}"

# 记住「本次运行之前」生效的单元名（来自旧配置或环境）：--name 变更后旧单元
# 仍会 enabled/运行，并可能与新单元抢同一端口，成功渲染新单元后需要清理它。
PREV_NAME="$DSH_SERVICE_NAME"

NAME="${OPT_NAME:-$DSH_SERVICE_NAME}"
PORT="${OPT_PORT:-$DSH_SERVICE_PORT}"
DSH_HOME="${DSH_SERVICE_DSH_HOME}"
NVM_DIR="${DSH_SERVICE_NVM_DIR}"
# 变量名不要用 PREFIX：nvm 会把 PREFIX 误认为 node 的安装前缀，
# 只要它非空，`nvm install` 就会以 “not compatible with the PREFIX
# environment variable” 直接失败（见 nvm.sh 的 nvm_do_install）。
LOCAL_BIN_DIR="${OPT_PREFIX:-$DSH_SERVICE_LOCAL_BIN}"
NODE_MAJOR="${OPT_NODE_MAJOR:-24}"
# 保留已安装的 Node：未显式传入 --node-major 时，优先沿用配置里记录的 Node 二进制目录
# 所对应的主版本，避免重跑 install.sh 把现有安装自动迁移到新的默认主版本（幂等契约）。
# 记录缺失或目录已失效（新安装、被手工删除）时才回退到默认主版本。
NODE_MAJOR_KEPT=0
if [ -z "$OPT_NODE_MAJOR" ] && [ -n "$DSH_SERVICE_NODE_BIN_DIR" ] && [ -x "$DSH_SERVICE_NODE_BIN_DIR/node" ]; then
	kept_major="$("$DSH_SERVICE_NODE_BIN_DIR/node" --version 2>/dev/null | sed -e 's/^v//' -e 's/\..*//' || true)"
	case "$kept_major" in
		''|*[!0-9]*) ;;
		*)
			NODE_MAJOR="$kept_major"
			NODE_MAJOR_KEPT=1
			;;
	esac
fi
NVM_VERSION="${OPT_NVM_VERSION:-v0.40.1}"
# 默认通道：dsh 以 rc 版本对外发布，npm 的 latest 常常落后于 next，因此新安装默认
# 跟随 next（与内嵌 dshctl 的 DSH_DEFAULT_CHANNEL 保持一致）。--dsh-version 可显式
# 覆盖为 latest / 其他 dist-tag / 具体版本。
DSH_DEFAULT_CHANNEL='next'
DSH_VERSION="${OPT_DSH_VERSION:-$DSH_DEFAULT_CHANNEL}"
# pnpm 与 dsh 同为可选全局包：默认 latest，可用 --pnpm-version / DSH_PNPM_VERSION 固定。
PNPM_VERSION="${OPT_PNPM_VERSION:-${DSH_PNPM_VERSION:-latest}}"
# 实际解析/安装到的版本（dist-tag 会被解析成具体版本号），供末尾汇总显示。
RESOLVED_DSH_VERSION="$DSH_VERSION"
RESOLVED_PNPM_VERSION="$PNPM_VERSION"
EXTRA_ARGS="$DSH_SERVICE_EXTRA_ARGS"

case "$PORT" in
	''|*[!0-9]*) die "--port 需要数字，收到 '$PORT'" ;;
esac
if [ "${#PORT}" -gt 5 ] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
	die "--port 必须在 1-65535 之间，收到 '$PORT'"
fi
# 归一化前导零：$((PORT + i)) 会把 080 当八进制直接报错、把 010 当成 8，
# 而 test/awk 又是十进制，混用会崩溃或换到错误端口。
PORT="$((10#$PORT))"
case "$NAME" in
	''|*[!A-Za-z0-9_.@-]*) die "--name 只允许字母、数字、下划线、点、@ 和连字符，收到 '$NAME'" ;;
esac
case "$NODE_MAJOR" in
	''|*[!A-Za-z0-9._/-]*) die "--node-major 只允许字母、数字、点、下划线、斜杠和连字符，收到 '$NODE_MAJOR'" ;;
esac
if [ "$NODE_MAJOR_KEPT" = 1 ]; then
	log "沿用已安装的 Node 主版本 $NODE_MAJOR（$DSH_SERVICE_NODE_BIN_DIR）；如需切换请用 --node-major <主版本> 或 dshctl upgrade-node <主版本>"
fi
# --nvm-version 会被拼进下载 URL 并由 bash 执行，限制为 tag 形态的字符集，
# 并拒绝目录穿越（..）与以 - 开头（会被 install.sh 当选项）。
case "$NVM_VERSION" in
	''|*[!A-Za-z0-9._-]*|*..*|-*) die "--nvm-version 只允许字母、数字、点、下划线和连字符（例如 v0.40.1），收到 '$NVM_VERSION'" ;;
esac
# pnpm 版本会作为 npm 参数（已加引号），仍限制字符集避免误传选项/注入。
case "$PNPM_VERSION" in
	''|*[!A-Za-z0-9._+-]*) die "--pnpm-version 只允许字母、数字、点、下划线、加号和连字符（例如 9.15.0 或 latest），收到 '$PNPM_VERSION'" ;;
esac
case "$LOCAL_BIN_DIR" in
	/*) ;;
	*) die "--prefix 必须是绝对路径，收到 '$LOCAL_BIN_DIR'" ;;
esac
case "$LOCAL_BIN_DIR" in
	*' '*|*$'\t'*) warn "--prefix 含空格或制表符（'$LOCAL_BIN_DIR'），systemd 单元的 ExecStart 可能无法正确解析。" ;;
esac

UNIT_NAME="$NAME.service"
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT_NAME"
DSHCTL_BIN="$LOCAL_BIN_DIR/dshctl"

# ── 镜像源（默认国内；apt/dnf/yum 等系统包管理器的软件源不在此列） ───────────
# npm 与 Node 二进制默认走 npmmirror，nvm 的安装脚本与仓库默认走 Gitee 镜像。
# DSH_SERVICE_MIRROR / DSH_SERVICE_NPM_REGISTRY / DSH_SERVICE_NODE_MIRROR 会被写入
# 配置，供 dshctl upgrade / upgrade-node 复用；--mirror / --no-mirror 是本次运行的
# 显式切换，会连同具体 URL 覆盖配置里的旧值（否则切换模式会被旧 URL 抵消）。
: "${DSH_SERVICE_MIRROR:=1}"
if [ -n "$OPT_MIRROR" ]; then
	DSH_SERVICE_MIRROR="$OPT_MIRROR"
	unset DSH_SERVICE_NPM_REGISTRY DSH_SERVICE_NODE_MIRROR DSH_NVM_SOURCE DSH_NVM_INSTALL_URL
fi
case "$DSH_SERVICE_MIRROR" in
	1|0) ;;
	*) die "DSH_SERVICE_MIRROR 只能是 1（国内镜像）或 0（官方源），收到 '$DSH_SERVICE_MIRROR'" ;;
esac
if [ "$DSH_SERVICE_MIRROR" = 1 ]; then
	: "${DSH_SERVICE_NPM_REGISTRY:=https://registry.npmmirror.com}"
	: "${DSH_SERVICE_NODE_MIRROR:=https://npmmirror.com/mirrors/node}"
else
	: "${DSH_SERVICE_NPM_REGISTRY:=https://registry.npmjs.org}"
	: "${DSH_SERVICE_NODE_MIRROR:=}"
fi
# nvm 安装脚本：默认同样从 Gitee 镜像下载 nvm 官方脚本（内容与 raw.githubusercontent 一致）。
if [ -n "${DSH_NVM_INSTALL_URL:-}" ]; then
	NVM_INSTALL_URL="$DSH_NVM_INSTALL_URL"
elif [ "$DSH_SERVICE_MIRROR" = 1 ]; then
	NVM_INSTALL_URL="https://gitee.com/mirrors/nvm/raw/$NVM_VERSION/install.sh"
else
	NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh"
fi
# NVM_SOURCE（git clone 的仓库地址）只在 nvm 走 git 方式时有效：没有 git 时 nvm
# 改用脚本下载，此时若仍导出仓库地址，nvm 会把 "<repo>.git" 当成 nvm.sh 下载，
# 结果是一份无法加载的假 nvm.sh。
NVM_SOURCE_EFFECTIVE="${DSH_NVM_SOURCE:-}"
if [ -z "$NVM_SOURCE_EFFECTIVE" ] && [ "$DSH_SERVICE_MIRROR" = 1 ]; then
	NVM_SOURCE_EFFECTIVE="https://gitee.com/mirrors/nvm.git"
fi
if [ -n "$NVM_SOURCE_EFFECTIVE" ] && ! command -v git >/dev/null 2>&1; then
	warn "未找到 git：nvm 将以脚本方式安装，NVM_SOURCE 镜像不生效（nvm-exec 等仍需访问 GitHub）"
	NVM_SOURCE_EFFECTIVE=""
fi

# apply_mirrors：把上面的设置注入 npm 与 nvm。用户环境里已显式设置的
# npm_config_registry / NVM_NODEJS_ORG_MIRROR / NVM_SOURCE 优先，不被覆盖。
apply_mirrors() {
	if [ -n "${DSH_SERVICE_NPM_REGISTRY:-}" ] && [ -z "${npm_config_registry:-}" ]; then
		export npm_config_registry="$DSH_SERVICE_NPM_REGISTRY"
	fi
	if [ -n "${DSH_SERVICE_NODE_MIRROR:-}" ] && [ -z "${NVM_NODEJS_ORG_MIRROR:-}" ]; then
		export NVM_NODEJS_ORG_MIRROR="$DSH_SERVICE_NODE_MIRROR"
	fi
	if [ -n "${NVM_SOURCE_EFFECTIVE:-}" ] && [ -z "${NVM_SOURCE:-}" ]; then
		export NVM_SOURCE="$NVM_SOURCE_EFFECTIVE"
	fi
}

log "dsh-service 安装器 v$INSTALLER_VERSION（dry-run=${DRY_RUN}）"

if [ "$(id -u)" -eq 0 ] && [ "$ALLOW_ROOT" != 1 ]; then
	die "检测到以 root 运行。用户级 systemd 服务应使用普通用户安装；如确需如此请加 --allow-root。"
fi
case "$HOME" in
	*' '*|*$'\t'*|*:*)
		warn "HOME 路径包含空格、制表符或冒号（'$HOME'），systemd 单元可能无法正确解析。"
		;;
esac
case "$DSH_HOME/" in
	/mnt/*)
		warn "DSH_HOME 位于 /mnt（WSL drvfs 的符号链接不可靠，profile 初始化可能失败）：$DSH_HOME"
		warn "建议用 DSH_SERVICE_DSH_HOME=/home/<用户>/.dsh 指定 Linux 原生路径后重跑。"
		;;
esac

# ── 工具函数 ─────────────────────────────────────────────────────────────────
# 临时文件登记表：任何退出路径都会清理（write_file、nvm 安装脚本）。
TMP_FILES=()
cleanup_tmp() {
	local f
	for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
		rm -f -- "$f" 2>/dev/null || true
	done
	return 0
}
trap cleanup_tmp EXIT

run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] %s\n' "$*"
		return 0
	fi
	"$@"
}

write_file() {
	local path="$1" content="$2" mode="${3:-0644}" tmp
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] 写入 %s (mode %s)\n' "$path" "$mode"
		return 0
	fi
	mkdir -p -- "$(dirname -- "$path")"
	tmp="$(mktemp "$(dirname -- "$path")/.tmp.XXXXXX")"
	TMP_FILES+=("$tmp")
	printf '%s\n' "$content" > "$tmp"
	chmod "$mode" "$tmp"
	if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
		rm -f -- "$tmp"
		log "未变化: $path"
		return 0
	fi
	mv -f -- "$tmp" "$path"
	log "已写入: $path"
}

# 把值安全地嵌进 shell 双引号上下文（.bashrc）：反斜杠、双引号、$ 与反引号。
# 与 dshctl 的 shell_q 同规则；缺少它时 --prefix 里的 " 会直接写坏用户的 .bashrc。
rc_q() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g'
}

# ── 端口预检 ─────────────────────────────────────────────────────────────────
# 端口是否有监听者：优先 ss / lsof（能识别“已 bind 但未 accept”的情况），
# 都不可用时退回 bash 的 /dev/tcp 连接测试。
port_in_use() {
	local port="$1"
	if command -v ss >/dev/null 2>&1; then
		# 按冒号切分后比较端口号，避免 ":3080" 同时命中 ":30800"。
		ss -ltn 2>/dev/null | awk -v port="$port" '
			NR > 1 {
				n = split($4, a, ":")
				if (a[n] == port) { found = 1 }
			}
			END { exit found ? 0 : 1 }'
		return $?
	fi
	if command -v lsof >/dev/null 2>&1; then
		lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
		return $?
	fi
	(exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}

# 占用端口的监听项（用于提示，拿不到时输出为空）。
port_holder() {
	local port="$1"
	command -v ss >/dev/null 2>&1 || return 0
	ss -ltnp 2>/dev/null | awk -v port="$port" '
		NR > 1 {
			n = split($4, a, ":")
			if (a[n] == port) { print }
		}' | head -n 1
}

# 端口是否属于本安装器管理的服务：单元存在、ExecStart 用的就是这个端口，
# 且服务处于 active。用于「重跑安装器」时避免把自己的端口误判为被占用。
port_is_ours() {
	local port="$1"
	[ -f "$UNIT_FILE" ] || return 1
	grep -qE -- "--port ${port}([[:space:]]|\$)" "$UNIT_FILE" || return 1
	if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
		export XDG_RUNTIME_DIR="/run/user/$(id -u)"
	fi
	systemctl --user is-active "$UNIT_NAME" >/dev/null 2>&1
}

# 安装前确定最终端口：被占用则自动改用后续空闲端口（--strict-port 时直接报错）。
resolve_port() {
	if ! port_in_use "$PORT"; then
		return 0
	fi
	if port_is_ours "$PORT"; then
		log "端口 $PORT 正由本服务（$UNIT_NAME）使用，保持不变"
		return 0
	fi

	local holder
	holder="$(port_holder "$PORT" || true)"
	if [ -n "$holder" ]; then
		warn "端口 $PORT 已被占用: $holder"
	else
		warn "端口 $PORT 已被占用"
	fi
	if [ "$STRICT_PORT" = 1 ]; then
		die "端口 $PORT 被占用（--strict-port：不自动切换）。请用 --port 指定其它端口。"
	fi

	local i=0 candidate
	while [ "$i" -lt 20 ]; do
		i=$((i + 1))
		candidate=$((PORT + i))
		if [ "$candidate" -gt 65535 ]; then
			break
		fi
		if ! port_in_use "$candidate"; then
			warn "自动改用端口 $candidate（原端口 $PORT 被占用）"
			PORT="$candidate"
			return 0
		fi
	done
	die "从 $PORT 起连续 20 个端口都被占用，无法自动选择；请用 --port 指定空闲端口。"
}

# ── nvm 调用包装 ─────────────────────────────────────────────────────────────
# nvm.sh 与 `set -u` 不兼容：它的下载失败路径会直接引用未定义的变量（如 TMPDIR），
# 在 install.sh 的 `set -Eeuo pipefail` 下会立刻以 “TMPDIR: unbound variable”
# 终止整个脚本，把真正的错误（下载失败）掩盖成一句莫名其妙的报错。所有 nvm 调用
# 都在临时关闭 -u/-e 后执行，命令返回后恢复原选项。
with_loose_shell() {
	local had_u=0 had_e=0 rc=0
	case $- in *u*) had_u=1 ;; esac
	case $- in *e*) had_e=1 ;; esac
	set +u +e
	"$@" || rc=$?
	if [ "$had_u" = 1 ]; then set -u; fi
	if [ "$had_e" = 1 ]; then set -e; fi
	return "$rc"
}

# nvm_loadable：nvm.sh 语法正确且能定义 nvm 函数。用于识别「上次安装中途失败、
# 只剩一个残缺 ~/.nvm」的情况（此时不能像正常安装那样直接跳过 nvm 步骤）。
nvm_loadable() {
	[ -s "$NVM_DIR/nvm.sh" ] || return 1
	bash -n "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || return 1
	with_loose_shell env NVM_DIR="$NVM_DIR" bash -c \
		'set +u; . "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1 && declare -F nvm >/dev/null 2>&1'
}

# ── 步骤 1：nvm ──────────────────────────────────────────────────────────────
ensure_nvm() {
	if [ -s "$NVM_DIR/nvm.sh" ]; then
		if nvm_loadable; then
			log "nvm 已安装: $NVM_DIR"
			return 0
		fi
		# ~/.nvm 已存在时 nvm 官方安装脚本无法重新克隆，只能提示用户处理。
		warn "nvm 目录存在但无法加载（$NVM_DIR/nvm.sh 可能不完整）"
		warn "若下面安装 Node 失败，请删除 $NVM_DIR 后重跑 install.sh"
		return 0
	fi
	# tag 可以被移动，摘要不能。可用 DSH_NVM_INSTALL_SHA256=<64位十六进制> 固定。
	local url="$NVM_INSTALL_URL"
	local sha="${DSH_NVM_INSTALL_SHA256:-}" tmp
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] 下载并执行 %s（sha256=%s）\n' "$url" "${sha:-未指定，仅打印}"
		return 0
	fi
	case "$sha" in
		'') ;;
		*[!0-9a-fA-F]*) die "DSH_NVM_INSTALL_SHA256 必须是十六进制摘要，收到 '$sha'" ;;
	esac
	if [ -n "$sha" ] && [ "${#sha}" -ne 64 ]; then
		die "DSH_NVM_INSTALL_SHA256 必须是 64 位十六进制，收到 ${#sha} 位"
	fi

	tmp="$(mktemp "${TMPDIR:-/tmp}/dsh-nvm-install.XXXXXX")"
	TMP_FILES+=("$tmp")
	log "下载 nvm 安装脚本 $NVM_VERSION ..."
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$tmp" "$url" || die "nvm 安装脚本下载失败（网络不可用？）：$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$tmp" "$url" || die "nvm 安装脚本下载失败（网络不可用？）：$url"
	else
		die "缺少 curl/wget，无法安装 nvm"
	fi
	if [ ! -s "$tmp" ]; then
		die "nvm 安装脚本为空: $url"
	fi
	if [ -n "$sha" ]; then
		if ! command -v sha256sum >/dev/null 2>&1; then
			die "系统缺少 sha256sum，无法校验 DSH_NVM_INSTALL_SHA256（请安装 coreutils）"
		fi
		if ! printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
			die "nvm 安装脚本 sha256 校验失败（期望 $sha，实际 $(sha256sum "$tmp" | awk '{print $1}')）"
		fi
		log "nvm 安装脚本 sha256 校验通过"
	elif command -v sha256sum >/dev/null 2>&1; then
		log "nvm 安装脚本 sha256: $(sha256sum "$tmp" | awk '{print $1}')（可用 DSH_NVM_INSTALL_SHA256 固定）"
	else
		warn "系统缺少 sha256sum，无法打印安装脚本摘要（请安装 coreutils）"
	fi
	log "安装 nvm $NVM_VERSION ..."
	if ! bash "$tmp"; then
		die "nvm 安装失败（网络不可用？）：$url"
	fi
	rm -f -- "$tmp"
	if [ ! -s "$NVM_DIR/nvm.sh" ]; then
		die "nvm 安装后仍未找到 $NVM_DIR/nvm.sh（可能安装到了其他 NVM_DIR）"
	fi
}

# ── 步骤 2：Node ─────────────────────────────────────────────────────────────
# load_nvm：必须在当前 shell 中加载（要拿到 nvm 函数与 PATH 改动）。
load_nvm() {
	# 同 dshctl：nvm 遇到已设置的 PREFIX 会拒绝执行 `nvm install`（哪怕它来自其他工具）。
	unset PREFIX
	export NVM_DIR="$NVM_DIR"
	# shellcheck source=/dev/null
	if ! with_loose_shell . "$NVM_DIR/nvm.sh" --no-use; then
		die "无法加载 nvm（$NVM_DIR/nvm.sh 缺失或损坏）。请删除 $NVM_DIR 后重跑 install.sh。"
	fi
}

# load_nvm_soft：nvm 缺失/损坏时安静返回 1，不中断安装（Node 可能已经装好了）。
load_nvm_soft() {
	[ -s "$NVM_DIR/nvm.sh" ] || return 1
	unset PREFIX
	export NVM_DIR="$NVM_DIR"
	# shellcheck source=/dev/null
	with_loose_shell . "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1
}

# nvm_local_node_bin：~/.nvm 下已经装好的、与 --node-major 匹配的 node。
# 只处理纯数字主版本（如 22）；`lts/iron`、`22.23.2` 这类交给 nvm 自己解析。
nvm_local_node_bin() {
	case "$NODE_MAJOR" in
		''|*[!0-9]*) return 1 ;;
	esac
	local candidates=() c
	for c in "$NVM_DIR"/versions/node/v"$NODE_MAJOR".*/bin/node; do
		if [ -x "$c" ]; then candidates+=("$c"); fi
	done
	if [ "${#candidates[@]}" -eq 0 ]; then
		return 1
	fi
	# sort -V 取最高的补丁版本；不支持 -V 时函数返回非 0，调用方退回 nvm install。
	printf '%s\n' ${candidates[@]+"${candidates[@]}"} | sort -V | tail -n 1
}

# use_node_bin：把某个 node 的 bin 目录放到 PATH 最前，并记录 NODE_BIN_DIR。
use_node_bin() {
	NODE_BIN_DIR="$(dirname -- "$1")"
	export PATH="$NODE_BIN_DIR:$PATH"
}

# nvm_set_default：设置 default 别名并切换当前 shell（纯本地操作，不联网）。
nvm_set_default() {
	if load_nvm_soft; then
		with_loose_shell nvm alias default "$NODE_MAJOR" >/dev/null 2>&1 || true
		with_loose_shell nvm use --silent "$NODE_MAJOR" >/dev/null 2>&1 || true
	fi
	return 0
}

# nvm_download_node：下载安装 Node。`-b` 禁止二进制下载失败后静默转为源码编译
# （一键安装不该触发几十分钟的源码构建）；网络抖动时按参数重试。
nvm_download_node() {
	local major="$1" attempts="$2" delay="$3" attempt=1
	while :; do
		if with_loose_shell nvm install -b "$major"; then
			return 0
		fi
		if [ "$attempt" -ge "$attempts" ]; then
			return 1
		fi
		warn "nvm install $major 失败（第 $attempt/$attempts 次尝试），${delay}s 后重试 ..."
		sleep "$delay"
		attempt=$((attempt + 1))
	done
}

ensure_node() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] nvm install -b %s && nvm alias default %s && nvm use --silent %s\n' \
			"$NODE_MAJOR" "$NODE_MAJOR" "$NODE_MAJOR"
		NODE_BIN_DIR="/placeholder/node/bin"
		return 0
	fi
	# 下载失败时的重试次数与间隔（秒）；间隔设 0 便于快速重试。
	: "${DSH_SERVICE_NODE_ATTEMPTS:=3}"
	: "${DSH_SERVICE_NODE_RETRY_DELAY:=5}"
	case "$DSH_SERVICE_NODE_ATTEMPTS" in
		''|*[!0-9]*) die "DSH_SERVICE_NODE_ATTEMPTS 必须是正整数，收到 '$DSH_SERVICE_NODE_ATTEMPTS'" ;;
	esac
	case "$DSH_SERVICE_NODE_RETRY_DELAY" in
		''|*[!0-9]*) die "DSH_SERVICE_NODE_RETRY_DELAY 必须是非负整数，收到 '$DSH_SERVICE_NODE_RETRY_DELAY'" ;;
	esac
	if [ "$DSH_SERVICE_NODE_ATTEMPTS" -lt 1 ]; then
		die "DSH_SERVICE_NODE_ATTEMPTS 至少为 1，收到 '$DSH_SERVICE_NODE_ATTEMPTS'"
	fi

	local bin=''
	# 快速路径：本地已有目标主版本时直接复用，不再访问 nodejs.org。
	# `nvm install 22` 即使本机已装好也会联网把 “22” 解析成最新 22.x，网络抖动时
	# 重跑 install.sh 会以 “Version '22' not found” 失败。升级补丁版本用 dshctl upgrade-node。
	if bin="$(nvm_local_node_bin)"; then
		use_node_bin "$bin"
		log "Node 主版本 $NODE_MAJOR 已安装（$NODE_BIN_DIR），跳过下载"
		nvm_set_default
		log "Node $(node --version)（$NODE_BIN_DIR）"
		return 0
	fi

	load_nvm
	log "安装 Node $NODE_MAJOR ..."
	if ! nvm_download_node "$NODE_MAJOR" "$DSH_SERVICE_NODE_ATTEMPTS" "$DSH_SERVICE_NODE_RETRY_DELAY"; then
		err "Node $NODE_MAJOR 下载失败（已尝试 $DSH_SERVICE_NODE_ATTEMPTS 次），通常是访问 Node 下载源的网络问题。"
		err "  1) 直接重跑 install.sh 再试一次（不完整的下载会被清理后重新开始）"
		if [ "$DSH_SERVICE_MIRROR" = 1 ]; then
			err "  2) 当前 Node 源为 $DSH_SERVICE_NODE_MIRROR；可换其它镜像后重跑："
			err "       DSH_SERVICE_NODE_MIRROR=https://<镜像>/node bash install.sh"
		else
			err "  2) 当前为官方源；国内网络可切换国内镜像后重跑："
			err "       bash install.sh --mirror"
		fi
		err "  3) 也可自行安装 Node $NODE_MAJOR（nvm / 发行版包 / NodeSource）后重跑 install.sh，"
		err "     已装好同主版本时脚本会自动跳过下载。"
		exit 1
	fi
	bin="$(command -v node 2>/dev/null || true)"
	if [ -z "$bin" ]; then
		die "Node $NODE_MAJOR 安装后仍找不到 node 命令"
	fi
	case "$NODE_MAJOR" in
		''|*[!0-9]*) ;;
		*)
			if [ "$(node --version 2>/dev/null | sed -e 's/^v//' -e 's/\..*//')" != "$NODE_MAJOR" ]; then
				die "Node $NODE_MAJOR 安装后版本不匹配：$(node --version 2>/dev/null || printf '未知')"
			fi
			;;
	esac
	use_node_bin "$bin"
	nvm_set_default
	log "Node $(node --version)（$NODE_BIN_DIR）"
}

# ── 步骤 3：安装 dsh ─────────────────────────────────────────────────────────
# `dsh --version` 的输出现为裸 semver；这里仍做一次提取，避免上游改变输出格式后
# 「已安装版本 == 目标版本」的判断永远不成立（导致每次重跑都重装）。
normalize_version() {
	local raw="$1" v
	v="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)?' | head -n 1 || true)"
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
	else
		printf '%s\n' "$raw"
	fi
}

# 目标版本可能写成 v0.1.6-alpha.2（npm 接受该前缀），而 dsh --version 输出裸
# semver；直接比较会让「已安装」判断永远不成立、每次重跑都重装。
strip_v_prefix() {
	local v="${1:-}"
	printf '%s\n' "${v#v}"
}

# 把 dist-tag（next/latest/alpha 等）解析为 registry 上指向的具体版本；
# 具体版本号（v0.1.6 / 0.1.6）原样返回、不访问网络；查询失败或没有该 tag 时输出空。
# 与内嵌 dshctl 的同名函数保持一致（两段脚本不能互相 source）。
resolve_dist_tag() {
	local spec="${1:-}" tags value
	case "$spec" in
		v[0-9]*|[0-9]*) strip_v_prefix "$spec"; return 0 ;;
	esac
	tags="$(npm view @deepseek-ai/dsh dist-tags --json 2>/dev/null || true)"
	if [ -z "$tags" ]; then
		# registry 查询失败：无法判断该 tag 是否存在，用退出码 2 让调用方区分。
		return 2
	fi
	# `|| true`：awk 命中后提前退出可能让上游 tr 收到 SIGPIPE，pipefail 下不应因此失败。
	value="$(printf '%s' "$tags" | tr -d '{}"' | tr ',' '\n' | tr ':' ' ' \
		| awk -v k="$spec" '$1 == k { print $2; exit }' || true)"
	printf '%s\n' "$value"
}

ensure_dsh() {
	local current target
	current=''
	if command -v dsh >/dev/null 2>&1; then
		current="$(normalize_version "$(dsh --version 2>/dev/null || true)")"
	fi
	# 默认通道只作用于新安装：未显式指定 --dsh-version（且未 --force）时，已有安装保持
	# 原样，不跟随默认通道升级——与 Node 主版本的保留规则一致，切换通道是用户的显式动作。
	if [ "$FORCE" != 1 ] && [ -z "$OPT_DSH_VERSION" ] && [ -n "$current" ]; then
		log "dsh $current 已安装，保留现有版本（默认通道 $DSH_DEFAULT_CHANNEL；如需切换请用 --dsh-version $DSH_DEFAULT_CHANNEL 或 dshctl upgrade）"
		RESOLVED_DSH_VERSION="$current"
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] npm install -g @deepseek-ai/dsh@%s\n' "$DSH_VERSION"
		RESOLVED_DSH_VERSION="$DSH_VERSION"
		return 0
	fi
	target="$(resolve_dist_tag "$DSH_VERSION" || true)"
	if [ -z "$target" ]; then
		# 具体版本，或 registry 不可达时的字面 dist-tag：直接安装，交给 npm 解析。
		target="$(strip_v_prefix "$DSH_VERSION")"
		case "$DSH_VERSION" in
			v[0-9]*|[0-9]*) ;;
			*) warn "无法解析 @deepseek-ai/dsh 的 $DSH_VERSION 通道（网络不可用？），将直接安装 $DSH_VERSION" ;;
		esac
	fi
	if [ "$FORCE" != 1 ] && [ -n "$current" ] && [ "$current" = "$target" ]; then
		log "dsh $current 已安装，跳过"
		RESOLVED_DSH_VERSION="$current"
		return 0
	fi
	log "安装 @deepseek-ai/dsh@$DSH_VERSION ..."
	if ! npm install -g "@deepseek-ai/dsh@$DSH_VERSION"; then
		die "npm install -g @deepseek-ai/dsh@$DSH_VERSION 失败"
	fi
	current="$(normalize_version "$(dsh --version 2>/dev/null || true)")"
	RESOLVED_DSH_VERSION="${current:-$target}"
	log "dsh 已安装: ${current:-版本未知}"
}

# ── 步骤 4：pnpm ─────────────────────────────────────────────────────────────
# pnpm 与 dsh 一样安装在「当前 Node 版本」的全局 npm 前缀下。它是可选工具：
# 安装失败只告警，不影响 dsh 服务本身（重跑 install.sh 即可重试）。
ensure_pnpm() {
	if [ "$NO_PNPM" = 1 ]; then
		log "已跳过 pnpm（--no-pnpm）"
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] npm install -g pnpm@%s\n' "$PNPM_VERSION"
		RESOLVED_PNPM_VERSION="$PNPM_VERSION"
		return 0
	fi
	local current='' target="$PNPM_VERSION"
	if command -v pnpm >/dev/null 2>&1; then
		current="$(normalize_version "$(pnpm --version 2>/dev/null || true)")"
	fi
	if [ "$target" = latest ]; then
		# 同 dsh：把 latest 解析成具体版本，重跑安装器时才能正确跳过。
		target="$(normalize_version "$(npm view pnpm version 2>/dev/null | tail -n 1 || true)")"
		if [ -z "$target" ]; then
			warn "无法解析 pnpm 的 latest 版本（网络不可用？），将直接安装 latest"
			target=latest
		fi
	fi
	if [ "$FORCE" != 1 ] && [ -n "$current" ] && [ "$current" = "$target" ]; then
		log "pnpm $current 已安装，跳过"
		RESOLVED_PNPM_VERSION="$current"
		PNPM_OK=1
		return 0
	fi
	log "安装 pnpm@$PNPM_VERSION ..."
	if ! npm install -g "pnpm@$PNPM_VERSION"; then
		warn "npm install -g pnpm@$PNPM_VERSION 失败（可稍后重试；不影响 dsh 服务）"
		PNPM_OK=0
		return 0
	fi
	current="$(normalize_version "$(pnpm --version 2>/dev/null || true)")"
	if [ -z "$current" ]; then
		warn "pnpm 安装命令已执行，但仍找不到 pnpm（检查 npm 全局 bin 是否在 PATH 中）"
		PNPM_OK=0
		return 0
	fi
	RESOLVED_PNPM_VERSION="$current"
	PNPM_OK=1
	log "pnpm 已安装: $current"
}

# ── 步骤 5：用户级入口与 dshctl ──────────────────────────────────────────────
install_tools() {
	local gbin
	run mkdir -p -- "$LOCAL_BIN_DIR"
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] ln -sfn "$(npm prefix -g)/bin/dsh" %s\n' "$LOCAL_BIN_DIR/dsh"
	else
		gbin="$(npm prefix -g 2>/dev/null | tail -n 1)/bin/dsh"
		if [ ! -x "$gbin" ]; then
			die "未找到全局 dsh 可执行文件: $gbin"
		fi
		ln -sfn -- "$gbin" "$LOCAL_BIN_DIR/dsh"
		log "稳定入口: $LOCAL_BIN_DIR/dsh -> $gbin"
	fi
	write_file "$DSHCTL_BIN" "$DSHCTL_SRC" 0755
}

# ── 步骤 6：shell 配置 ───────────────────────────────────────────────────────
ensure_shell_rc() {
	if [ "$NO_RC" = 1 ]; then
		log "已跳过 shell 配置（--no-rc）"
		return 0
	fi
	local rc="$HOME/.bashrc" begin='# >>> dsh-service >>>' end='# <<< dsh-service <<<'
	local base='' blocktmp newtmp had_block=no rc_real
	# .bashrc 常见为指向 dotfiles 仓库的符号链接：改写链接目标而不是替换链接本身。
	rc_real="$(readlink -f -- "$rc" 2>/dev/null || true)"
	if [ -n "$rc_real" ]; then
		rc="$rc_real"
	fi
	if [ -f "$rc" ] && grep -qF "$begin" "$rc" 2>/dev/null; then
		had_block=yes
		if ! grep -qF "$end" "$rc" 2>/dev/null; then
			warn "$rc 中缺少结束标记 $end，跳过自动更新（请手动检查）"
			return 0
		fi
		# 先在内存里去旧块，再看块外是否已有 NVM_DIR，避免旧块自身干扰判断。
		base="$(sed -e '/^# >>> dsh-service >>>$/,/^# <<< dsh-service <<<$/d' -- "$rc" || true)"
	elif [ -f "$rc" ]; then
		base="$(cat -- "$rc" || true)"
	fi

	if [ "$DRY_RUN" = 1 ]; then
		if [ "$had_block" = yes ]; then
			printf '[dry-run] 更新 %s 中的 dsh-service 配置\n' "$rc"
		else
			printf '[dry-run] 追加 dsh-service 配置到 %s\n' "$rc"
		fi
		return 0
	fi

	blocktmp="$(mktemp "$(dirname -- "$rc")/.dsh-rc-block.XXXXXX")" \
		|| die "无法在 $(dirname -- "$rc") 创建临时文件（请检查该目录权限）"
	TMP_FILES+=("$blocktmp")
	{
		printf '\n%s\n' "$begin"
		printf '%s\n' '# nvm 与 ~/.local/bin（由 dsh-service install.sh 添加）'
		if ! printf '%s' "$base" | grep -q 'NVM_DIR'; then
			printf 'export NVM_DIR="%s"\n' "$(rc_q "$NVM_DIR")"
			printf '%s\n' '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
			printf '%s\n' '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"'
		fi
		printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' \
			"$(rc_q "$LOCAL_BIN_DIR")" "$(rc_q "$LOCAL_BIN_DIR")"
		printf '%s\n' "$end"
	} > "$blocktmp"

	newtmp="$(mktemp "$(dirname -- "$rc")/.dsh-rc.XXXXXX")" \
		|| die "无法在 $(dirname -- "$rc") 创建临时文件（请检查该目录权限）"
	TMP_FILES+=("$newtmp")
	if [ -n "$base" ]; then
		printf '%s\n' "$base" > "$newtmp"
	fi
	cat "$blocktmp" >> "$newtmp"

	# 值变化（例如 --prefix/--name 改动）时重写块；不变时保持文件逐字节不变（幂等）。
	if [ -f "$rc" ] && cmp -s "$newtmp" "$rc"; then
		log "$rc 已包含 dsh-service 配置"
		return 0
	fi
	if [ -f "$rc" ]; then
		chmod --reference="$rc" "$newtmp" 2>/dev/null || true
	fi
	if ! mv -f -- "$newtmp" "$rc"; then
		die "无法更新 $rc（请检查权限）"
	fi
	log "已更新 $rc"
}

# ── 步骤 7：配置 + 单元 + 服务 ──────────────────────────────────────────────
render_via_dshctl() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] %s _render-config（NAME=%s PORT=%s ...）\n' "$DSHCTL_BIN" "$NAME" "$PORT"
		printf '[dry-run] %s _render-unit\n' "$DSHCTL_BIN"
		return 0
	fi
	if [ ! -x "$DSHCTL_BIN" ]; then
		die "dshctl 未正确安装: $DSHCTL_BIN"
	fi
	DSH_SERVICE_NAME="$NAME" \
	DSH_SERVICE_PORT="$PORT" \
	DSH_SERVICE_DSH_HOME="$DSH_HOME" \
	DSH_SERVICE_NVM_DIR="$NVM_DIR" \
	DSH_SERVICE_NODE_BIN_DIR="$NODE_BIN_DIR" \
	DSH_SERVICE_LOCAL_BIN="$LOCAL_BIN_DIR" \
	DSH_SERVICE_EXTRA_ARGS="$EXTRA_ARGS" \
	DSH_SERVICE_MIRROR="$DSH_SERVICE_MIRROR" \
	DSH_SERVICE_NPM_REGISTRY="$DSH_SERVICE_NPM_REGISTRY" \
	DSH_SERVICE_NODE_MIRROR="$DSH_SERVICE_NODE_MIRROR" \
		"$DSHCTL_BIN" _render-config
	DSH_SERVICE_NAME="$NAME" \
	DSH_SERVICE_PORT="$PORT" \
	DSH_SERVICE_DSH_HOME="$DSH_HOME" \
	DSH_SERVICE_NVM_DIR="$NVM_DIR" \
	DSH_SERVICE_NODE_BIN_DIR="$NODE_BIN_DIR" \
	DSH_SERVICE_LOCAL_BIN="$LOCAL_BIN_DIR" \
	DSH_SERVICE_EXTRA_ARGS="$EXTRA_ARGS" \
	DSH_SERVICE_MIRROR="$DSH_SERVICE_MIRROR" \
	DSH_SERVICE_NPM_REGISTRY="$DSH_SERVICE_NPM_REGISTRY" \
	DSH_SERVICE_NODE_MIRROR="$DSH_SERVICE_NODE_MIRROR" \
		"$DSHCTL_BIN" _render-unit
}

# 用户级 systemd 是否可用（供旧单元清理使用）。
user_systemd_ok() {
	if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
		export XDG_RUNTIME_DIR="/run/user/$(id -u)"
	fi
	systemctl --user show-environment >/dev/null 2>&1
}

# --name 变更后，旧单元仍处于 enabled/运行状态，并会与新单元争抢同一端口。
# 新单元渲染成功后再清理旧单元（渲染失败会 die，旧单元保持原状）。
retire_previous_unit() {
	local prev="${1:-}" prev_unit
	[ -n "$prev" ] || return 0
	[ "$prev" = "$NAME" ] && return 0
	# 旧名字来自配置文件（可能被手工改过）：只接受与其他单元名相同的字符集，
	# 避免 ../ 之类的值把删除操作引到 systemd/user 目录之外。
	case "$prev" in
		*[!A-Za-z0-9_.@-]*) return 0 ;;
	esac
	prev_unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${prev}.service"
	[ -f "$prev_unit" ] || return 0
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] 停用并删除旧单元 %s（--name %s -> %s）\n' "$prev_unit" "$prev" "$NAME"
		return 0
	fi
	warn "检测到旧单元 $prev_unit（--name 已从 $prev 改为 $NAME），正在停用并清理"
	if user_systemd_ok; then
		systemctl --user disable --now "${prev}.service" 2>/dev/null \
			|| systemctl --user stop "${prev}.service" 2>/dev/null \
			|| true
		systemctl --user daemon-reload 2>/dev/null || true
	fi
	rm -f -- "$prev_unit" "$prev_unit.bak"
	log "已移除旧单元: $prev_unit"
}

SERVICE_OK=1
# pnpm 是可选项：安装失败只告警并在汇总中标注，不影响服务启用。
PNPM_OK=1

apply_service() {
	if [ "$NO_SERVICE" = 1 ]; then
		log "已跳过服务启用（--no-service）；稍后可执行: dshctl enable"
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] %s _enable\n' "$DSHCTL_BIN"
		printf '[dry-run] %s _linger\n' "$DSHCTL_BIN"
		return 0
	fi
	if ! "$DSHCTL_BIN" _enable; then
		SERVICE_OK=0
		return 0
	fi
	if [ "$NO_LINGER" = 1 ]; then
		log "已跳过 linger 设置（--no-linger）"
	else
		"$DSHCTL_BIN" _linger || true
	fi
}

# ── 执行 ─────────────────────────────────────────────────────────────────────
# 先注入镜像设置（npm registry / nvm Node 源），后续所有 npm / nvm 调用都会继承。
apply_mirrors

# 安装前先做端口预检：被占用时自动改用后续空闲端口（--strict-port 则直接报错）。
resolve_port
log "单元=$UNIT_NAME 端口=$PORT 前缀=$LOCAL_BIN_DIR"

ensure_nvm
ensure_node
ensure_dsh
ensure_pnpm
install_tools
ensure_shell_rc

if [ "$DRY_RUN" = 1 ]; then
	NODE_BIN_DIR="/placeholder/node/bin"
fi
render_via_dshctl
retire_previous_unit "$PREV_NAME"
apply_service

# ── 汇总 ─────────────────────────────────────────────────────────────────────
printf '\n'
log "安装完成"
printf '  版本     : dsh %s / node %s\n' "$RESOLVED_DSH_VERSION" "$([ "$DRY_RUN" = 1 ] && printf '（dry-run）' || node --version 2>/dev/null || printf '未知')"
if [ "$NO_PNPM" = 1 ]; then
	printf '  pnpm     : 已跳过（--no-pnpm）\n'
elif [ "$PNPM_OK" = 1 ]; then
	printf '  pnpm     : %s\n' "$RESOLVED_PNPM_VERSION"
else
	printf '  pnpm     : 未安装（见上方 WARN，可重跑 install.sh）\n'
fi
if [ "$DSH_SERVICE_MIRROR" = 1 ]; then
	printf '  镜像     : 国内（npm %s）\n' "$DSH_SERVICE_NPM_REGISTRY"
else
	printf '  镜像     : 官方源（--no-mirror）\n'
fi
printf '  地址     : http://%s:%s\n' "$DSH_SERVICE_HOST" "$PORT"
printf '  单元     : %s\n' "$UNIT_FILE"
printf '  配置     : %s\n' "$CONFIG_FILE"
printf '  dshctl   : %s\n' "$DSHCTL_BIN"

if [ "$DRY_RUN" = 0 ] && [ "$NO_SERVICE" != 1 ] && [ "$SERVICE_OK" = 1 ]; then
	login_url="$("$DSHCTL_BIN" url --wait 30 2>/dev/null || true)"
	if [ -n "$login_url" ]; then
		printf '\n  登录链接 : %s\n' "$login_url"
	else
		printf '\n  登录链接 : 暂未取到，稍后执行 dshctl url\n'
	fi
fi

cat <<'EOF'

下一步
  * 模型密钥在 Web 界面的设置页配置（本脚本不处理 DEEPSEEK_API_KEY）。
  * 常用命令：
      dshctl status          查看状态
      dshctl url             打印登录链接
      dshctl logs -f         跟踪日志
      dshctl restart         改配置后重启
      dshctl upgrade         升级 dsh
      dshctl doctor          环境自检
      dshctl export          导出配置与会话（迁移到新环境用）
  * 远程访问（服务仅监听 127.0.0.1）：
      ssh -N -L 3080:127.0.0.1:3080 <主机>
      然后在本机浏览器打开 dshctl url 输出的链接。
EOF

if [ "$SERVICE_OK" != 1 ]; then
	printf '\n'
	err "服务未成功启用；请按上方提示处理后执行: dshctl enable"
	exit 1
fi

if [ "$DRY_RUN" = 0 ] && [ "$NO_SERVICE" != 1 ]; then
	case ":$PATH:" in
		*":$LOCAL_BIN_DIR:"*) ;;
		*) warn "$LOCAL_BIN_DIR 尚未在当前 shell 的 PATH 中：重新登录或执行 export PATH=\"$LOCAL_BIN_DIR:\$PATH\"" ;;
	esac
fi

exit 0
