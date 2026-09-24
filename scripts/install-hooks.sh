#!/usr/bin/env bash
# =============================================================================
#  scripts/install-hooks.sh —— 启用/停用仓库自带的 Git 钩子
#
#  把 core.hooksPath 指向 .githooks，使 pre-commit 钩子生效（改动 install.sh
#  未 bump 版本号时自动递增 patch）。只改本仓库的本地 git 配置，不影响全局。
#
#  用法：
#    bash scripts/install-hooks.sh            启用（默认）
#    bash scripts/install-hooks.sh --uninstall 停用
#    bash scripts/install-hooks.sh --status    查看当前状态
# =============================================================================
set -Eeuo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DSH_SERVICE_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"

die() {
	printf '错误：%s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
dsh-service Git 钩子管理

用法:
  bash scripts/install-hooks.sh            启用 .githooks（core.hooksPath=.githooks）
  bash scripts/install-hooks.sh --uninstall 停用（unset core.hooksPath）
  bash scripts/install-hooks.sh --status    查看当前状态
EOF
}

MODE=enable
while [ $# -gt 0 ]; do
	case "$1" in
		--uninstall) MODE=uninstall; shift ;;
		--status) MODE=status; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; die "未知选项: $1" ;;
	esac
done

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT 不是 Git 仓库"
HOOKS_DIR="$ROOT/.githooks"
[ -d "$HOOKS_DIR" ] || die "找不到钩子目录: $HOOKS_DIR"

case "$MODE" in
	enable)
		# 钩子由 git 直接执行，必须有可执行位（Windows 检出可能丢失）。
		chmod +x "$HOOKS_DIR"/* 2>/dev/null || true
		git -C "$ROOT" config --local core.hooksPath .githooks
		printf '已启用仓库钩子：core.hooksPath=%s\n' "$(git -C "$ROOT" config --local core.hooksPath)"
		printf '改动 install.sh 提交时会自动递增版本号；跳过用 git commit --no-verify\n'
		;;
	uninstall)
		git -C "$ROOT" config --local --unset core.hooksPath 2>/dev/null || true
		printf '已停用仓库钩子（core.hooksPath 未设置）\n'
		;;
	status)
		current="$(git -C "$ROOT" config --local core.hooksPath 2>/dev/null || true)"
		if [ "$current" = '.githooks' ]; then
			printf '钩子已启用：core.hooksPath=%s\n' "$current"
		else
			printf '钩子未启用（core.hooksPath=%s）\n' "${current:-未设置}"
			exit 1
		fi
		;;
esac
