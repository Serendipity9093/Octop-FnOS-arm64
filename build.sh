#!/usr/bin/env bash
# =============================================================================
# build.sh — 为飞牛 fnOS (ARM64) 构建 OCTOP 原生安装包 (.fpk)
#
# 用法:
#   ./build.sh                       # 构建默认版本
#   OCTOP_VERSION=1.0.2 ./build.sh   # 构建指定版本
#   MIRROR=https://pypi.org/simple ./build.sh   # 指定 PyPI 源
#
# 前置条件:Linux x86_64 / WSL、bash、curl、python3、git、网络
#
# 产出:dist/Octop-fnos-native-arm64-<version>.fpk
#
# 原理:官方 CI 在 x86_64 运行器上执行 pip install,导致包内二进制全是 x86_64,
#       却在 manifest 里声明 platform=all。本脚本用 uv 的 --python-platform
#       交叉安装 aarch64 依赖,并声明 platform=arm。
# =============================================================================
set -euo pipefail

# ---------- 配置 ----------
OCTOP_VERSION="${OCTOP_VERSION:-1.0.1}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/TencentCloud/Octop.git}"
MIRROR="${MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"
PKG_NAME="${PKG_NAME:-Octop-fnos-native-arm64}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/.build"
UPSTREAM="$WORK/Octop"
SP="$UPSTREAM/fnos/native/app/site-packages"
OUT="$ROOT/dist"
LOCALWHEELS="$WORK/localwheels"

log()  { echo -e "\033[1;34m[build]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn ]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
log "检查前置条件…"
for c in curl git python3; do
  command -v "$c" >/dev/null || die "缺少命令:$c"
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' || die "需要 Python 3.9+"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ;;
  aarch64|arm64) warn "检测到 ARM64 主机。本脚本为交叉构建设计,在 ARM64 上直接构建亦可,但请确认 --python-platform 与目标一致。" ;;
  *) warn "未知主机架构 $ARCH,继续尝试交叉构建。" ;;
esac

# uv(用于交叉安装)
if ! command -v uv >/dev/null; then
  log "安装 uv…"
  python3 -m pip install --quiet --break-system-packages uv 2>/dev/null \
    || python3 -m pip install --quiet --user uv \
    || die "uv 安装失败,请手动安装:https://docs.astral.sh/uv/"
  export PATH="$HOME/.local/bin:$PATH"
fi
UV="$(command -v uv)"
log "uv:$($UV --version)"

mkdir -p "$WORK" "$OUT" "$LOCALWHEELS"

# ---------- 1. 克隆上游 ----------
if [ -d "$UPSTREAM/.git" ]; then
  log "复用已克隆的上游仓库:$UPSTREAM"
else
  log "克隆上游仓库(仅需一次)…"
  git clone --depth 1 "$UPSTREAM_REPO" "$UPSTREAM"
fi

# ---------- 2. 下载 octop wheel ----------
WHEEL="$WORK/octop-${OCTOP_VERSION}-py3-none-any.whl"
if [ -f "$WHEEL" ]; then
  log "复用已下载的 wheel:$WHEEL"
else
  log "下载 octop==${OCTOP_VERSION} wheel…"
  python3 -m pip download --no-deps -i "$MIRROR" -d "$WORK" "octop==${OCTOP_VERSION}"
  WHEEL="$(ls "$WORK"/octop-"${OCTOP_VERSION}"-*.whl 2>/dev/null | head -1 || true)"
fi
[ -f "$WHEEL" ] || die "未获取到 octop wheel"
python3 -c "
import zipfile,sys
z=zipfile.ZipFile('$WHEEL')
assert len(z.namelist())>100, 'wheel 似乎不完整'
print(f'  wheel 校验通过:{len(z.namelist())} 个文件')
"

# ---------- 3. 构建三个无预编译 wheel 的依赖 ----------
# oss2 / esdk-obs-python:纯 Python,在任意平台构建的 wheel 都是 py3-none-any
# crcmod:含 C 扩展但自带纯 Python 回退,用 CC=/bin/false 触发回退
log "构建本地通用 wheel(共 3 个)…"
build_local_wheel() {
  local name="$1" extra_env="${2:-}"
  local existing
  existing="$(ls "$LOCALWHEELS"/"${name}"-*.whl 2>/dev/null | head -1 || true)"
  if [ -n "$existing" ]; then
    log "  复用:$(basename "$existing")"
    return 0
  fi
  log "  构建:$name"
  local dl="$WORK/dl-$name"
  rm -rf "$dl"; mkdir -p "$dl"
  python3 -m pip download --no-deps --no-binary :all: -i "$MIRROR" -d "$dl" "$name" >/dev/null
  local src
  # 注意:glob 未匹配时 ls 会返回非零,在 set -o pipefail 下会静默终止脚本,
  # 因此必须 `|| true` 兜底(只取 tar.gz,不并列匹配 .zip)。
  src="$(ls "$dl"/*.tar.gz 2>/dev/null | head -1 || true)"
  [ -n "$src" ] || die "$name:未下载到源码包"
  local exdir="$WORK/src-$name"
  rm -rf "$exdir"; mkdir -p "$exdir"
  tar xzf "$src" -C "$exdir" 2>/dev/null || unzip -q "$src" -d "$exdir"
  local sub
  sub="$(find "$exdir" -maxdepth 1 -mindepth 1 -type d | head -1 || true)"
  [ -n "$sub" ] || sub="$exdir"
  local blog="$WORK/build-$name.log"
  # shellcheck disable=SC2086
  if ! env $extra_env "$UV" build --wheel --out-dir "$LOCALWHEELS" "$sub" > "$blog" 2>&1; then
    echo "---- $name 构建输出 ----" >&2
    tail -20 "$blog" >&2
    die "构建 $name 的 wheel 失败"
  fi
}

build_local_wheel "oss2"
build_local_wheel "esdk-obs-python"
build_local_wheel "crcmod" "CC=/bin/false CXX=/bin/false LDSHARED=/bin/false"

# 校验:本地 wheel 必须是 py3-none-any
for w in "$LOCALWHEELS"/*.whl; do
  python3 -c "
import zipfile
z=zipfile.ZipFile('$w')
wheel_meta=[n for n in z.namelist() if n.endswith('WHEEL')][0]
tags=[l for l in z.read(wheel_meta).decode().splitlines() if l.startswith('Tag:')]
assert any('none-any' in t for t in tags), f'$w 不是通用 wheel: {tags}'
" || die "$(basename "$w") 不是 py3-none-any"
done
log "本地 wheel 校验通过:$(ls "$LOCALWHEELS" 2>/dev/null | tr '\n' ' ' || true)"

# ---------- 4. 交叉安装全部依赖到 aarch64 ----------
log "提取 octop 的依赖清单(排除 evdev)…"
REQS="$WORK/requirements.txt"
python3 - "$WHEEL" "$REQS" <<'PY'
import sys, zipfile
wheel, out = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(wheel)
meta = [n for n in z.namelist() if n.endswith("METADATA")][0]
lines = z.read(meta).decode("utf-8", "replace").splitlines()
reqs = []
for l in lines:
    if not l.startswith("Requires-Dist:"):
        continue
    spec = l.split(":", 1)[1].strip()
    if "extra ==" in spec:      # 只取基础依赖,不含 extras
        continue
    reqs.append(spec)
with open(out, "w") as f:
    f.write("\n".join(reqs) + "\n")
print(f"  共 {len(reqs)} 个直接依赖")
PY

export VIRTUAL_ENV="$WORK/venv"
[ -d "$VIRTUAL_ENV" ] || "$UV" venv "$VIRTUAL_ENV" --python 3.12 >/dev/null 2>&1 \
  || "$UV" venv "$VIRTUAL_ENV" >/dev/null

log "解析完整依赖树(允许源码包,仅用于生成清单)…"
PINNED="$WORK/pinned.txt"
"$UV" pip install --dry-run \
  --python-platform aarch64-unknown-linux-gnu --python-version 3.12 \
  --index-url "$MIRROR" \
  -r "$REQS" "$LOCALWHEELS"/*.whl 2>&1 >/dev/null \
  | sed -n 's/^ + \([^ ]*\) @ file:\/\/\(.*\)$/\2/p; s/^ + \([A-Za-z0-9_.-]*==[0-9][^ ]*\)$/\1/p' \
  | sort -u | grep -v '^evdev==' > "$PINNED"

log "  解析出 $(wc -l < "$PINNED") 个包(已排除 evdev)"

log "交叉安装到 aarch64 side-packages…"
rm -rf "$SP"; mkdir -p "$SP"
# shellcheck disable=SC2046
"$UV" pip install \
  --python-platform aarch64-unknown-linux-gnu --python-version 3.12 \
  --target "$SP" --only-binary :all: --no-deps \
  --index-url "$MIRROR" \
  $(tr '\n' ' ' < "$PINNED")

# ---------- 5. 固定 mcp / langchain-mcp-adapters(上游 CI 要求) ----------
log "安装固定版本的 mcp / langchain-mcp-adapters…"
rm -rf "$SP/mcp" "$SP"/mcp-*.dist-info \
       "$SP/langchain_mcp_adapters" "$SP"/langchain_mcp_adapters-*.dist-info
PIN_DIR="$WORK/pinned-wheels"
rm -rf "$PIN_DIR"; mkdir -p "$PIN_DIR"
python3 -m pip download --no-deps -i "$MIRROR" -d "$PIN_DIR" \
  "mcp==1.28.1" "langchain-mcp-adapters==0.3.0" >/dev/null
for w in "$PIN_DIR"/*.whl; do
  python3 -m zipfile -e "$w" "$SP"
done

# ---------- 6. 安装 octop 本体 ----------
log "安装 octop 本体…"
"$UV" pip install \
  --python-platform aarch64-unknown-linux-gnu --python-version 3.12 \
  --target "$SP" --only-binary :all: --no-deps "$WHEEL"
# 上游做法:保留一份 wheel 在 site-packages 内
cp "$WHEEL" "$SP/octop.whl"

# ---------- 7. 架构自检 ----------
log "自检:确认 site-packages 内没有非 AArch64 的二进制…"
python3 - "$SP" <<'PY'
import os, struct, sys
sp = sys.argv[1]
bad, ok = [], 0
for root, _, files in os.walk(sp):
    for f in files:
        if not f.endswith(".so"):
            continue
        p = os.path.join(root, f)
        try:
            with open(p, "rb") as fh:
                head = fh.read(20)
            if head[:4] != b"\x7fELF":
                continue
            machine = struct.unpack_from("<H", head, 18)[0]
            if machine == 0xB7:
                ok += 1
            else:
                bad.append((os.path.relpath(p, sp), hex(machine)))
        except Exception:
            pass
print(f"  AArch64: {ok} 个")
if bad:
    for p, m in bad[:10]:
        print(f"  ✗ 非 AArch64 ({m}): {p}")
    sys.exit(1)
if ok == 0:
    print("  ✗ 未找到任何 ELF 二进制,构建可能异常")
    sys.exit(1)
print("  ✓ 全部为 AArch64")
PY

# ---------- 8. 修正 manifest ----------
log "修正 manifest:platform=all → platform=arm"
MANIFEST="$UPSTREAM/fnos/native/manifest"
# 兼容 "platform=all" 与其对齐写法 "platform              = all"
sed -i -E 's/^platform[[:space:]]*=[[:space:]]*all[[:space:]]*$/platform=arm/' "$MANIFEST"
grep -qE '^platform[[:space:]]*=[[:space:]]*arm' "$MANIFEST" \
  || die "manifest platform 字段改写失败,请检查 $MANIFEST"
log "  当前值:$(grep -E '^platform' "$MANIFEST")"

# ---------- 9. 打包 ----------
log "调用 fnpack 打包(会自动下载 fnpack 到 .verify/)…"
cd "$UPSTREAM"
FPK_NAME_PREFIX="$PKG_NAME" bash scripts/build-fpk.sh native

BUILT="$(ls "$UPSTREAM"/dist/${PKG_NAME}-native-"${OCTOP_VERSION}".fpk 2>/dev/null | head -1 || true)"
if [ -z "$BUILT" ]; then
  BUILT="$(ls -t "$UPSTREAM"/dist/*.fpk 2>/dev/null | head -1 || true)"
fi
[ -n "$BUILT" ] || die "未找到构建产物"

mv "$BUILT" "$OUT/"
# 统一为可预期的发布文件名(上游模板会插入 "-native-",这里规范为固定格式)
FINAL="$OUT/Octop-fnos-native-arm64-${OCTOP_VERSION}.fpk"
if [ "$OUT/$(basename "$BUILT")" != "$FINAL" ]; then
  mv "$OUT/$(basename "$BUILT")" "$FINAL"
fi

# 输出校验和
( cd "$OUT" && sha256sum "$(basename "$FINAL")" > "$(basename "$FINAL").sha256" )

log "=========================================="
log "构建完成 ✓"
log "  产物:$FINAL"
log "  大小:$(du -h "$FINAL" | cut -f1)"
log "  校验和:$(cat "$FINAL.sha256")"
log "=========================================="
log ""
log "安装方法:把 .fpk 传到 NAS → 飞牛应用中心 → 手动安装"
