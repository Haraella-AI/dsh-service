#!/usr/bin/env bash
# =============================================================================
#  scripts/bump-version.sh —— dsh-service 版本号统一维护
#
#  版本号只有一个来源：install.sh 的 INSTALLER_VERSION 与内嵌 dshctl 的
#  DSHCTL_VERSION（两者必须同值），README 顶部的版本行跟随显示。导出归档
#  manifest 里的 DSHCTL_VERSION 由内嵌 dshctl 运行时生成，所以 bump 之后无需
#  单独改动——`--check` 会导出内嵌副本复核这一点。
#
#  用法：
#    bash scripts/bump-version.sh patch|minor|major   递增版本号
#    bash scripts/bump-version.sh 0.2.0               指定版本号（默认拒绝回退）
#    bash scripts/bump-version.sh --check             只校验各处的版本号是否一致
#
#  选项：
#    --dry-run        只打印将要做的事，不写文件
#    --stage          写完后 git add install.sh README.md
#    --force          允许写一个比当前更低的版本号（默认拒绝）
#    --root DIR       仓库根目录（默认脚本上一级；也可用 DSH_SERVICE_ROOT）
#    -h, --help       显示本帮助
#
#  退出码：0 成功；1 用法/校验/写入失败
# =============================================================================
set -Eeuo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# die：打印错误并退出 1。
die() {
	printf '错误：%s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
dsh-service 版本号统一维护

用法:
  bash scripts/bump-version.sh patch|minor|major   递增版本号
  bash scripts/bump-version.sh 0.2.0               指定版本号（默认拒绝回退）
  bash scripts/bump-version.sh --check             只校验各处的版本号是否一致

选项:
  --dry-run        只打印将要做的事，不写文件
  --stage          写完后 git add install.sh README.md
  --force          允许写一个比当前更低的版本号（默认拒绝）
  --root DIR       仓库根目录（默认脚本上一级；也可用 DSH_SERVICE_ROOT）
  -h, --help       显示本帮助

版本号来源:
  install.sh 的 INSTALLER_VERSION 与内嵌 dshctl 的 DSHCTL_VERSION（同源同值），
  README.md 顶部的版本行跟随显示；导出归档 manifest 的 DSHCTL_VERSION 由内嵌
  dshctl 运行时生成，因此不需要单独维护。
EOF
}

# ── 参数解析 ─────────────────────────────────────────────────────────────────
ROOT="${DSH_SERVICE_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
TARGET=''
CHECK=0
DRY_RUN=0
STAGE=0
FORCE=0

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK=1; shift ;;
		--dry-run|-n) DRY_RUN=1; shift ;;
		--stage) STAGE=1; shift ;;
		--force) FORCE=1; shift ;;
		--root) ROOT="${2:?--root 需要一个目录}"; shift 2 ;;
		--root=*) ROOT="${1#*=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) usage >&2; die "未知选项: $1" ;;
		*)
			[ -z "$TARGET" ] || die "只接受一个版本参数（已给出 '$TARGET' 和 '$1'）"
			TARGET="$1"
			shift
			;;
	esac
done

[ -d "$ROOT" ] || die "仓库根目录不存在: $ROOT"
ROOT="$(cd -- "$ROOT" && pwd)"
INSTALL_SH="$ROOT/install.sh"
README_FILE="$ROOT/README.md"

[ -f "$INSTALL_SH" ] || die "找不到 $INSTALL_SH"
[ -f "$README_FILE" ] || die "找不到 $README_FILE"

if [ "$CHECK" = 1 ] && [ -n "$TARGET" ]; then
	usage >&2
	die "--check 不能与版本参数同时使用"
fi
if [ "$CHECK" != 1 ] && [ -z "$TARGET" ]; then
	usage >&2
	die "缺少版本参数（patch|minor|major 或 X.Y.Z）"
fi

# ── 读取与校验 ───────────────────────────────────────────────────────────────
# 用 awk 而不是 sed|head：既避免 pipefail 下的 SIGPIPE，也保证只取第一处匹配。

file_installer_version() {
	awk '
		/^INSTALLER_VERSION="/ {
			v = $0
			sub(/^INSTALLER_VERSION="/, "", v)
			sub(/"$/, "", v)
			print v
			exit
		}
	' "$1"
}

file_dshctl_version() {
	awk '
		/^DSHCTL_VERSION="/ {
			v = $0
			sub(/^DSHCTL_VERSION="/, "", v)
			sub(/"$/, "", v)
			print v
			exit
		}
	' "$1"
}

file_readme_version() {
	awk '
		/^当前版本：\*\*v/ {
			v = $0
			sub(/^当前版本：\*\*v/, "", v)
			sub(/\*\*.*$/, "", v)
			print v
			exit
		}
	' "$1"
}

is_semver() {
	[[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
}

# split_version：把 $1 拆成 V_MAJOR / V_MINOR / V_PATCH / V_PRE（调用前先 is_semver）。
split_version() {
	local core="$1" pre=''
	case "$core" in
		*-*) pre="${core#*-}"; core="${core%%-*}" ;;
	esac
	IFS=. read -r V_MAJOR V_MINOR V_PATCH <<<"$core"
	V_PRE="$pre"
}

# version_gt A B：A 是否严格大于 B（预发布号被视为小于同号的正式版）。
version_gt() {
	local a="$1" b="$2"
	local am an ap apre bm bn bp bpre
	[ "$a" = "$b" ] && return 1
	split_version "$a"; am="$V_MAJOR"; an="$V_MINOR"; ap="$V_PATCH"; apre="$V_PRE"
	split_version "$b"; bm="$V_MAJOR"; bn="$V_MINOR"; bp="$V_PATCH"; bpre="$V_PRE"
	if [ "$am" -ne "$bm" ]; then [ "$am" -gt "$bm" ]; return; fi
	if [ "$an" -ne "$bn" ]; then [ "$an" -gt "$bn" ]; return; fi
	if [ "$ap" -ne "$bp" ]; then [ "$ap" -gt "$bp" ]; return; fi
	if [ -z "$apre" ] && [ -n "$bpre" ]; then return 0; fi
	if [ -n "$apre" ] && [ -z "$bpre" ]; then return 1; fi
	[ "$apre" \> "$bpre" ]
}

# next_version CUR KIND：按 KIND（major|minor|patch）算出下一个版本。
# 预发布版（如 0.2.0-rc.1）的 patch 视为把它转正为 0.2.0。
next_version() {
	local cur="$1" kind="$2"
	split_version "$cur"
	case "$kind" in
		major) printf '%s.0.0\n' "$((V_MAJOR + 1))" ;;
		minor) printf '%s.%s.0\n' "$V_MAJOR" "$((V_MINOR + 1))" ;;
		patch)
			if [ -n "$V_PRE" ]; then
				printf '%s.%s.%s\n' "$V_MAJOR" "$V_MINOR" "$V_PATCH"
			else
				printf '%s.%s.%s\n' "$V_MAJOR" "$V_MINOR" "$((V_PATCH + 1))"
			fi
			;;
		*) die "未知的递增类型: $kind" ;;
	esac
}

# replace_in_file FILE SED_SCRIPT：同目录临时文件 + 保留权限地整体替换。
replace_in_file() {
	local file="$1" script="$2" tmp
	tmp="$(mktemp -- "${file}.bump.XXXXXX")" || die "无法在 $(dirname -- "$file") 下创建临时文件"
	if ! sed -- "$script" "$file" >"$tmp"; then
		rm -f -- "$tmp"
		die "写入失败: $file"
	fi
	chmod --reference="$file" "$tmp" 2>/dev/null || true
	mv -- "$tmp" "$file" || die "替换失败: $file"
}

# ── --check：各处版本号一致性 ─────────────────────────────────────────────────
do_check() {
	local iv dv rv printed rc=0
	iv="$(file_installer_version "$INSTALL_SH")"
	dv="$(file_dshctl_version "$INSTALL_SH")"
	rv="$(file_readme_version "$README_FILE")"

	if [ -z "$iv" ]; then
		printf 'FAIL install.sh 中找不到 INSTALLER_VERSION\n' >&2
		rc=1
	fi
	if [ -z "$dv" ]; then
		printf 'FAIL install.sh 中找不到 DSHCTL_VERSION\n' >&2
		rc=1
	fi
	if [ -z "$rv" ]; then
		printf 'FAIL README.md 中找不到「当前版本：**vX.Y.Z**」版本行\n' >&2
		rc=1
	fi
	if [ "$rc" -eq 0 ] && [ "$iv" != "$dv" ]; then
		printf 'FAIL INSTALLER_VERSION（%s）与 DSHCTL_VERSION（%s）不一致\n' "$iv" "$dv" >&2
		rc=1
	fi
	if [ "$rc" -eq 0 ] && [ "$iv" != "$rv" ]; then
		printf 'FAIL README 版本行（%s）与 install.sh（%s）不一致\n' "$rv" "$iv" >&2
		rc=1
	fi
	if [ "$rc" -eq 0 ] && ! is_semver "$iv"; then
		printf 'FAIL 版本号不是合法 semver: %s\n' "$iv" >&2
		rc=1
	fi

	# 内嵌 dshctl 是导出归档版本字段的唯一来源：导出一次复核它确实同步。
	# 整体捕获输出后再匹配：awk 命中即退出，直接管道会因 SIGPIPE + pipefail
	# 把「版本一致」误判成失败。
	if [ "$rc" -eq 0 ]; then
		printed="$(bash "$INSTALL_SH" --print-dshctl 2>/dev/null)" || printed=''
		printed="$(awk '
			/^DSHCTL_VERSION="/ {
				v = $0
				sub(/^DSHCTL_VERSION="/, "", v)
				sub(/"$/, "", v)
				print v
				exit
			}
		' <<<"$printed")"
		if [ "$printed" != "$iv" ]; then
			printf 'FAIL 内嵌 dshctl 版本（%s）与 install.sh（%s）不一致\n' "${printed:-读取失败}" "$iv" >&2
			rc=1
		fi
	fi

	if [ "$rc" -ne 0 ]; then
		printf '版本号校验未通过\n' >&2
		exit 1
	fi
	printf '版本号一致：v%s（install.sh / 内嵌 dshctl / README）\n' "$iv"
	return 0
}

if [ "$CHECK" = 1 ]; then
	do_check
	exit 0
fi

# ── bump：解析目标版本 ───────────────────────────────────────────────────────
CUR="$(file_installer_version "$INSTALL_SH")"
[ -n "$CUR" ] || die "无法从 $INSTALL_SH 读取 INSTALLER_VERSION"
is_semver "$CUR" || die "当前版本号不是合法 semver: $CUR"

case "$TARGET" in
	major|minor|patch) NEW="$(next_version "$CUR" "$TARGET")" ;;
	*) NEW="$TARGET" ;;
esac
is_semver "$NEW" || die "目标版本号不是合法 semver: $NEW"

if [ "$NEW" = "$CUR" ] && [ "$FORCE" != 1 ]; then
	die "目标版本号与当前版本号相同（v$CUR）；如确需重写请加 --force"
fi
if [ "$NEW" != "$CUR" ] && ! version_gt "$NEW" "$CUR" && [ "$FORCE" != 1 ]; then
	die "目标版本 v$NEW 低于当前 v$CUR；如确需回退请加 --force"
fi

# README 版本行必须存在，否则 sed 会静默不替换。
grep -q '^当前版本：\*\*v' "$README_FILE" || die "README.md 缺少「当前版本：**vX.Y.Z**」版本行"

# install.sh 里两处赋值都必须唯一，避免误改到注释或清单输出。
[ "$(grep -c '^INSTALLER_VERSION="' "$INSTALL_SH" || true)" = 1 ] \
	|| die "install.sh 中 INSTALLER_VERSION 赋值不唯一"
[ "$(grep -c '^DSHCTL_VERSION="' "$INSTALL_SH" || true)" = 1 ] \
	|| die "install.sh 中 DSHCTL_VERSION 赋值不唯一"

if [ "$DRY_RUN" = 1 ]; then
	printf 'dry-run：版本 v%s -> v%s\n' "$CUR" "$NEW"
	printf '  待改  %s（INSTALLER_VERSION、DSHCTL_VERSION）\n' "$INSTALL_SH"
	printf '  待改  %s（版本行）\n' "$README_FILE"
	[ "$STAGE" = 1 ] && printf '  待执行 git add install.sh README.md\n'
	printf '未写入任何文件\n'
	exit 0
fi

replace_in_file "$INSTALL_SH" "s|^INSTALLER_VERSION=\"[^\"]*\"\$|INSTALLER_VERSION=\"$NEW\"|"
replace_in_file "$INSTALL_SH" "s|^DSHCTL_VERSION=\"[^\"]*\"\$|DSHCTL_VERSION=\"$NEW\"|"
replace_in_file "$README_FILE" "s|^当前版本：\*\*v[^ *]*\*\*|当前版本：**v$NEW**|"

printf '版本 v%s -> v%s\n' "$CUR" "$NEW"
printf '  已改  %s\n' "$INSTALL_SH"
printf '  已改  %s\n' "$README_FILE"

if [ "$STAGE" = 1 ]; then
	if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$ROOT" add -- install.sh README.md
		printf '  已暂存 install.sh README.md\n'
	else
		printf '警告：%s 不是 Git 仓库，跳过 --stage\n' "$ROOT" >&2
	fi
fi

do_check
