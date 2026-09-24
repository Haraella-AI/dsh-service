#!/usr/bin/env bash
# =============================================================================
#  tests/run.sh —— dsh-service 离线测试
#
#  不需要网络、systemd 或 root：用桩命令（systemctl/npm/node/...）在临时 HOME
#  中完整走一遍安装、幂等、dshctl url、升级回滚、doctor 等路径。
#
#  用法: bash tests/run.sh
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.tmp/tests"
rm -rf -- "$WORK"
mkdir -p -- "$WORK/bin" "$WORK/node/lib/node_modules/@deepseek-ai/dsh/lib"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }
assert_eq() {
	if [ "$1" = "$2" ]; then
		ok "$3"
	else
		bad "$3（期望 [$2] 实际 [$1]）"
	fi
}
assert_contains() {
	if printf '%s' "$2" | grep -qF -- "$1"; then
		ok "$3"
	else
		bad "$3（未包含 [$1]）"
		printf '%s\n' "$2" | sed 's/^/      | /'
	fi
}
assert_not_contains() {
	if printf '%s' "$2" | grep -qF -- "$1"; then
		bad "$3（不应包含 [$1]）"
	else
		ok "$3"
	fi
}
assert_file() {
	if [ -f "$1" ]; then ok "$2"; else bad "$2（缺少 $1）"; fi
}
assert_symlink_to() {
	if [ -L "$1" ] && [ "$(readlink -- "$1")" = "$2" ]; then
		ok "$3"
	else
		bad "$3（$1 -> ${1:+$(readlink -- "$1" 2>/dev/null || printf '缺失')}，期望 $2）"
	fi
}
count_of() {
	printf '%s' "$2" | grep -cF -- "$1" || true
}
# nvm 桩的调用记录（安装次数用于断言重试行为）
reset_nvm_log() {
	: > "$STUB_NVM_LOG"
	: > "$STUB_NVM_LOG.count"
}

# ── 桩命令 ───────────────────────────────────────────────────────────────────
export STUB_SYSTEM_BIN="$WORK/bin"
export STUB_NODE_PREFIX="$WORK/node"
export STUB_NPM_LOG="$WORK/npm.log"
export STUB_NPM_ENV_LOG="$WORK/npm-env.log"
export STUB_SYSTEMCTL_LOG="$WORK/systemctl.log"
export STUB_SUDO_LOG="$WORK/sudo.log"
export STUB_NVM_LOG="$WORK/nvm.log"
export STUB_DSH_LOG="$WORK/dsh.log"
export PATH="$WORK/bin:$WORK/node/bin:$PATH"

: > "$STUB_NPM_LOG"
: > "$STUB_NPM_ENV_LOG"
: > "$STUB_SYSTEMCTL_LOG"
: > "$STUB_SUDO_LOG"
: > "$STUB_NVM_LOG"
: > "$STUB_NVM_LOG.count"
: > "$STUB_DSH_LOG"
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"

# 全局 dsh：bin/dsh -> lib/node_modules/@deepseek-ai/dsh/lib/bin.js
cat > "$WORK/node/lib/node_modules/@deepseek-ai/dsh/package.json" <<'EOF'
{ "name": "@deepseek-ai/dsh", "version": "0.1.0" }
EOF
mkdir -p "$WORK/node/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist"
printf '<html></html>\n' > "$WORK/node/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/index.html"
cat > "$WORK/node/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${STUB_DSH_LOG:-/dev/null}"
if [ "\${1:-}" = "--version" ]; then cat "$WORK/node/VERSION"; exit 0; fi
exit 0
EOF
chmod +x "$WORK/node/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
mkdir -p "$WORK/node/bin"
ln -sfn "$WORK/node/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" "$WORK/node/bin/dsh"

cat > "$WORK/node/bin/node" <<'EOF'
#!/usr/bin/env bash
# 与真实 nvm 一样：安装/切换后 node 的版本随之变化。当前生效版本记录在
# $HOME/.stub-node-version（由 nvm 桩在 install 成功时写入），缺省回退到 v22.99.0。
if [ "${1:-}" = "--version" ]; then
	if [ -n "${HOME:-}" ] && [ -r "$HOME/.stub-node-version" ]; then
		cat "$HOME/.stub-node-version"
	else
		printf 'v22.99.0\n'
	fi
fi
exit 0
EOF

cat > "$WORK/node/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -u
# 记录生效的 registry，用于断言镜像设置确实传给了 npm。
printf 'registry %s\n' "${npm_config_registry-}" >> "${STUB_NPM_ENV_LOG:-/dev/null}"
# dist-tag → 版本的桩数据：view dist-tags 与 install <pkg>@<tag> 共用同一份。
if [ -z "${STUB_NPM_DIST_TAGS:-}" ]; then
	STUB_NPM_DIST_TAGS='{"latest":"0.2.0","next":"1.0.0-rc.1"}'
fi
# tag_version <tag>：从 JSON 桩数据里取出该 tag 指向的版本（没有则输出空）。
tag_version() {
	printf '%s' "$STUB_NPM_DIST_TAGS" | tr -d '{}"' | tr ',' '\n' | tr ':' ' ' \
		| awk -v k="$1" '$1 == k { print $2; exit }'
}
case "${1:-}" in
	prefix)
		printf '%s\n' "$STUB_NODE_PREFIX"
		exit 0
		;;
	view)
		# npm view <包[@spec]> <字段>：按字段返回，便于测试 upgrade --list 与装前校验。
		pkg="${2:-}"
		field="${3:-}"
		if [ "${STUB_NPM_VIEW_FAIL:-0}" = 1 ]; then
			printf 'npm error code EAI_AGAIN\nnpm error network request failed\n' >&2
			exit 1
		fi
		if [ -n "${STUB_NPM_NOTARGET_MATCH:-}" ]; then
			case "$pkg" in
				*"$STUB_NPM_NOTARGET_MATCH"*)
					printf 'npm error code ETARGET\n' >&2
					printf 'npm error notarget No matching version found for %s.\n' "$pkg" >&2
					exit 1
					;;
			esac
		fi
		case "$field" in
			versions)
				printf '%s\n' "${STUB_NPM_VERSIONS:-[\"0.1.0\",\"0.1.1\",\"0.2.0\",\"1.0.0-rc.1\"]}"
				exit 0
				;;
			dist-tags)
				printf '%s\n' "$STUB_NPM_DIST_TAGS"
				exit 0
				;;
		esac
		printf '%s\n' "${STUB_NPM_VIEW_VERSION:-1.0.0}"
		exit 0
		;;
	install)
		spec=""
		shift
		for a in "$@"; do
			case "$a" in
				-*) ;;
				*)
					spec="$a"
					break
					;;
			esac
		done
		printf 'install %s\n' "$spec" >> "$STUB_NPM_LOG"
		if [ -n "${STUB_NPM_NOTARGET_INSTALL_MATCH:-}" ]; then
			case "$spec" in
				*"$STUB_NPM_NOTARGET_INSTALL_MATCH"*)
					printf 'npm error code ETARGET\n' >&2
					printf 'npm error notarget No matching version found for %s.\n' "$spec" >&2
					exit 1
					;;
			esac
		fi
		if [ -n "${STUB_NPM_NOOP_MATCH:-}" ]; then
			case "$spec" in
				*"$STUB_NPM_NOOP_MATCH"*) exit 0 ;;
			esac
		fi
		if [ -n "${STUB_NPM_FAIL_MATCH:-}" ]; then
			case "$spec" in
				*"$STUB_NPM_FAIL_MATCH"*) exit 1 ;;
			esac
		fi
		case "$spec" in
			pnpm|pnpm@*)
				# pnpm 桩：版本写入独立文件并生成可执行文件，避免覆盖 dsh 的 VERSION。
				ver="${spec#pnpm}"
				ver="${ver#@}"
				if [ -z "$ver" ] || [ "$ver" = latest ]; then
					ver="${STUB_NPM_VIEW_VERSION:-1.0.0}"
				fi
				printf '%s\n' "$ver" > "$STUB_NODE_PREFIX/pnpm-version"
				mkdir -p "$STUB_NODE_PREFIX/bin"
				cat > "$STUB_NODE_PREFIX/bin/pnpm" <<'PNPM_STUB_EOF'
#!/usr/bin/env bash
cat "$STUB_NODE_PREFIX/pnpm-version"
PNPM_STUB_EOF
				chmod +x "$STUB_NODE_PREFIX/bin/pnpm"
				exit 0
				;;
		esac
		ver="${spec##*@}"
		case "$ver" in
			v[0-9]*|[0-9]*) ver="${ver#v}" ;;
			*)
				# dist-tag（next / latest / ...）：按桩的 dist-tags 映射为具体版本，
				# 与真实 npm 安装 dist-tag 后写出的 package 版本一致。
				tag_ver="$(tag_version "$ver")"
				ver="${tag_ver:-${STUB_NPM_VIEW_VERSION:-1.0.0}}"
				;;
		esac
		printf '%s\n' "$ver" > "$STUB_NODE_PREFIX/VERSION"
		exit 0
		;;
	--version)
		printf '10.0.0\n'
		exit 0
		;;
	*)
		exit 0
		;;
esac
EOF

cat > "$WORK/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_SYSTEMCTL_LOG"
if [ "${1:-}" = "--user" ]; then shift; fi
case "${1:-}" in
	show-environment) exit 0 ;;
	is-active) printf '%s\n' "${STUB_IS_ACTIVE:-active}"; exit 0 ;;
	is-enabled) exit 0 ;;
	status) printf '○ stub unit (inactive)\n'; exit 0 ;;
	*) exit 0 ;;
esac
EOF

cat > "$WORK/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
# AlmaLinux/RHEL 场景：普通用户读不了持久化 journal（--user 失败）；
# 带 -t <ident> 的 sudo 回退路径应仍可用。
if [ "${STUB_JOURNAL_DENY:-0}" = 1 ]; then
	case " $* " in
		*" --user "*)
			printf '%s\n' 'No journal files were opened due to insufficient permissions.' >&2
			exit 1
			;;
	esac
fi
printf '%s\n' 'dsh web: http://127.0.0.1:3080/?token=TESTTOKEN123 (LAN: http://10.0.0.5:3080/?token=TESTTOKEN123)'
EOF

cat > "$WORK/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = show-user ]; then
	printf 'Linger=%s\n' "${STUB_LINGER:-no}"
	exit 0
fi
exit 0
EOF

# sudo 桩：记录调用后直接执行参数（忽略 -n 等选项），避免测试触碰真实 sudo/loginctl。
cat > "$WORK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_SUDO_LOG:-/dev/null}"
args=()
for a in "$@"; do
	case "$a" in
		-n|--non-interactive) ;;
		*) args+=("$a") ;;
	esac
done
exec "${args[@]}"
EOF

cat > "$WORK/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port'
# 默认没有任何监听者；需要时用 STUB_SS_OUTPUT 指定（可多行）。
if [ -n "${STUB_SS_OUTPUT:-}" ]; then
	printf '%s\n' "$STUB_SS_OUTPUT"
fi
EOF

chmod +x "$WORK/node/bin/node" "$WORK/node/bin/npm" \
	"$WORK/bin/systemctl" "$WORK/bin/journalctl" "$WORK/bin/loginctl" \
	"$WORK/bin/sudo" "$WORK/bin/ss"

# 生成一个临时 HOME（含 nvm 桩）
make_home() {
	local home="$1"
	mkdir -p -- "$home/.nvm" "$home/.config" "$home/.local/bin"
	printf '%s\n' '# fixture bashrc' > "$home/.bashrc"
	cat > "$home/.nvm/nvm.sh" <<EOF
export NVM_DIR="\$HOME/.nvm"
nvm() {
	local cmd="\${1:-}"
	shift || true
	case "\$cmd" in
		install)
			# 记录调用参数与次数（STUB_NVM_FAIL_UNTIL 按次数模拟「先失败后成功」）
			printf 'install %s\n' "\$*" >> "$STUB_NVM_LOG"
			printf 'node-mirror %s\n' "\${NVM_NODEJS_ORG_MIRROR-}" >> "$STUB_NVM_LOG"
			local n
			n="\$(cat "$STUB_NVM_LOG.count" 2>/dev/null || printf 0)"
			n=\$((n + 1))
			printf '%s\n' "\$n" > "$STUB_NVM_LOG.count"
			if [ -n "\${PREFIX-}" ]; then
				printf 'nvm is not compatible with the "PREFIX" environment variable: currently set to "%s"\n' "\$PREFIX" >&2
				printf '%s\n' 'Run `unset PREFIX` to unset it.' >&2
				return 3
			fi
			# 真实 nvm.sh 在下载失败路径上会引用未定义的变量（如 TMPDIR）；在 \`set -u\`
			# 下这会让整个脚本以 "unbound variable" 退出，从而掩盖真正的错误。
			if [ "\${STUB_NVM_TRIP_SET_U:-0}" = 1 ]; then
				printf 'trip: %s\n' "\${STUB_NVM_DELIBERATELY_UNSET}"
			fi
			if [ "\${STUB_NVM_ALWAYS_FAIL:-0}" = 1 ] \
				|| { [ -n "\${STUB_NVM_FAIL_UNTIL:-}" ] && [ "\$n" -le "\${STUB_NVM_FAIL_UNTIL}" ]; }; then
				printf 'download from https://nodejs.org/dist/v22.99.0/node-v22.99.0-linux-x64.tar.xz failed\n' >&2
				return 1
			fi
			local ver="22"
			for a in "\$@"; do
				case "\$a" in -*) ;; *) ver="\$a"; break ;; esac
			done
			PATH="$WORK/node/bin:\$PATH"
			export PATH
			printf 'v%s.99.0\n' "\$ver" > "\$HOME/.stub-node-version"
			printf 'Now using node v%s.99.0 (npm v10.0.0)\n' "\$ver"
			;;
		*) return 0 ;;
	esac
}
EOF
}

# ── 1. 语法与帮助 ────────────────────────────────────────────────────────────
section '1. 语法与帮助'
if bash -n "$ROOT/install.sh"; then ok 'install.sh 语法检查'; else bad 'install.sh 语法检查'; fi
bash "$ROOT/install.sh" --print-dshctl > "$WORK/dshctl.embedded" 2>/dev/null
if bash -n "$WORK/dshctl.embedded"; then ok 'dshctl（内嵌副本）语法检查'; else bad 'dshctl 语法检查'; fi
assert_contains 'dshctl' "$(head -3 "$WORK/dshctl.embedded")" '--print-dshctl 输出内容正确'

if bash "$ROOT/install.sh" --help >/dev/null 2>&1; then ok 'install.sh --help 退出 0'; else bad 'install.sh --help 退出 0'; fi
assert_not_contains '--with-build-tools' "$(bash "$ROOT/install.sh" --help 2>&1)" '帮助不再列出 --with-build-tools'
assert_contains '--no-mirror' "$(bash "$ROOT/install.sh" --help 2>&1)" '帮助列出 --no-mirror'
if bash "$ROOT/install.sh" --bogus >/dev/null 2>&1; then bad '未知参数应失败'; else ok '未知参数退出非 0'; fi
# 已移除的编译工具链选项：作为未知参数立即失败，且不进入任何安装步骤。
if bash "$ROOT/install.sh" --with-build-tools >/dev/null 2>&1; then bad '已移除的 --with-build-tools 应失败'; else ok '已移除的 --with-build-tools 退出非 0'; fi
assert_contains '未知参数' "$(bash "$ROOT/install.sh" --with-build-tools 2>&1 || true)" '已移除的 --with-build-tools 报未知参数'

# ── 2. dry-run 不产生任何文件 ────────────────────────────────────────────────
section '2. dry-run 纯净性'
# 模拟「机器上没有安装 dsh」：只暴露 node/npm，不暴露 dsh。
NODSH_BIN="$WORK/no-dsh-bin"
rm -rf "$NODSH_BIN"; mkdir -p "$NODSH_BIN"
ln -sfn "$WORK/node/bin/node" "$NODSH_BIN/node"
ln -sfn "$WORK/node/bin/npm" "$NODSH_BIN/npm"
DRY_HOME="$WORK/dry-home"
make_home "$DRY_HOME"
BEFORE_LIST="$(find "$DRY_HOME" -mindepth 1 -printf '%p\n' | sort)"
DRY_OUT="$(HOME="$DRY_HOME" bash "$ROOT/install.sh" --dry-run 2>&1)"
DRY_RC=$?
assert_eq "$DRY_RC" '0' 'dry-run 退出 0'
AFTER_LIST="$(find "$DRY_HOME" -mindepth 1 -printf '%p\n' | sort)"
NEW_FILES="$(comm -13 <(printf '%s\n' "$BEFORE_LIST") <(printf '%s\n' "$AFTER_LIST"))"
assert_eq "$NEW_FILES" '' 'dry-run 未创建新文件'
# PATH 上已有 dsh（桩 0.1.0）且未显式指定版本：dry-run 报告保留，而不是安装。
assert_contains 'dsh 0.1.0 已安装，保留现有版本' "$DRY_OUT" 'dry-run 报告保留已有安装'
assert_not_contains '[dry-run] npm install -g @deepseek-ai/dsh@' "$DRY_OUT" '已有安装的 dry-run 不打印 dsh 安装动作'
# 机器上没有 dsh：默认安装通道为 next。
DRY_FRESH_OUT="$(HOME="$DRY_HOME" PATH="$WORK/bin:$NODSH_BIN:/usr/bin:/bin" \
	bash "$ROOT/install.sh" --dry-run 2>&1)"
assert_contains '[dry-run] npm install -g @deepseek-ai/dsh@next' "$DRY_FRESH_OUT" '未安装 dsh 时 dry-run 安装默认通道 next'
assert_contains '[dry-run] npm install -g pnpm@latest' "$DRY_FRESH_OUT" 'dry-run 打印 pnpm 安装动作'
assert_not_contains "$DRY_HOME/.dsh" "$AFTER_LIST" 'dry-run 未创建 DSH_HOME'
assert_not_contains '编译工具' "$DRY_OUT" 'dry-run 不包含编译工具链步骤'
# 全新安装（无 --node-major、无已记录 Node）默认请求 Node 24。
assert_contains '[dry-run] nvm install -b 24' "$DRY_OUT" '全新安装默认请求 Node 24'

# ── 3. 完整安装（桩 systemd） ────────────────────────────────────────────────
section '3. 完整安装'
HOME3="$WORK/home3"
make_home "$HOME3"
: > "$STUB_SYSTEMCTL_LOG"
: > "$STUB_SUDO_LOG"
INSTALL_RC=0
INSTALL_OUT="$(HOME="$HOME3" bash "$ROOT/install.sh" --dsh-version 0.1.0 2>&1)" || INSTALL_RC=$?
assert_eq "$INSTALL_RC" '0' 'install.sh 退出 0'
assert_contains '服务已启用并启动: dsh.service' "$INSTALL_OUT" '服务已启用'
assert_contains 'http://127.0.0.1:3080/?token=TESTTOKEN123' "$INSTALL_OUT" '安装末尾打印登录链接'
assert_contains '已启用 linger（sudo）' "$INSTALL_OUT" 'linger 优先走免密 sudo（避免 polkit 噪音）'
assert_contains 'loginctl enable-linger' "$(cat "$STUB_SUDO_LOG")" 'linger 经由 sudo 执行'
assert_contains '版本     : dsh 0.1.0' "$INSTALL_OUT" '汇总显示实际安装的 dsh 版本'
assert_contains 'Node v24.99.0' "$INSTALL_OUT" '全新安装按默认主版本安装 Node 24'
assert_contains 'pnpm 已安装: 1.0.0' "$INSTALL_OUT" '安装 pnpm'
assert_contains '  pnpm     : 1.0.0' "$INSTALL_OUT" '汇总显示 pnpm 版本'
assert_contains 'install pnpm@latest' "$(cat "$STUB_NPM_LOG")" '通过 npm 全局安装 pnpm'
assert_eq "$("$WORK/node/bin/pnpm" --version 2>/dev/null || true)" '1.0.0' 'pnpm 命令可用'

assert_file "$HOME3/.local/bin/dshctl" 'dshctl 已安装'
if [ -x "$HOME3/.local/bin/dshctl" ]; then ok 'dshctl 可执行'; else bad 'dshctl 可执行'; fi
assert_symlink_to "$HOME3/.local/bin/dsh" "$WORK/node/bin/dsh" 'dsh 稳定入口指向全局 dsh'
assert_file "$HOME3/.config/dsh-service/config" '配置文件已生成'
assert_file "$HOME3/.config/systemd/user/dsh.service" 'systemd 单元已生成'
if [ -e "$HOME3/dsh-workspace" ]; then bad '不应自动创建工作目录'; else ok '未自动创建工作目录'; fi

UNIT="$(cat "$HOME3/.config/systemd/user/dsh.service")"
assert_contains 'Type=exec' "$UNIT" '单元 Type=exec'
assert_contains "Environment=\"PATH=$HOME3/.local/bin:$WORK/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" "$UNIT" '单元 PATH 含 ~/.local/bin 与 node bin'
assert_contains "Environment=\"DSH_HOME=$HOME3/.dsh\"" "$UNIT" '单元设置 DSH_HOME'
assert_not_contains 'WorkingDirectory=' "$UNIT" '单元不含 WorkingDirectory'
assert_contains "ExecStart=$HOME3/.local/bin/dsh web --host 127.0.0.1 --port 3080 --no-open" "$UNIT" '单元 ExecStart 只监听回环'
assert_contains 'Restart=on-failure' "$UNIT" '单元自动重启策略'
assert_contains 'WantedBy=default.target' "$UNIT" '单元开机目标'

SYSTEMCTL_LOG="$(cat "$STUB_SYSTEMCTL_LOG")"
assert_contains '--user daemon-reload' "$SYSTEMCTL_LOG" '执行 daemon-reload'
assert_contains '--user enable --now dsh.service' "$SYSTEMCTL_LOG" '启用并启动服务'

BASHRC="$(cat "$HOME3/.bashrc")"
assert_contains '# >>> dsh-service >>>' "$BASHRC" 'shell 配置块已写入'
assert_contains "export PATH=\"$HOME3/.local/bin:\$PATH\"" "$BASHRC" 'shell PATH 含 ~/.local/bin'

CONFIG_SOURCED="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" config)"
assert_contains "DSH_SERVICE_PORT          = 3080" "$CONFIG_SOURCED" '配置文件端口正确'
assert_contains "DSH_SERVICE_NODE_BIN_DIR  = $WORK/node/bin" "$CONFIG_SOURCED" '配置文件 node bin 正确'

# ── 3b. 端口预检与自动换端口 ─────────────────────────────────────────────────
section '3b. 端口预检'
export STUB_SS_OUTPUT='LISTEN 0      511        127.0.0.1:3080      0.0.0.0:*'

SWITCH_HOME="$WORK/home-switch"
make_home "$SWITCH_HOME"
SWITCH_RC=0
SWITCH_OUT="$(HOME="$SWITCH_HOME" bash "$ROOT/install.sh" --dsh-version 0.1.0 --port 3080 2>&1)" || SWITCH_RC=$?
assert_eq "$SWITCH_RC" '0' '端口被占用时安装仍成功'
assert_contains '自动改用端口 3081' "$SWITCH_OUT" '自动选择空闲端口 3081'
assert_contains '--port 3081 --no-open' "$(cat "$SWITCH_HOME/.config/systemd/user/dsh.service")" '切换后的端口写入单元'
assert_contains 'DSH_SERVICE_PORT:=3081' "$(cat "$SWITCH_HOME/.config/dsh-service/config")" '切换后的端口写入配置'
assert_contains '地址     : http://127.0.0.1:3081' "$SWITCH_OUT" '汇总显示切换后的地址'

STRICT_HOME="$WORK/home-strict"
make_home "$STRICT_HOME"
if HOME="$STRICT_HOME" bash "$ROOT/install.sh" --dsh-version 0.1.0 --port 3080 --strict-port >/dev/null 2>&1; then
	bad '--strict-port 端口被占用时应失败'
else
	ok '--strict-port 端口被占用时退出非 0'
fi
if [ -f "$STRICT_HOME/.config/systemd/user/dsh.service" ]; then
	bad '--strict-port 失败时不应写出单元'
else
	ok '--strict-port 失败时未写出单元'
fi

# 端口属于本服务（单元存在且 active）时不应切换，保证重跑幂等
OWN_OUT="$(HOME="$HOME3" bash "$ROOT/install.sh" --dsh-version 0.1.0 2>&1)"
assert_contains '正由本服务' "$OWN_OUT" '识别出端口属于本服务'
assert_contains '--port 3080 --no-open' "$(cat "$HOME3/.config/systemd/user/dsh.service")" '本服务端口保持不变'
unset STUB_SS_OUTPUT

# ── 3c. pnpm 安装开关与容错 ──────────────────────────────────────────────────
section '3c. pnpm 安装开关与容错'

# 幂等：pnpm 已是 1.0.0，重跑不应再次执行 npm install pnpm
: > "$STUB_NPM_LOG"
HOME="$HOME3" bash "$ROOT/install.sh" --dsh-version 0.1.0 >/dev/null 2>&1
assert_eq "$(count_of 'install pnpm' "$(cat "$STUB_NPM_LOG")")" '0' 'pnpm 已是最新时跳过安装'

# --no-pnpm：完全不安装 pnpm
NOPNPM_HOME="$WORK/home-nopnpm"
make_home "$NOPNPM_HOME"
NOPNPM_OUT="$(HOME="$NOPNPM_HOME" bash "$ROOT/install.sh" --no-service --no-pnpm --dsh-version 0.1.0 2>&1)"
assert_contains '已跳过 pnpm（--no-pnpm）' "$NOPNPM_OUT" '--no-pnpm 跳过 pnpm'
assert_contains '  pnpm     : 已跳过（--no-pnpm）' "$NOPNPM_OUT" '汇总标注 pnpm 已跳过'

# pnpm 安装失败只告警：这是可选工具，不应阻断 dsh 安装
# （已有 pnpm 1.0.0，用 --pnpm-version 9.9.9 强制触发一次安装并让它失败）
FAILPNPM_HOME="$WORK/home-failpnpm"
make_home "$FAILPNPM_HOME"
export STUB_NPM_FAIL_MATCH='pnpm@9.9.9'
FAILPNPM_RC=0
FAILPNPM_OUT="$(HOME="$FAILPNPM_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --pnpm-version 9.9.9 2>&1)" || FAILPNPM_RC=$?
unset STUB_NPM_FAIL_MATCH
assert_eq "$FAILPNPM_RC" '0' 'pnpm 安装失败时安装器仍成功'
assert_contains 'npm install -g pnpm@9.9.9 失败' "$FAILPNPM_OUT" 'pnpm 安装失败给出告警'
assert_contains '  pnpm     : 未安装' "$FAILPNPM_OUT" '汇总标注 pnpm 未安装'

# ── 4. 幂等 ──────────────────────────────────────────────────────────────────
section '4. 重复执行幂等'
UNIT_HASH_BEFORE="$(sha256sum "$HOME3/.config/systemd/user/dsh.service" | awk '{print $1}')"
RC_HASH_BEFORE="$(sha256sum "$HOME3/.bashrc" | awk '{print $1}')"
CTL_HASH_BEFORE="$(sha256sum "$HOME3/.local/bin/dshctl" | awk '{print $1}')"
INSTALL_OUT2="$(HOME="$HOME3" bash "$ROOT/install.sh" --dsh-version 0.1.0 2>&1)"
assert_eq "$(sha256sum "$HOME3/.config/systemd/user/dsh.service" | awk '{print $1}')" "$UNIT_HASH_BEFORE" '单元文件未变'
assert_eq "$(sha256sum "$HOME3/.bashrc" | awk '{print $1}')" "$RC_HASH_BEFORE" 'bashrc 未变'
assert_eq "$(sha256sum "$HOME3/.local/bin/dshctl" | awk '{print $1}')" "$CTL_HASH_BEFORE" 'dshctl 未变'
assert_eq "$(count_of '# >>> dsh-service >>>' "$(cat "$HOME3/.bashrc")")" '1' 'shell 配置块只有一份'
assert_contains '已包含 dsh-service 配置' "$INSTALL_OUT2" '重跑时识别已有配置'

# ── 5. dshctl url / version ─────────────────────────────────────────────────
section '5. dshctl url'
URL="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" url)"
assert_eq "$URL" 'http://127.0.0.1:3080/?token=TESTTOKEN123' 'url 取根因链接而非 LAN'
assert_eq "$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" url --plain)" 'http://127.0.0.1:3080/' 'url --plain 去掉 token'
assert_contains "dshctl : 0.1.0" "$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" version)" 'version 输出'
if HOME="$HOME3" "$HOME3/.local/bin/dshctl" nope >/dev/null 2>&1; then bad '未知命令应退出 2'; else ok '未知命令退出非 0'; fi

section '5b. journal 权限受限时回退到 sudo'
export STUB_JOURNAL_DENY=1
LOGS_FALLBACK="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" logs -n 5 2>&1 || true)"
assert_contains 'token=TESTTOKEN123' "$LOGS_FALLBACK" 'journal 不可读时 logs 回退到 sudo -t 成功'
URL_FALLBACK="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" url 2>&1 || true)"
assert_eq "$URL_FALLBACK" 'http://127.0.0.1:3080/?token=TESTTOKEN123' 'journal 不可读时 url 仍能取得链接'
DOCTOR_JOURNAL="$(PATH="$HOME3/.local/bin:$WORK/node/bin:$PATH" HOME="$HOME3" \
	"$HOME3/.local/bin/dshctl" doctor 2>&1 || true)"
assert_not_contains '无法读取服务日志' "$DOCTOR_JOURNAL" 'doctor 在回退可用时不报日志失败'
unset STUB_JOURNAL_DENY

# ── 6. upgrade 回滚 ──────────────────────────────────────────────────────────
section '6. upgrade 版本校验失败回滚'
: > "$STUB_NPM_LOG"
export STUB_NPM_NOOP_MATCH='0.2.0'
export STUB_NPM_VIEW_VERSION='0.2.0'
UP_OUT=''
UP_RC=0
UP_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade 0.2.0 --no-restart 2>&1)" || UP_RC=$?
unset STUB_NPM_NOOP_MATCH
assert_eq "$UP_RC" '1' '升级校验失败时退出非 0'
assert_contains '版本校验失败' "$UP_OUT" '报告版本校验失败'
NPM_LOG="$(cat "$STUB_NPM_LOG")"
assert_contains 'install @deepseek-ai/dsh@0.2.0' "$NPM_LOG" '尝试安装新版本'
assert_contains 'install @deepseek-ai/dsh@0.1.0' "$NPM_LOG" '回滚到旧版本'
assert_eq "$(cat "$WORK/node/VERSION")" '0.1.0' 'VERSION 保持旧版本'

section '6b. upgrade 默认通道 next 与 --check'
# 省略目标：默认通道 next（dist-tags next=1.0.0-rc.1），而不是 latest=0.2.0。
CHECK_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --check 2>&1)"
assert_contains '可升级: 0.1.0 -> 1.0.0-rc.1' "$CHECK_OUT" 'upgrade --check 的默认目标为 next'
assert_not_contains '可升级: 0.1.0 -> 0.2.0' "$CHECK_OUT" '默认目标不再是 latest'

# 省略目标实际安装：装的是 next 指向的版本。
: > "$STUB_NPM_LOG"
UPNEXT_RC=0
UPNEXT_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --no-restart 2>&1)" || UPNEXT_RC=$?
assert_eq "$UPNEXT_RC" '0' '省略目标的 upgrade 退出 0'
assert_contains 'install @deepseek-ai/dsh@1.0.0-rc.1' "$(cat "$STUB_NPM_LOG")" '省略目标时安装 next 指向的版本'
assert_contains '升级完成: 0.1.0 -> 1.0.0-rc.1' "$UPNEXT_OUT" '报告默认通道升级结果'
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"

# 显式 latest：仍解析 dist-tags 的 latest。
: > "$STUB_NPM_LOG"
UPLATEST_RC=0
UPLATEST_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade latest --no-restart 2>&1)" || UPLATEST_RC=$?
assert_eq "$UPLATEST_RC" '0' '显式 latest 的 upgrade 退出 0'
assert_contains 'install @deepseek-ai/dsh@0.2.0' "$(cat "$STUB_NPM_LOG")" '显式 latest 安装 latest 指向的版本'
assert_contains '升级完成: 0.1.0 -> 0.2.0' "$UPLATEST_OUT" '显式 latest 报告安装结果'
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"

section '6c. upgrade 目标版本带 v 前缀不误判'
# 回归：dshctl upgrade v0.3.0（npm 接受 v 前缀，dsh --version 输出裸 semver）
# 曾把装好的 0.3.0 判成「校验失败」并回滚到 0.1.0。
: > "$STUB_NPM_LOG"
UPV_OUT=''
UPV_RC=0
UPV_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade v0.3.0 --no-restart 2>&1)" || UPV_RC=$?
assert_eq "$UPV_RC" '0' 'v 前缀目标版本升级成功（退出 0）'
assert_contains '升级完成: 0.1.0 -> 0.3.0' "$UPV_OUT" 'v 前缀被剥离后版本校验通过'
assert_not_contains '版本校验失败' "$UPV_OUT" 'v 前缀不再误判为校验失败'
assert_not_contains '回滚' "$UPV_OUT" 'v 前缀不再触发回滚'
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"

# ── 6d. upgrade --list ───────────────────────────────────────────────────────
section '6d. upgrade --list 版本列表'
: > "$STUB_SYSTEMCTL_LOG"
: > "$STUB_NPM_LOG"
LIST_RC=0
LIST_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --list 2>&1)" || LIST_RC=$?
assert_eq "$LIST_RC" '0' 'upgrade --list 退出 0'
assert_eq "$(cat "$STUB_NPM_LOG")" '' 'upgrade --list 不安装任何包'
assert_eq "$(cat "$STUB_SYSTEMCTL_LOG")" '' 'upgrade --list 不调用 systemctl'
assert_eq "$(printf '%s\n' "$LIST_OUT" | sed -n 's/^  \([^ ]*\).*/\1/p' | head -n 1)" '1.0.0-rc.1' \
	'版本按最新在前排列'
assert_contains '1.0.0-rc.1  (next)' "$LIST_OUT" '标记 next 指向的版本'
assert_contains '0.2.0  (latest)' "$LIST_OUT" '标记 latest 指向的版本'
assert_eq "$(printf '%s\n' "$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --list 2 2>&1)" \
	| grep -c '^  [0-9]')" '2' '--list N 限制输出数量'
if HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --list abc >/dev/null 2>&1; then
	bad '--list 非数字数量应失败'
else
	ok '--list 非数字数量退出非 0'
fi
if HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --list 0 >/dev/null 2>&1; then
	bad '--list 0 应失败'
else
	ok '--list 0 退出非 0'
fi
# 未安装 dsh 的机器：只给 npm，不给 dsh，仍应能列出版本（且不触碰服务）。
mkdir -p "$NODSH_BIN"
ln -sfn "$WORK/node/bin/npm" "$NODSH_BIN/npm"
LIST_NODSH_RC=0
LIST_NODSH_OUT="$(HOME="$HOME3" PATH="$WORK/bin:$NODSH_BIN:/usr/bin:/bin" \
	bash "$HOME3/.local/bin/dshctl" upgrade --list 2>&1)" || LIST_NODSH_RC=$?
assert_eq "$LIST_NODSH_RC" '0' '未安装 dsh 时 --list 仍退出 0'
assert_contains '1.0.0-rc.1' "$LIST_NODSH_OUT" '未安装 dsh 时仍列出版本'
# registry 不可达
LIST_FAIL_RC=0
LIST_FAIL_OUT="$(STUB_NPM_VIEW_FAIL=1 HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --list 2>&1)" || LIST_FAIL_RC=$?
assert_eq "$LIST_FAIL_RC" '1' 'registry 不可达时 --list 退出非 0'
assert_contains '无法获取 @deepseek-ai/dsh 的版本列表' "$LIST_FAIL_OUT" 'registry 不可达时给出可读报错'

# ── 6e. upgrade 不存在的版本：装前拒绝 ───────────────────────────────────────
section '6e. 不存在的版本在安装前被拒绝'
: > "$STUB_NPM_LOG"
export STUB_NPM_NOTARGET_MATCH='1.7.0-rc.1'
NF_RC=0
NF_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade 1.7.0-rc.1 --no-restart 2>&1)" || NF_RC=$?
unset STUB_NPM_NOTARGET_MATCH
assert_eq "$NF_RC" '1' '不存在的版本退出 1'
assert_contains '版本 1.7.0-rc.1 在 registry 上不存在' "$NF_OUT" '报告版本不存在'
assert_contains 'dshctl upgrade --list' "$NF_OUT" '提示查看可用版本'
assert_contains '默认通道 next 当前版本: 1.0.0-rc.1' "$NF_OUT" '显示默认通道当前版本'
assert_eq "$(count_of 'install @deepseek-ai/dsh' "$(cat "$STUB_NPM_LOG")")" '0' '不存在的版本不尝试安装'

# ── 6f. registry 不可达：校验不阻断安装 ──────────────────────────────────────
section '6f. registry 不可达时校验不阻断升级'
: > "$STUB_NPM_LOG"
export STUB_NPM_VIEW_FAIL=1
UNREACH_RC=0
UNREACH_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade 0.2.0 --no-restart 2>&1)" || UNREACH_RC=$?
unset STUB_NPM_VIEW_FAIL
assert_eq "$UNREACH_RC" '0' 'registry 不可达时仍继续安装'
assert_contains '无法确认版本 0.2.0 是否存在' "$UNREACH_OUT" '告警无法确认版本是否存在'
assert_eq "$(cat "$WORK/node/VERSION")" '0.2.0' '安装确实已执行'
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"

# ── 6g. 安装失败带「无匹配版本」诊断：提示且不回滚 ───────────────────────────
section '6g. 安装失败时的版本未找到提示'
: > "$STUB_NPM_LOG"
TMP_PROBE="$WORK/tmp-probe"
rm -rf "$TMP_PROBE"; mkdir -p "$TMP_PROBE"
export STUB_NPM_NOTARGET_INSTALL_MATCH='0.9.0'
G_RC=0
G_OUT="$(TMPDIR="$TMP_PROBE" HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade 0.9.0 --no-restart 2>&1)" || G_RC=$?
unset STUB_NPM_NOTARGET_INSTALL_MATCH
assert_eq "$G_RC" '1' '安装失败退出 1'
assert_contains '版本 0.9.0 在 registry 上不存在' "$G_OUT" '安装失败时打印版本未找到提示'
assert_contains '服务未做任何改动' "$G_OUT" '报告现有安装未被改动'
assert_eq "$(count_of 'install @deepseek-ai/dsh@0.1.0' "$(cat "$STUB_NPM_LOG")")" '0' '安装失败不触发回滚'
assert_eq "$(find "$TMP_PROBE" -mindepth 1 | wc -l | tr -d ' ')" '0' '退出时清理安装输出临时文件'

# ── 6h. 默认通道解析与不存在的 dist-tag ──────────────────────────────────────
section '6h. 默认通道解析失败与不存在的 dist-tag'
# 省略目标 + registry 不可达：无法解析默认通道，中止而不是静默装别的版本。
: > "$STUB_NPM_LOG"
export STUB_NPM_VIEW_FAIL=1
NOCHAN_RC=0
NOCHAN_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade --no-restart 2>&1)" || NOCHAN_RC=$?
unset STUB_NPM_VIEW_FAIL
assert_eq "$NOCHAN_RC" '1' 'registry 不可达且省略目标时退出 1'
assert_contains '无法解析目标版本' "$NOCHAN_OUT" '报告无法解析默认通道目标'
assert_eq "$(count_of 'install @deepseek-ai/dsh' "$(cat "$STUB_NPM_LOG")")" '0' \
	'默认通道解析失败时不尝试安装'

# 不存在的 dist-tag：registry 查询成功但没有该 tag，仍走「版本不存在」提示。
: > "$STUB_NPM_LOG"
export STUB_NPM_NOTARGET_MATCH='bogus-tag'
BT_RC=0
BT_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade bogus-tag --no-restart 2>&1)" || BT_RC=$?
unset STUB_NPM_NOTARGET_MATCH
assert_eq "$BT_RC" '1' '不存在的 dist-tag 退出 1'
assert_contains '版本 bogus-tag 在 registry 上不存在' "$BT_OUT" '报告 dist-tag 不存在'
assert_contains '默认通道 next 当前版本' "$BT_OUT" '提示默认通道当前版本'
assert_eq "$(count_of 'install @deepseek-ai/dsh' "$(cat "$STUB_NPM_LOG")")" '0' \
	'不存在的 dist-tag 不尝试安装'

# ── 7. doctor ────────────────────────────────────────────────────────────────
section '7. dshctl doctor'
export STUB_LINGER='yes'
export STUB_SS_OUTPUT='LISTEN 0      511        127.0.0.1:3080      0.0.0.0:*'
DOCTOR_OUT=''
DOCTOR_RC=0
DOCTOR_OUT="$(PATH="$HOME3/.local/bin:$WORK/node/bin:$PATH" HOME="$HOME3" "$HOME3/.local/bin/dshctl" doctor 2>&1)" || DOCTOR_RC=$?
assert_eq "$DOCTOR_RC" '0' 'doctor 全部通过（退出 0）'
assert_contains '前端资源' "$DOCTOR_OUT" '检查前端 dist'
assert_contains '配置组合检查: dsh web --dump-config' "$DOCTOR_OUT" '检查配置组合'
assert_contains '服务运行中' "$DOCTOR_OUT" '检查服务状态'
assert_contains '稳定入口' "$DOCTOR_OUT" '检查稳定入口'
assert_contains 'DSH_HOME 位于 /mnt' "$DOCTOR_OUT" '提示 drvfs 风险（本仓库位于 /mnt，属预期）'
unset STUB_SS_OUTPUT

# ── 8. 参数校验 ──────────────────────────────────────────────────────────────
section '8. 参数校验'
if HOME="$HOME3" bash "$ROOT/install.sh" --port abc >/dev/null 2>&1; then bad '--port abc 应失败'; else ok '--port 非数字失败'; fi
if HOME="$HOME3" bash "$ROOT/install.sh" --port 70000 >/dev/null 2>&1; then bad '--port 70000 应失败'; else ok '--port 超范围失败'; fi
if HOME="$HOME3" bash "$ROOT/install.sh" --port 0 >/dev/null 2>&1; then bad '--port 0 应失败'; else ok '--port 0 失败'; fi
if HOME="$HOME3" bash "$ROOT/install.sh" --node-major '22;rm' >/dev/null 2>&1; then bad '--node-major 非法字符应失败'; else ok '--node-major 非法字符失败'; fi
if HOME="$HOME3" bash "$ROOT/install.sh" --pnpm-version '1;rm' >/dev/null 2>&1; then bad '--pnpm-version 非法字符应失败'; else ok '--pnpm-version 非法字符失败'; fi
if HOME="$HOME3" bash "$ROOT/install.sh" --workspace rel >/dev/null 2>&1; then bad '--workspace 已移除，应作为未知参数失败'; else ok '--workspace 已移除（未知参数失败）'; fi
if HOME="$HOME3" bash "$ROOT/install.sh" --name 'a/b' >/dev/null 2>&1; then bad '--name 含斜杠应失败'; else ok '--name 非法字符失败'; fi

# ── 9. 服务启动即崩溃 ────────────────────────────────────────────────────────
section '9. 服务启动即崩溃的检测'
CRASH_HOME="$WORK/home-crash"
make_home "$CRASH_HOME"
export STUB_IS_ACTIVE='failed'
CRASH_RC=0
CRASH_OUT="$(HOME="$CRASH_HOME" bash "$ROOT/install.sh" --no-linger 2>&1)" || CRASH_RC=$?
unset STUB_IS_ACTIVE
assert_eq "$CRASH_RC" '1' '服务未运行时 install.sh 退出 1'
assert_contains '服务已启用但未正常运行' "$CRASH_OUT" '报告服务未正常运行'
assert_contains 'dshctl logs -n 30' "$CRASH_OUT" '给出日志排查提示'

# ── 10. 重跑保留自定义配置 ───────────────────────────────────────────────────
section '10. 重跑保留自定义配置'
KEEP_HOME="$WORK/home-keep"
make_home "$KEEP_HOME"
HOME="$KEEP_HOME" bash "$ROOT/install.sh" --dsh-version 0.1.0 --port 3099 >/dev/null 2>&1
sed -i 's/DSH_SERVICE_PORT:=3099/DSH_SERVICE_PORT:=4100/' "$KEEP_HOME/.config/dsh-service/config"
HOME="$KEEP_HOME" bash "$ROOT/install.sh" --dsh-version 0.1.0 >/dev/null 2>&1
assert_contains '--port 4100 --no-open' "$(cat "$KEEP_HOME/.config/systemd/user/dsh.service")" '不带 --port 重跑时保留配置文件里的端口'
HOME="$KEEP_HOME" bash "$ROOT/install.sh" --dsh-version 0.1.0 --port 4200 >/dev/null 2>&1
assert_contains '--port 4200 --no-open' "$(cat "$KEEP_HOME/.config/systemd/user/dsh.service")" '--port 覆盖配置文件'
assert_contains 'DSH_SERVICE_PORT:=4200' "$(cat "$KEEP_HOME/.config/dsh-service/config")" '新端口写回配置文件'

# ── 11. 继承的 PREFIX 环境变量（nvm 兼容性） ──────────────────────────────────
section '11. PREFIX 环境变量与 nvm 兼容性'
PFX_HOME="$WORK/home-prefix"
make_home "$PFX_HOME"
PFX_RC=0
PFX_OUT="$(HOME="$PFX_HOME" PREFIX="$WORK/foreign-prefix" bash "$ROOT/install.sh" --no-linger --dsh-version 0.1.0 2>&1)" || PFX_RC=$?
assert_eq "$PFX_RC" '0' '外部已设置 PREFIX 时安装仍成功'
assert_not_contains 'not compatible with the "PREFIX"' "$PFX_OUT" '未触发 nvm 的 PREFIX 不兼容错误'
assert_file "$PFX_HOME/.local/bin/dshctl" 'PREFIX 存在时 dshctl 仍安装到 --prefix 目录'

# ── 12. 端口精确匹配 ─────────────────────────────────────────────────────────
section '12. 端口精确匹配'
export STUB_SS_OUTPUT='LISTEN 0      511        127.0.0.1:30800    0.0.0.0:*'
STATUS_30800="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" status 2>&1 || true)"
assert_contains '端口监听  : 无' "$STATUS_30800" ':30800 不被当成 :3080'
export STUB_SS_OUTPUT='LISTEN 0      511        127.0.0.1:3080      0.0.0.0:*'
STATUS_3080="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" status 2>&1 || true)"
assert_contains '端口监听  : 127.0.0.1:3080' "$STATUS_3080" ':3080 正常识别'
unset STUB_SS_OUTPUT

# ── 13. 配置值不被求值（命令注入防护） ───────────────────────────────────────
section '13. 配置引用与命令注入防护'
INJ_HOME="$WORK/home-inj"
rm -rf "$INJ_HOME"
mkdir -p "$INJ_HOME"
INJ_MARKER="$WORK/inj-marker"
rm -f "$INJ_MARKER"
DSHCTL_CONFIG_DIR="$INJ_HOME/cfg" HOME="$INJ_HOME" \
	DSH_SERVICE_LOCAL_BIN="$WORK/\$(touch $INJ_MARKER)/bin" \
	"$HOME3/.local/bin/dshctl" _render-config >/dev/null 2>&1
assert_contains '$(touch' "$(cat "$INJ_HOME/cfg/config")" '配置中保留字面量 $()'
DSHCTL_CONFIG_DIR="$INJ_HOME/cfg" HOME="$INJ_HOME" \
	"$HOME3/.local/bin/dshctl" config >/dev/null 2>&1 || true
if [ -e "$INJ_MARKER" ]; then bad '配置被 source 时执行了命令替换'; else ok '配置被 source 时未执行命令替换'; fi

# ── 14. systemd 单元注入防护 ─────────────────────────────────────────────────
section '14. systemd 单元注入防护'
UNIT_INJ_HOME="$WORK/home-unitinj"
rm -rf "$UNIT_INJ_HOME"
mkdir -p "$UNIT_INJ_HOME"
UNIT_INJ_RC=0
DSH_SERVICE_NAME='inject' DSH_SERVICE_EXTRA_ARGS=$'--x\nExecStartPre=/bin/echo pwned' \
	DSHCTL_CONFIG_DIR="$UNIT_INJ_HOME/cfg" HOME="$UNIT_INJ_HOME" \
	"$HOME3/.local/bin/dshctl" _render-unit >/dev/null 2>&1 || UNIT_INJ_RC=$?
assert_eq "$UNIT_INJ_RC" '1' 'EXTRA_ARGS 含换行时拒绝渲染'
if [ -f "$UNIT_INJ_HOME/.config/systemd/user/inject.service" ]; then
	bad '不应写出被注入的单元'
else
	ok '未写出被注入的单元'
fi

# ── 15. 非登录环境健壮性 ─────────────────────────────────────────────────────
section '15. 非登录环境健壮性'
DOCTOR_NOUSER="$(env -u USER -u LOGNAME HOME="$HOME3" \
	PATH="$WORK/bin:$WORK/node/bin:/usr/bin:/bin" \
	"$HOME3/.local/bin/dshctl" doctor 2>&1 || true)"
assert_not_contains 'unbound variable' "$DOCTOR_NOUSER" 'USER 缺失时不再崩溃'
assert_contains '通过' "$DOCTOR_NOUSER" 'doctor 仍输出汇总'

VERSION_NO_NODE="$(env -i HOME="$HOME3" PATH=/usr/bin:/bin "$HOME3/.local/bin/dshctl" version 2>&1 || true)"
assert_contains 'v24.99.0' "$VERSION_NO_NODE" 'version 自动补上 node bin 目录'

# ── 16. doctor --fix 韧性 ────────────────────────────────────────────────────
section '16. doctor --fix 在 nvm 缺失时不中断'
FIX_NO_NVM="$(DSH_SERVICE_NVM_DIR="$WORK/no-such-nvm" HOME="$HOME3" \
	PATH="$WORK/bin:$WORK/node/bin:/usr/bin:/bin" \
	"$HOME3/.local/bin/dshctl" doctor --fix 2>&1 || true)"
assert_contains 'nvm 缺失' "$FIX_NO_NVM" '报告 nvm 缺失'
assert_contains '通过' "$FIX_NO_NVM" 'nvm 缺失时仍输出汇总'
assert_not_contains 'unbound variable' "$FIX_NO_NVM" '未因 nvm 缺失而中断'

# ── 17. 默认通道 next 与保留已有安装 ─────────────────────────────────────────
section '17. 默认通道 next 与保留已有安装'
LATEST_HOME="$WORK/home-latest"
make_home "$LATEST_HOME"
export STUB_NPM_VIEW_VERSION='0.2.0'
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"
: > "$STUB_NPM_LOG"

# 17a 已有安装 + 未显式指定版本：保留现有版本，不跟随默认通道升级。
LATEST_OUT1="$(HOME="$LATEST_HOME" bash "$ROOT/install.sh" --no-service 2>&1)"
assert_eq "$(count_of 'install @deepseek-ai/dsh' "$(cat "$STUB_NPM_LOG")")" '0' \
	'已有安装重跑不触发 npm install'
assert_contains 'dsh 0.1.0 已安装，保留现有版本' "$LATEST_OUT1" '报告保留已安装版本'
assert_contains '默认通道 next' "$LATEST_OUT1" '保留提示点名默认通道'
assert_contains '版本     : dsh 0.1.0' "$LATEST_OUT1" '汇总显示保留的版本'

# 17b 显式 --dsh-version next：按 dist-tags 解析出的具体版本安装。
: > "$STUB_NPM_LOG"
NEXT_OUT="$(HOME="$LATEST_HOME" bash "$ROOT/install.sh" --no-service --dsh-version next 2>&1)"
assert_contains 'install @deepseek-ai/dsh@next' "$(cat "$STUB_NPM_LOG")" '显式 next 按默认通道安装'
assert_contains '版本     : dsh 1.0.0-rc.1' "$NEXT_OUT" 'next 解析为 dist-tags 指向的版本'

# 17c 已安装 next 指向的版本时，重跑显式 next 仍应跳过 npm install（dist-tag 幂等）。
: > "$STUB_NPM_LOG"
NEXT2_OUT="$(HOME="$LATEST_HOME" bash "$ROOT/install.sh" --no-service --dsh-version next 2>&1)"
assert_eq "$(count_of 'install @deepseek-ai/dsh' "$(cat "$STUB_NPM_LOG")")" '0' \
	'next 已安装时重跑跳过 npm install'
assert_contains 'dsh 1.0.0-rc.1 已安装，跳过' "$NEXT2_OUT" 'dist-tag 解析后判为同一版本'

# 17d --force：即使版本匹配也按默认通道重装。
: > "$STUB_NPM_LOG"
FORCE_OUT="$(HOME="$LATEST_HOME" bash "$ROOT/install.sh" --no-service --force 2>&1)"
assert_contains 'install @deepseek-ai/dsh@next' "$(cat "$STUB_NPM_LOG")" '--force 按默认通道重装'
assert_contains '版本     : dsh 1.0.0-rc.1' "$FORCE_OUT" '强制重装后汇总仍有版本'

# 17e 回归：--dsh-version 带 v 前缀时，应与已安装的裸 semver 判为同一版本，
# 否则重跑安装器会永远重装（幂等性失效）。
printf '%s\n' '1.0.0' > "$WORK/node/VERSION"
: > "$STUB_NPM_LOG"
VPFX_OUT="$(HOME="$LATEST_HOME" bash "$ROOT/install.sh" --no-service --dsh-version v1.0.0 2>&1)"
assert_eq "$(count_of 'install @deepseek-ai/dsh' "$(cat "$STUB_NPM_LOG")")" '0' \
	'v 前缀 --dsh-version 不再触发重装'
assert_contains 'dsh 1.0.0 已安装，跳过' "$VPFX_OUT" 'v 前缀与裸 semver 判为同一版本'

# 17f 全新机器（PATH 上没有 dsh）：默认安装 next。
FRESH_HOME="$WORK/home-dsh-default"
make_home "$FRESH_HOME"
# 预置本地 Node 24：避免 nvm install 把 $WORK/node/bin 前置进 PATH、从而暴露出桩 dsh。
mkdir -p "$FRESH_HOME/.nvm/versions/node/v24.99.0/bin"
cat > "$FRESH_HOME/.nvm/versions/node/v24.99.0/bin/node" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'v24.99.0\n'; fi
exit 0
EOF
chmod +x "$FRESH_HOME/.nvm/versions/node/v24.99.0/bin/node"
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"
: > "$STUB_NPM_LOG"
FRESH_RC=0
FRESH_OUT="$(HOME="$FRESH_HOME" \
	PATH="$WORK/bin:$NODSH_BIN:$FRESH_HOME/.nvm/versions/node/v24.99.0/bin:/usr/bin:/bin" \
	bash "$ROOT/install.sh" --no-service 2>&1)" || FRESH_RC=$?
assert_eq "$FRESH_RC" '0' '未安装 dsh 时安装退出 0'
assert_contains 'install @deepseek-ai/dsh@next' "$(cat "$STUB_NPM_LOG")" '未安装 dsh 时默认安装 next'
assert_eq "$(cat "$WORK/node/VERSION")" '1.0.0-rc.1' 'next 被解析为 dist-tags 指向的具体版本'
assert_contains '版本     : dsh 1.0.0-rc.1' "$FRESH_OUT" '汇总显示 next 解析后的版本'
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"

# 17g registry 不可达时的新安装：告警并回退为字面 next，安装不中止。
rm -f "$FRESH_HOME/.local/bin/dsh"
: > "$STUB_NPM_LOG"
FRESHFAIL_RC=0
FRESHFAIL_OUT="$(HOME="$FRESH_HOME" STUB_NPM_VIEW_FAIL=1 \
	PATH="$WORK/bin:$NODSH_BIN:$FRESH_HOME/.nvm/versions/node/v24.99.0/bin:/usr/bin:/bin" \
	bash "$ROOT/install.sh" --no-service 2>&1)" || FRESHFAIL_RC=$?
assert_eq "$FRESHFAIL_RC" '0' 'registry 不可达时新安装仍成功'
assert_contains '将直接安装 next' "$FRESHFAIL_OUT" 'registry 不可达时警告并回退字面通道'
assert_contains 'install @deepseek-ai/dsh@next' "$(cat "$STUB_NPM_LOG")" '回退后仍安装字面 next'
rm -f "$FRESH_HOME/.local/bin/dsh"
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"

# ── 18. --print-dshctl 与源码内嵌段逐字节一致 ────────────────────────────────
section '18. --print-dshctl 字节一致'
awk '/^IFS= read -r -d/{flag=1;next} /^DSHCTL_EMBED_EOF$/{flag=0} flag' "$ROOT/install.sh" > "$WORK/dshctl.expected"
bash "$ROOT/install.sh" --print-dshctl > "$WORK/dshctl.printed" 2>/dev/null
if cmp -s "$WORK/dshctl.expected" "$WORK/dshctl.printed"; then
	ok '--print-dshctl 与源码内嵌段一致'
else
	bad '--print-dshctl 与源码内嵌段不一致'
fi

# ── 19. shell 配置转义与更新 ─────────────────────────────────────────────────
section '19. shell 配置转义与更新'
ESC_HOME="$WORK/home-esc"
make_home "$ESC_HOME"
ESC_PREFIX="$ESC_HOME/we\"ird\$dir"
HOME="$ESC_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --prefix "$ESC_PREFIX" >/dev/null 2>&1
if bash -n "$ESC_HOME/.bashrc" 2>/dev/null; then
	ok '含 " 与 $ 的 --prefix 不破坏 .bashrc 语法'
else
	bad '含 " 与 $ 的 --prefix 破坏了 .bashrc 语法'
fi
HOME="$ESC_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --prefix "$ESC_HOME/other-bin" >/dev/null 2>&1
assert_contains 'other-bin:$PATH' "$(cat "$ESC_HOME/.bashrc")" '改 --prefix 后 .bashrc 被更新'
assert_eq "$(count_of '# >>> dsh-service >>>' "$(cat "$ESC_HOME/.bashrc")")" '1' 'shell 配置块仍只有一份'
assert_eq "$(count_of 'export NVM_DIR=' "$(cat "$ESC_HOME/.bashrc")")" '1' 'nvm 加载语句未重复'

# ── 20. --name 变更清理旧单元 ────────────────────────────────────────────────
section '20. --name 变更清理旧单元'
RN_HOME="$WORK/home-rename"
make_home "$RN_HOME"
: > "$STUB_SYSTEMCTL_LOG"
HOME="$RN_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --name alpha --port 3090 >/dev/null 2>&1
HOME="$RN_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --name beta --port 3090 >/dev/null 2>&1
if [ -f "$RN_HOME/.config/systemd/user/alpha.service" ]; then
	bad '--name 变更后旧单元应被删除'
else
	ok '--name 变更后旧单元已删除'
fi
assert_file "$RN_HOME/.config/systemd/user/beta.service" '新单元已写入'
assert_contains 'disable --now alpha.service' "$(cat "$STUB_SYSTEMCTL_LOG")" '旧单元被停用'

# ── 21. 前导零端口归一化 ─────────────────────────────────────────────────────
section '21. 前导零端口归一化'
Z_HOME="$WORK/home-zero"
make_home "$Z_HOME"
export STUB_SS_OUTPUT='LISTEN 0      511        127.0.0.1:80      0.0.0.0:*'
Z_RC=0
Z_OUT="$(HOME="$Z_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --port 080 2>&1)" || Z_RC=$?
unset STUB_SS_OUTPUT
assert_eq "$Z_RC" '0' '--port 080 不再因八进制报错'
assert_contains '自动改用端口 81' "$Z_OUT" '前导零端口按十进制进位'
assert_contains '--port 81 --no-open' "$(cat "$Z_HOME/.config/systemd/user/dsh.service")" '单元使用归一化后的端口'

# ── 22. ExecStart 的 % 说明符转义 ────────────────────────────────────────────
section '22. ExecStart % 说明符转义'
PCT_HOME="$WORK/home-pct"
make_home "$PCT_HOME"
HOME="$PCT_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --prefix "$WORK/pct%bin" >/dev/null 2>&1
if grep -qF 'ExecStart='"$WORK"'/pct%%bin/dsh' "$PCT_HOME/.config/systemd/user/dsh.service"; then
	ok 'ExecStart 中的 % 被转义为 %%'
else
	bad 'ExecStart 中的 % 未转义'
fi

# ── 23. HOME 缺失时的报错 ────────────────────────────────────────────────────
section '23. HOME 缺失时的报错'
HOMELESS="$(env -u HOME bash "$ROOT/install.sh" 2>&1 || true)"
assert_contains '缺少 HOME' "$HOMELESS" 'install.sh 在 HOME 缺失时给出可读报错'
assert_not_contains 'unbound variable' "$HOMELESS" 'install.sh 不报 unbound variable'
NOHOME_CTL="$(env -u HOME bash "$WORK/dshctl.printed" version 2>&1 || true)"
assert_contains '缺少 HOME' "$NOHOME_CTL" 'dshctl 在 HOME 缺失时给出可读报错'

# ── 24. doctor --fix 在单元渲染失败时继续 ────────────────────────────────────
section '24. doctor --fix 渲染失败不中断'
FIXU_HOME="$WORK/home-fixunit"
make_home "$FIXU_HOME"
FIXU_OUT="$(HOME="$FIXU_HOME" DSH_SERVICE_EXTRA_ARGS=$'--x\nExecStartPre=/bin/echo pwned' \
	PATH="$FIXU_HOME/.local/bin:$PATH" "$HOME3/.local/bin/dshctl" doctor --fix 2>&1 || true)"
assert_not_contains 'unbound variable' "$FIXU_OUT" 'doctor --fix 未崩溃'
assert_contains '通过' "$FIXU_OUT" 'doctor --fix 仍输出汇总'

# ── 25. Node 下载失败：重试与可读报错 ────────────────────────────────────────
section '25. Node 下载失败的重试与报错'
NODEFAIL_HOME="$WORK/home-nodefail"
make_home "$NODEFAIL_HOME"
reset_nvm_log
export STUB_NVM_ALWAYS_FAIL=1 DSH_SERVICE_NODE_ATTEMPTS=3 DSH_SERVICE_NODE_RETRY_DELAY=0
NODEFAIL_RC=0
NODEFAIL_OUT="$(HOME="$NODEFAIL_HOME" bash "$ROOT/install.sh" --no-service --node-major 22 --dsh-version 0.1.0 2>&1)" || NODEFAIL_RC=$?
unset STUB_NVM_ALWAYS_FAIL DSH_SERVICE_NODE_ATTEMPTS DSH_SERVICE_NODE_RETRY_DELAY
assert_eq "$NODEFAIL_RC" '1' 'Node 下载持续失败时安装器退出非 0'
assert_contains 'Node 22 下载失败' "$NODEFAIL_OUT" '报错说明是 Node 下载失败'
assert_contains 'DSH_SERVICE_NODE_MIRROR' "$NODEFAIL_OUT" '提示可用镜像变量'
assert_not_contains 'unbound variable' "$NODEFAIL_OUT" '不再以 unbound variable 崩溃'
assert_eq "$(count_of 'install -b 22' "$(cat "$STUB_NVM_LOG")")" '3' '按 DSH_SERVICE_NODE_ATTEMPTS 重试 3 次'
assert_contains '第 1/3 次尝试' "$NODEFAIL_OUT" '重试时给出进度提示'
assert_not_contains 'Node 主版本 22 已安装' "$NODEFAIL_OUT" '未安装成功时不会误报跳过下载'

# ── 25b. Node 下载首次失败后重试成功 ─────────────────────────────────────────
section '25b. Node 下载失败后重试成功'
RETRY_HOME="$WORK/home-noderetry"
make_home "$RETRY_HOME"
reset_nvm_log
export STUB_NVM_FAIL_UNTIL=1 DSH_SERVICE_NODE_ATTEMPTS=3 DSH_SERVICE_NODE_RETRY_DELAY=0
RETRY_RC=0
RETRY_OUT="$(HOME="$RETRY_HOME" bash "$ROOT/install.sh" --no-service --node-major 22 --dsh-version 0.1.0 2>&1)" || RETRY_RC=$?
unset STUB_NVM_FAIL_UNTIL DSH_SERVICE_NODE_ATTEMPTS DSH_SERVICE_NODE_RETRY_DELAY
assert_eq "$RETRY_RC" '0' '首次下载失败后重试成功'
assert_eq "$(count_of 'install -b 22' "$(cat "$STUB_NVM_LOG")")" '2' '失败一次后第二次调用成功'
assert_contains '安装完成' "$RETRY_OUT" '安装正常完成'

# ── 26. nvm.sh 引用未定义变量时不终止安装器（set -u 回归） ───────────────────
section '26. nvm 与 set -u 兼容性'
TRIP_HOME="$WORK/home-nvm-u"
make_home "$TRIP_HOME"
reset_nvm_log
export STUB_NVM_TRIP_SET_U=1
TRIP_RC=0
TRIP_OUT="$(HOME="$TRIP_HOME" bash "$ROOT/install.sh" --no-service --node-major 22 --dsh-version 0.1.0 2>&1)" || TRIP_RC=$?
unset STUB_NVM_TRIP_SET_U
assert_eq "$TRIP_RC" '0' 'nvm 内部引用未定义变量时安装仍成功'
assert_not_contains 'unbound variable' "$TRIP_OUT" 'nvm 内的未定义变量不再终止安装器'
assert_contains '安装完成' "$TRIP_OUT" '安装正常完成'

# ── 27. 已安装同主版本时跳过下载（离线重跑） ─────────────────────────────────
section '27. 已安装同主版本时跳过下载'
LOCAL_HOME="$WORK/home-localnode"
make_home "$LOCAL_HOME"
mkdir -p "$LOCAL_HOME/.nvm/versions/node/v22.5.0/bin"
cat > "$LOCAL_HOME/.nvm/versions/node/v22.5.0/bin/node" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf 'v22.5.0\n'; fi
exit 0
EOF
chmod +x "$LOCAL_HOME/.nvm/versions/node/v22.5.0/bin/node"
reset_nvm_log
LOCAL_RC=0
LOCAL_OUT="$(HOME="$LOCAL_HOME" bash "$ROOT/install.sh" --no-service --node-major 22 --dsh-version 0.1.0 2>&1)" || LOCAL_RC=$?
assert_eq "$LOCAL_RC" '0' '显式 --node-major 22 且本地已有 Node 22 时安装成功'
assert_eq "$(count_of 'install ' "$(cat "$STUB_NVM_LOG")")" '0' '不再调用 nvm install（无需联网解析版本）'
assert_contains 'Node 主版本 22 已安装' "$LOCAL_OUT" '提示复用本地 Node'
assert_contains "Node v22.5.0" "$LOCAL_OUT" '使用本地 Node 的版本'
assert_contains "DSH_SERVICE_NODE_BIN_DIR  = $LOCAL_HOME/.nvm/versions/node/v22.5.0/bin" \
	"$(HOME="$LOCAL_HOME" "$LOCAL_HOME/.local/bin/dshctl" config)" 'NODE_BIN_DIR 指向复用的本地 Node'

# ── 27b. 重跑沿用配置记录的 Node 主版本（不被新默认值 24 迁移） ───────────────
section '27b. 重跑沿用已记录的 Node 主版本'
LOCAL_UNIT="$LOCAL_HOME/.config/systemd/user/dsh.service"
LOCAL_UNIT_HASH="$(sha256sum "$LOCAL_UNIT" | awk '{print $1}')"
reset_nvm_log
KEEP_RC=0
KEEP_OUT="$(HOME="$LOCAL_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 2>&1)" || KEEP_RC=$?
assert_eq "$KEEP_RC" '0' '未传 --node-major 时重跑成功'
assert_eq "$(count_of 'install ' "$(cat "$STUB_NVM_LOG")")" '0' '沿用已记录的 Node 时不下载新主版本'
assert_contains '沿用已安装的 Node 主版本 22' "$KEEP_OUT" '提示沿用了已记录的 Node 主版本'
assert_not_contains 'Node 主版本 24' "$KEEP_OUT" '未迁移到默认主版本 24'
assert_eq "$(sha256sum "$LOCAL_UNIT" | awk '{print $1}')" "$LOCAL_UNIT_HASH" '沿用 Node 时单元文件未变'
assert_contains "DSH_SERVICE_NODE_BIN_DIR  = $LOCAL_HOME/.nvm/versions/node/v22.5.0/bin" \
	"$(HOME="$LOCAL_HOME" "$LOCAL_HOME/.local/bin/dshctl" config)" '配置仍记录原来的 Node 目录'

# 记录在配置里的 Node 目录已失效（被删除 / node 不可执行）→ 回退到默认主版本 24。
STALE_HOME="$WORK/home-stalenode"
make_home "$STALE_HOME"
mkdir -p "$STALE_HOME/.config/dsh-service"
cat > "$STALE_HOME/.config/dsh-service/config" <<EOF
: "\${DSH_SERVICE_NAME:=dsh}"
: "\${DSH_SERVICE_NODE_BIN_DIR:=$STALE_HOME/.nvm/versions/node/v22.9.9/bin}"
EOF
reset_nvm_log
STALE_RC=0
STALE_OUT="$(HOME="$STALE_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 2>&1)" || STALE_RC=$?
assert_eq "$STALE_RC" '0' '记录的 Node 目录失效时安装成功'
assert_eq "$(count_of 'install -b 24' "$(cat "$STUB_NVM_LOG")")" '1' '记录失效时回退到默认主版本 24'
assert_contains 'Node v24.99.0' "$STALE_OUT" '回退后使用 Node 24'

# ── 28. dshctl upgrade-node 下载失败 ─────────────────────────────────────────
section '28. dshctl upgrade-node 下载失败'
reset_nvm_log
export STUB_NVM_ALWAYS_FAIL=1 DSH_SERVICE_NODE_ATTEMPTS=2 DSH_SERVICE_NODE_RETRY_DELAY=0
UPN_RC=0
UPN_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade-node 22 2>&1)" || UPN_RC=$?
unset STUB_NVM_ALWAYS_FAIL DSH_SERVICE_NODE_ATTEMPTS DSH_SERVICE_NODE_RETRY_DELAY
assert_eq "$UPN_RC" '1' 'Node 下载失败时 upgrade-node 退出非 0'
assert_contains 'nvm install 22 失败' "$UPN_OUT" 'upgrade-node 给出可读失败信息'
assert_not_contains 'unbound variable' "$UPN_OUT" 'upgrade-node 不再以 unbound variable 崩溃'
assert_eq "$(count_of 'install -b 22' "$(cat "$STUB_NVM_LOG")")" '2' 'upgrade-node 按次数重试'

# ── 28b. dshctl upgrade-node 按默认通道重装 dsh ──────────────────────────────
section '28b. dshctl upgrade-node 按默认通道重装 dsh'
reset_nvm_log
: > "$STUB_NPM_LOG"
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"
UOK_RC=0
UOK_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" upgrade-node 22 2>&1)" || UOK_RC=$?
assert_eq "$UOK_RC" '0' 'Node 安装成功时 upgrade-node 退出 0'
assert_contains 'install @deepseek-ai/dsh@1.0.0-rc.1' "$(cat "$STUB_NPM_LOG")" \
	'upgrade-node 重装默认通道 next 指向的版本'
assert_contains '默认通道 next' "$UOK_OUT" 'upgrade-node 报告默认通道'
printf '%s\n' '0.1.0' > "$WORK/node/VERSION"
rm -f "$HOME3/.stub-node-version"

# ── 29. dshctl plugins list / reset（保留配置） ───────────────────────────────
section '29. dshctl plugins list / reset'
PLUG_DIR="$HOME3/.dsh/profiles/web"
write_plugin_fixture() {
	mkdir -p "$PLUG_DIR/node_modules/@acme/hello" "$PLUG_DIR/node_modules/leftpad"
	cat > "$PLUG_DIR/package.json" <<'EOF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {
    "@acme/hello": "^1.2.3",
    "leftpad": "^2.0.0"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "@acme/hello"
      ],
      "patchReload": "live"
    }
  }
}
EOF
	printf '%s\n' '# user patch' '[]' > "$PLUG_DIR/cordis.patch.yml"
	printf 'lockfile\n' > "$PLUG_DIR/pnpm-lock.yaml"
	printf '{"name":"leftpad"}\n' > "$PLUG_DIR/node_modules/leftpad/package.json"
}
write_plugin_fixture

PLUG_LIST="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" plugins list 2>&1)"
assert_contains 'profile  : web' "$PLUG_LIST" 'plugins list 显示 profile'
assert_contains '@acme/hello' "$PLUG_LIST" 'plugins list 列出插件'
assert_contains 'leftpad' "$PLUG_LIST" 'plugins list 列出普通依赖'
assert_contains '2 个' "$PLUG_LIST" 'plugins list 统计数量'

CONFIG_HASH_BEFORE="$(sha256sum "$HOME3/.config/dsh-service/config" | awk '{print $1}')"
PATCH_HASH_BEFORE="$(sha256sum "$PLUG_DIR/cordis.patch.yml" | awk '{print $1}')"
: > "$STUB_SYSTEMCTL_LOG"
export STUB_IS_ACTIVE='active'
PLUG_RC=0
PLUG_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" plugins reset --yes 2>&1)" || PLUG_RC=$?
unset STUB_IS_ACTIVE
assert_eq "$PLUG_RC" '0' 'plugins reset 退出 0'
assert_contains '已停止服务' "$PLUG_OUT" '重置前先停止服务'
assert_contains '服务已重启' "$PLUG_OUT" '重置后重启服务'
PLUG_SYSLOG="$(cat "$STUB_SYSTEMCTL_LOG")"
assert_contains '--user stop dsh.service' "$PLUG_SYSLOG" '调用 systemctl stop'
assert_contains '--user restart dsh.service' "$PLUG_SYSLOG" '调用 systemctl restart'
assert_file "$PLUG_DIR/package.json.bak" '生成 manifest 备份'

PLUG_MANIFEST="$(cat "$PLUG_DIR/package.json")"
assert_not_contains '@acme/hello' "$PLUG_MANIFEST" 'manifest 已移除插件依赖'
assert_not_contains 'leftpad' "$PLUG_MANIFEST" 'manifest 已移除全部依赖'
assert_contains '"dependencies": {' "$PLUG_MANIFEST" 'dependencies 保留为空对象'
assert_contains '@deepseek-ai/dsh-base' "$PLUG_MANIFEST" '保留随附 base bundle'
assert_contains '@deepseek-ai/dsh-web-app' "$PLUG_MANIFEST" '保留随附 web bundle'
assert_not_contains '"@deepseek-ai/dsh-web-app",' "$PLUG_MANIFEST" '数组末元素逗号已修正'
assert_contains '"patchReload": "live"' "$PLUG_MANIFEST" 'manifest 其余字段保留'
if [ -d "$PLUG_DIR/node_modules" ]; then bad 'node_modules 应被删除'; else ok 'node_modules 已删除'; fi
if [ -f "$PLUG_DIR/pnpm-lock.yaml" ]; then bad 'pnpm-lock.yaml 应被删除'; else ok 'pnpm-lock.yaml 已删除'; fi
assert_eq "$(sha256sum "$HOME3/.config/dsh-service/config" | awk '{print $1}')" "$CONFIG_HASH_BEFORE" 'dsh-service 配置未变'
assert_eq "$(sha256sum "$PLUG_DIR/cordis.patch.yml" | awk '{print $1}')" "$PATCH_HASH_BEFORE" 'profile 的 cordis.patch.yml 未变'
assert_contains 'leftpad' "$(cat "$PLUG_DIR/package.json.bak")" '备份保留原始内容'

PLUG_AGAIN="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" plugins reset --yes 2>&1)"
assert_contains '没有已安装的插件' "$PLUG_AGAIN" '无插件时重置为空操作'

# --no-restart：完全不动服务
write_plugin_fixture
: > "$STUB_SYSTEMCTL_LOG"
export STUB_IS_ACTIVE='active'
PLUG_NR_RC=0
PLUG_NR_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" plugins reset --yes --no-restart 2>&1)" || PLUG_NR_RC=$?
unset STUB_IS_ACTIVE
assert_eq "$PLUG_NR_RC" '0' '--no-restart 退出 0'
assert_contains '按 --no-restart 跳过服务重启' "$PLUG_NR_OUT" '--no-restart 给出提示'
assert_not_contains '--user restart dsh.service' "$(cat "$STUB_SYSTEMCTL_LOG")" '--no-restart 不重启服务'
assert_not_contains '--user stop dsh.service' "$(cat "$STUB_SYSTEMCTL_LOG")" '--no-restart 不停止服务'

# 非交互式必须显式 --yes
write_plugin_fixture
if HOME="$HOME3" "$HOME3/.local/bin/dshctl" plugins reset < /dev/null >/dev/null 2>&1; then
	bad '非交互式缺少 --yes 应失败'
else
	ok '非交互式缺少 --yes 退出非 0'
fi
if HOME="$HOME3" "$HOME3/.local/bin/dshctl" plugins nope >/dev/null 2>&1; then
	bad 'plugins 未知子命令应失败'
else
	ok 'plugins 未知子命令退出非 0'
fi

# ── 30. dshctl export / import ───────────────────────────────────────────────
section '30. dshctl export / import'
EXP_DIR="$WORK/export"
mkdir -p "$EXP_DIR"
# 源端（HOME3）补齐 DSH_HOME 内容：会话、附件、storages、settings、凭证。
mkdir -p "$HOME3/.dsh/sessions/--proj--/session-a" "$HOME3/.dsh/attachments" "$HOME3/.dsh/storages"
printf 'settings-v1\n' > "$HOME3/.dsh/settings.yaml"
printf 'cred-v1\n' > "$HOME3/.dsh/.credentials.yaml"
chmod 600 "$HOME3/.dsh/.credentials.yaml"
printf 'sess\n' > "$HOME3/.dsh/sessions/--proj--/session-a/session.v3.jsonl.zstd"
printf 'lock\n' > "$HOME3/.dsh/sessions/--proj--/session-a/session.lock"
printf 'attach\n' > "$HOME3/.dsh/attachments/f.bin"
printf '{}\n' > "$HOME3/.dsh/storages/workspace.json"

EXP_RC=0
EXP_OUT="$(HOME="$HOME3" "$HOME3/.local/bin/dshctl" export -o "$EXP_DIR/default.tgz" 2>&1)" || EXP_RC=$?
assert_eq "$EXP_RC" '0' 'export 退出 0'
assert_contains '已导出' "$EXP_OUT" 'export 报告成功'
assert_file "$EXP_DIR/default.tgz" '归档已生成'
EXP_MEMBERS="$(tar -tzf "$EXP_DIR/default.tgz")"
assert_contains 'manifest' "$EXP_MEMBERS" '归档含 manifest'
assert_contains 'config/dsh-service.config' "$EXP_MEMBERS" '归档含配置副本'
assert_contains 'dsh-home/settings.yaml' "$EXP_MEMBERS" '归档含 settings.yaml'
assert_contains 'dsh-home/sessions/' "$EXP_MEMBERS" '默认导出会话'
assert_contains 'dsh-home/attachments/f.bin' "$EXP_MEMBERS" '默认导出附件'
assert_not_contains 'node_modules' "$EXP_MEMBERS" '不导出 node_modules'
assert_not_contains 'session.lock' "$EXP_MEMBERS" '不导出会话锁文件'
assert_not_contains '.credentials.yaml' "$EXP_MEMBERS" '默认不导出凭证'
assert_contains 'INCLUDE_SECRETS=0' "$(tar -xzOf "$EXP_DIR/default.tgz" manifest)" 'manifest 标注不含凭证'
assert_contains 'SERVICE_PORT=3080' "$(tar -xzOf "$EXP_DIR/default.tgz" manifest)" 'manifest 记录可移植配置'

# --with-secrets / --no-sessions
HOME="$HOME3" "$HOME3/.local/bin/dshctl" export -o "$EXP_DIR/sec.tgz" --with-secrets --no-sessions >/dev/null 2>&1
EXP_SEC_MEMBERS="$(tar -tzf "$EXP_DIR/sec.tgz")"
assert_contains 'dsh-home/.credentials.yaml' "$EXP_SEC_MEMBERS" '--with-secrets 导出凭证'
assert_not_contains 'dsh-home/sessions' "$EXP_SEC_MEMBERS" '--no-sessions 跳过会话'

# 覆盖保护
if HOME="$HOME3" "$HOME3/.local/bin/dshctl" export -o "$EXP_DIR/default.tgz" >/dev/null 2>&1; then
	bad '已存在的归档应拒绝覆盖'
else
	ok '已存在的归档拒绝覆盖（需 --force）'
fi
EXP_FORCE_RC=0
HOME="$HOME3" "$HOME3/.local/bin/dshctl" export -o "$EXP_DIR/default.tgz" --force >/dev/null 2>&1 || EXP_FORCE_RC=$?
assert_eq "$EXP_FORCE_RC" '0' '--force 允许覆盖'

# 导入到「新环境」：install.sh 装好配置，但 DSH_HOME 里已有本机数据。
IMP_HOME="$WORK/home-import"
make_home "$IMP_HOME"
HOME="$IMP_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --port 3999 >/dev/null 2>&1
mkdir -p "$IMP_HOME/.dsh/profiles/web/node_modules/keep" "$IMP_HOME/.dsh/sessions/--keep--/s"
printf 'settings-old\n' > "$IMP_HOME/.dsh/settings.yaml"
printf 'keep\n' > "$IMP_HOME/.dsh/profiles/web/node_modules/keep/index.js"
printf 'other\n' > "$IMP_HOME/.dsh/sessions/--keep--/s/session.v3.jsonl.zstd"

# 非交互式必须显式 --yes
if HOME="$IMP_HOME" "$IMP_HOME/.local/bin/dshctl" import "$EXP_DIR/default.tgz" < /dev/null >/dev/null 2>&1; then
	bad 'import 非交互式缺少 --yes 应失败'
else
	ok 'import 非交互式缺少 --yes 退出非 0'
fi

# dry-run 不落盘
IMP_BEFORE="$(find "$IMP_HOME/.dsh" -mindepth 1 | sort)"
IMP_DRY="$(HOME="$IMP_HOME" "$IMP_HOME/.local/bin/dshctl" import "$EXP_DIR/default.tgz" --dry-run --yes 2>&1)"
assert_contains 'dry-run' "$IMP_DRY" 'import --dry-run 提示不写入'
assert_eq "$(find "$IMP_HOME/.dsh" -mindepth 1 | sort)" "$IMP_BEFORE" 'import --dry-run 未改动 DSH_HOME'

IMP_RC=0
IMP_OUT="$(HOME="$IMP_HOME" "$IMP_HOME/.local/bin/dshctl" import "$EXP_DIR/default.tgz" --yes --no-restart 2>&1)" || IMP_RC=$?
assert_eq "$IMP_RC" '0' 'import 退出 0'
assert_contains '导入完成' "$IMP_OUT" 'import 报告完成'
assert_contains '已导入 DSH_HOME' "$IMP_OUT" 'import 写入 DSH_HOME'
assert_contains 'dsh plugin --profile web install' "$IMP_OUT" '未装插件时给出重装指引'

assert_eq "$(cat "$IMP_HOME/.dsh/settings.yaml")" 'settings-v1' 'settings.yaml 已覆盖'
assert_eq "$(cat "$IMP_HOME/.dsh/settings.yaml.~1~" 2>/dev/null)" 'settings-old' '被覆盖的文件就地备份'
assert_eq "$(cat "$IMP_HOME/.dsh/profiles/web/node_modules/keep/index.js" 2>/dev/null)" 'keep' '归档外的文件保留'
assert_file "$IMP_HOME/.dsh/sessions/--proj--/session-a/session.v3.jsonl.zstd" '导入的会话已落盘'
assert_file "$IMP_HOME/.dsh/sessions/--keep--/s/session.v3.jsonl.zstd" '本机原有会话保留'
if [ -f "$IMP_HOME/.dsh/.credentials.yaml" ]; then bad '默认归档不应写入凭证'; else ok '默认归档未写入凭证'; fi

# 配置只应用可移植项：端口来自归档，路径类保留本机
IMP_CONF="$(HOME="$IMP_HOME" "$IMP_HOME/.local/bin/dshctl" config)"
assert_contains 'DSH_SERVICE_PORT          = 3080' "$IMP_CONF" '导入应用归档端口'
assert_contains "DSH_SERVICE_DSH_HOME      = $IMP_HOME/.dsh" "$IMP_CONF" 'DSH_HOME 保留本机取值'
assert_contains "DSH_SERVICE_NODE_BIN_DIR  = $WORK/node/bin" "$IMP_CONF" 'node bin 目录保留本机取值'
assert_file "$(find "$IMP_HOME/.config/dsh-service" -name 'config.bak-*' -print -quit)" '原配置已备份'

# 含凭证的归档可还原凭证
SEC_HOME="$WORK/home-import-sec"
make_home "$SEC_HOME"
HOME="$SEC_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 >/dev/null 2>&1
HOME="$SEC_HOME" "$SEC_HOME/.local/bin/dshctl" import "$EXP_DIR/sec.tgz" --yes --no-restart >/dev/null 2>&1
assert_eq "$(cat "$SEC_HOME/.dsh/.credentials.yaml" 2>/dev/null)" 'cred-v1' '含凭证归档可还原凭证'

# --no-config 只导入 DSH_HOME
NC_HOME="$WORK/home-import-noconfig"
make_home "$NC_HOME"
HOME="$NC_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 --port 3999 >/dev/null 2>&1
HOME="$NC_HOME" "$NC_HOME/.local/bin/dshctl" import "$EXP_DIR/default.tgz" --yes --no-restart --no-config >/dev/null 2>&1
assert_contains 'DSH_SERVICE_PORT          = 3999' "$(HOME="$NC_HOME" "$NC_HOME/.local/bin/dshctl" config)" '--no-config 保留本机端口'

# 非法归档被拒绝
printf 'not a tarball\n' > "$EXP_DIR/bogus.tgz"
if HOME="$IMP_HOME" "$IMP_HOME/.local/bin/dshctl" import "$EXP_DIR/bogus.tgz" --yes >/dev/null 2>&1; then
	bad '非法归档应被拒绝'
else
	ok '非法归档被拒绝'
fi
if HOME="$IMP_HOME" "$IMP_HOME/.local/bin/dshctl" import >/dev/null 2>&1; then
	bad 'import 缺少归档参数应失败'
else
	ok 'import 缺少归档参数退出非 0'
fi

# --install-plugins 经 dsh plugin 重装 profile 插件
: > "$STUB_DSH_LOG"
IMP_PLUG_RC=0
IMP_PLUG="$(HOME="$IMP_HOME" "$IMP_HOME/.local/bin/dshctl" import "$EXP_DIR/default.tgz" --yes --no-restart --install-plugins 2>&1)" || IMP_PLUG_RC=$?
assert_eq "$IMP_PLUG_RC" '0' '--install-plugins 退出 0'
assert_contains '重装 profile' "$IMP_PLUG" '--install-plugins 触发插件重装'
assert_contains 'plugin --profile web install' "$(cat "$STUB_DSH_LOG")" '通过 dsh plugin 重装插件'

# ── 31. 国内镜像默认值与 --no-mirror ─────────────────────────────────────────
section '31. 国内镜像默认值与 --no-mirror'

# dry-run：HOME 里没有 nvm.sh 时才会走到「下载 nvm 安装脚本」这一步。
MIRROR_DRY_HOME="$WORK/home-mirror-dry"
make_home "$MIRROR_DRY_HOME"
rm -f "$MIRROR_DRY_HOME/.nvm/nvm.sh"
MIRROR_DRY="$(HOME="$MIRROR_DRY_HOME" bash "$ROOT/install.sh" --dry-run 2>&1)"
assert_contains 'https://gitee.com/mirrors/nvm/raw/v0.40.1/install.sh' "$MIRROR_DRY" '默认从 Gitee 镜像下载 nvm 安装脚本'
assert_contains '镜像     : 国内（npm https://registry.npmmirror.com）' "$MIRROR_DRY" '汇总标注国内镜像'

NOMIRROR_DRY="$(HOME="$MIRROR_DRY_HOME" bash "$ROOT/install.sh" --dry-run --no-mirror 2>&1)"
assert_contains 'https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh' "$NOMIRROR_DRY" '--no-mirror 切回 raw.githubusercontent'
assert_contains '镜像     : 官方源（--no-mirror）' "$NOMIRROR_DRY" '汇总标注官方源'

# 默认安装：镜像写入配置，并注入 npm / nvm（桩命令离线记录）。
MIRROR_HOME="$WORK/home-mirror"
make_home "$MIRROR_HOME"
: > "$STUB_NPM_ENV_LOG"
reset_nvm_log
HOME="$MIRROR_HOME" bash "$ROOT/install.sh" --no-service --dsh-version 0.1.0 >/dev/null 2>&1
MIRROR_CONF="$(HOME="$MIRROR_HOME" "$MIRROR_HOME/.local/bin/dshctl" config)"
assert_contains 'DSH_SERVICE_MIRROR        = 1' "$MIRROR_CONF" '配置记录国内镜像模式'
assert_contains 'DSH_SERVICE_NPM_REGISTRY  = https://registry.npmmirror.com' "$MIRROR_CONF" '配置记录 npmmirror registry'
assert_contains 'DSH_SERVICE_NODE_MIRROR   = https://npmmirror.com/mirrors/node' "$MIRROR_CONF" '配置记录 Node 镜像'
assert_contains 'registry https://registry.npmmirror.com' "$(cat "$STUB_NPM_ENV_LOG")" 'npm 子命令收到镜像 registry'
assert_contains 'node-mirror https://npmmirror.com/mirrors/node' "$(cat "$STUB_NVM_LOG")" 'nvm 收到 Node 镜像'

# dshctl upgrade --check 经配置复用镜像（npm view 也走 npmmirror）。
: > "$STUB_NPM_ENV_LOG"
HOME="$MIRROR_HOME" "$MIRROR_HOME/.local/bin/dshctl" upgrade --check >/dev/null 2>&1 || true
assert_contains 'registry https://registry.npmmirror.com' "$(cat "$STUB_NPM_ENV_LOG")" 'dshctl upgrade 复用镜像 registry'

# --no-mirror 安装：配置与 npm 都切回官方源。
NOMIRROR_HOME="$WORK/home-nomirror"
make_home "$NOMIRROR_HOME"
: > "$STUB_NPM_ENV_LOG"
HOME="$NOMIRROR_HOME" bash "$ROOT/install.sh" --no-service --no-mirror --dsh-version 0.1.0 >/dev/null 2>&1
NOMIRROR_CONF="$(HOME="$NOMIRROR_HOME" "$NOMIRROR_HOME/.local/bin/dshctl" config)"
assert_contains 'DSH_SERVICE_MIRROR        = 0' "$NOMIRROR_CONF" '--no-mirror 写入配置'
assert_contains 'DSH_SERVICE_NPM_REGISTRY  = https://registry.npmjs.org' "$NOMIRROR_CONF" '--no-mirror 使用 npmjs registry'
assert_contains 'registry https://registry.npmjs.org' "$(cat "$STUB_NPM_ENV_LOG")" '--no-mirror 下 npm 收到官方 registry'

# 已有官方配置时，--mirror 能连同 URL 一起切回国内镜像（不被配置里的旧 URL 抵消）。
HOME="$NOMIRROR_HOME" bash "$ROOT/install.sh" --no-service --mirror --dsh-version 0.1.0 >/dev/null 2>&1
assert_contains 'DSH_SERVICE_MIRROR        = 1' \
	"$(HOME="$NOMIRROR_HOME" "$NOMIRROR_HOME/.local/bin/dshctl" config)" '--mirror 从官方配置切回镜像'
assert_contains 'DSH_SERVICE_NPM_REGISTRY  = https://registry.npmmirror.com' \
	"$(HOME="$NOMIRROR_HOME" "$NOMIRROR_HOME/.local/bin/dshctl" config)" '--mirror 覆盖配置里的官方 registry'

# ── 汇总 ─────────────────────────────────────────────────────────────────────
printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
printf '\033[32m全部测试通过\033[0m\n'
