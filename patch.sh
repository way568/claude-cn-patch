#!/bin/bash
# claude-cn-patch v2 —— 解锁 Claude Desktop 随包预置的简体中文界面
#
# 依赖：仅 macOS 自带工具（python3 + codesign）。无需 Node。
# 用法：bash patch.sh [副本App路径]   默认 /Applications/Claude-CN.app
# 原理（四步）：
#   ① 往 ion-dist 的 HTML 注入语言清单 meta（备用路径）
#   ② 装入官方中文词典（catalogs/ 里的 34,443 词条 webapp 词典 + 49 词条动态词典）
#   ③ 改 3 处 JS：词典目录/选择器清单/选择器渲染点追加 zh-Hans（按内容搜锚点，版本漂移会提示）
#   ④ 关闭 Electron asar 完整性校验 fuse（一个字节，绕开 plist 指纹+框架摘要两层校验）
#   最后 ad-hoc 重签名。原 App 永不被修改；备份在 ~/.claude-cn-patch-backups/。
# 回滚：删除副本 App 用回原版。
# 更新：官方更新覆盖后重跑本脚本；锚点漂移时脚本会逐项提示，关键项失败会明确警告。

set -euo pipefail

SRC_APP="${SRC_APP:-/Applications/Claude.app}"
APP="${1:-/Applications/Claude-CN.app}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUPS="$HOME/.claude-cn-patch-backups"
WORK=$(mktemp -d /tmp/claude-cn.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------- 0. 环境检查 ----------
[ -d "$SRC_APP" ] || { echo "❌ 未找到原 App：${SRC_APP}（可用 SRC_APP=/路径/Claude.app 指定）"; exit 1; }
python3 -c 'print(1)' >/dev/null 2>&1 || { echo "❌ 需要 python3。终端执行一次 xcode-select --install 安装命令行工具后重试。"; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "❌ 缺少 codesign（异常，macOS 应自带）"; exit 1; }
FREE_GB=$(df -g / | tail -1 | awk '{print $4}')
[ "${FREE_GB:-0}" -ge 3 ] || echo "⚠️ 磁盘剩余 ${FREE_GB}GB，建议 ≥3GB，继续尝试……"
if pgrep -f "$APP/Contents/MacOS/Claude" >/dev/null 2>&1; then
  echo "❌ $APP 正在运行。请先完全退出（菜单栏 Claude 图标 → Quit Claude），再重跑本脚本。"
  exit 1
fi

# ---------- 1. 准备副本 ----------
if [ ! -d "$APP" ]; then
  echo "→ 复制原 App 到 $APP"
  cp -R "$SRC_APP" "$APP"
fi
ASAR="$APP/Contents/Resources/ion-dist.asar"
FW="$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
mkdir -p "$BACKUPS"
cp "$ASAR" "$BACKUPS/ion-dist.$(date +%Y%m%d%H%M%S).asar"
echo "→ 已备份当前 ion-dist.asar"

# ---------- 2~4. 解包 / 注入 / 重打包（纯 python，逐文件哈希自检） ----------
echo "→ 解包、注入、重打包（约1-2分钟）"
python3 - "$ASAR" "$WORK" "$SCRIPT_DIR" <<'PYEOF'
import json, struct, os, sys, hashlib, shutil

ASAR, WORK, SCRIPT_DIR = sys.argv[1], sys.argv[2], sys.argv[3]
TREE = os.path.join(WORK, 'iondist')
BLOCK = 4 * 1024 * 1024

# ===== asar 读写（纯 python 实现）=====
def parse_header(path):
    with open(path, 'rb') as f:
        head = f.read(16)
        jl = struct.unpack('<I', head[12:16])[0]
        tree = json.loads(f.read(jl).decode('utf-8'))
    return tree, (16 + jl + 3) & ~3

def iter_files(node, prefix):
    for name, meta in (node.get('files') or {}).items():
        p = f"{prefix}/{name}" if prefix else name
        if 'offset' in meta:
            yield p, meta
        if 'files' in meta:
            if 'offset' in meta:
                raise SystemExit(f'❌ 不支持的格式：{p} 既是文件又是目录')
            yield from iter_files(meta, p)

def extract(asar, outdir):
    tree, ds = parse_header(asar)
    n = 0
    with open(asar, 'rb') as f:
        for rel, meta in iter_files(tree, ''):
            if meta.get('unpacked'):
                raise SystemExit(f'❌ 发现 unpacked 条目（{rel}），此版本脚本不支持')
            dst = os.path.join(outdir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            f.seek(ds + int(meta['offset']))
            open(dst, 'wb').write(f.read(meta['size']))
            if meta.get('executable'):
                os.chmod(dst, 0o755)
            n += 1
    return n

def integrity_of(data):
    blocks = [hashlib.sha256(data[i:i+BLOCK]).hexdigest() for i in range(0, len(data), BLOCK)]
    return {"algorithm": "SHA256", "hash": hashlib.sha256(data).hexdigest(),
            "blockSize": BLOCK, "blocks": blocks}

def pack(indir, outasar):
    blobs = []  # (entry_dict, data)
    def build(dirpath):
        files = {}
        for name in sorted(os.listdir(dirpath)):
            p = os.path.join(dirpath, name)
            if os.path.isdir(p):
                files[name] = build(p)
            else:
                data = open(p, 'rb').read()
                entry = {"size": len(data), "integrity": integrity_of(data)}
                if os.access(p, os.X_OK):
                    entry["executable"] = True
                files[name] = entry
                blobs.append((entry, data))
        return {"files": files}
    root = build(indir)
    pos = 0
    for entry, data in blobs:
        entry["offset"] = str(pos)
        pos += len(data)
    js = json.dumps(root, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    assert len(js) > 0 and pos == sum(e['size'] for e, _ in blobs)
    pad = (-len(js)) % 4
    with open(outasar, 'wb') as f:
        f.write(struct.pack('<IIII', 4, len(js) + 8 + pad, len(js) + 4 + pad, len(js)))
        f.write(js)
        f.write(b'\x00' * pad)
        for entry, data in blobs:
            f.write(data)
    return len(blobs)

def verify(outasar, indir):
    """逐文件重新解包比对哈希，确保打包无损"""
    tree, ds = parse_header(outasar)
    n = 0
    with open(outasar, 'rb') as f:
        for rel, meta in iter_files(tree, ''):
            src = os.path.join(indir, rel)
            if not os.path.isfile(src):
                raise SystemExit(f'❌ 自检失败：包内多出 {rel}')
            f.seek(ds + int(meta['offset']))
            got = f.read(meta['size'])
            if hashlib.sha256(got).hexdigest() != hashlib.sha256(open(src, 'rb').read()).hexdigest():
                raise SystemExit(f'❌ 自检失败：{rel} 内容不一致')
            n += 1
    return n

# ===== 解包 =====
nfiles = extract(ASAR, TREE)
print(f'  解包 {nfiles} 个文件')

# ===== 注入①：HTML 语言清单 meta（备用路径） =====
CATALOGS = ("en-US:1.1,de-DE:1.1,fr-FR:1.1,ko-KR:1.1,ja-JP:1.1,es-419:1.1,"
            "es-ES:1.1,it-IT:1.1,hi-IN:1.1,pt-BR:1.1,id-ID:1.1,zh-Hans:1.1")
META_I18N = ('<meta name="i18n-catalogs" '
             f'data-i18n-catalogs="{CATALOGS}" '
             'data-i18n-released="zh-Hans">')
META_FRAME = ('<meta name="frame-shell-i18n" '
              'data-shipped="en-US,zh-Hans" '
              'data-catalogs="en-US:1,zh-Hans:1" '
              'data-released="zh-Hans">')
import re
for name in ('index.html', 'frame-shell.html'):
    p = os.path.join(TREE, name)
    if not os.path.isfile(p):
        continue
    s = open(p, encoding='utf-8').read()
    added = []
    for marker, meta in (('data-i18n-released', META_I18N), ('<meta name="frame-shell-i18n"', META_FRAME)):
        if marker in s:
            continue
        m = re.search(r'<head[^>]*>', s)
        s = s[:m.end()] + meta + s[m.end():] if m else meta + s
        added.append(marker[:20])
    if added:
        open(p, 'w', encoding='utf-8').write(s)
    print(f'  {name}: 注入 {added or "已有，跳过"}')

# ===== 注入②：官方中文词典 =====
for src_name, dst_rel in (('zh-Hans-web.json', 'i18n/zh-Hans.json'),
                          ('zh-Hans-dynamic.json', 'i18n/dynamic/zh-Hans.json')):
    src = os.path.join(SCRIPT_DIR, 'catalogs', src_name)
    dst = os.path.join(TREE, dst_rel)
    if not os.path.isfile(src):
        print(f'  ⚠️ 词典缺失：catalogs/{src_name}（界面将退回英文）')
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    print(f'  词典装入 {dst_rel}（{len(json.load(open(src)))} 词条）')

# ===== 注入③：JS 语言清单（按内容全局搜锚点，防版本漂移） =====
PAIRS = [
    ('t&&e.push(t.slice(1))}return e}',
     't&&e.push(t.slice(1))}return e.concat([["zh-Hans","7ee95791203a","684b0c92fef0"]])}',
     'ON()词典目录'),
    ('dataset.i18nReleased;return e?e.split(","):[]}',
     'dataset.i18nReleased;return e?e.split(",").concat(["zh-Hans"]):["zh-Hans"]}',
     'H()选择器清单'),
    ('let r=v(t),i;',
     'let r=[...(v(t)||[]),"zh-Hans"],i;',
     '选择器渲染点(关键)'),
]
jsdir = os.path.join(TREE, 'assets', 'v1')
cand = [os.path.join(jsdir, f) for f in os.listdir(jsdir)] if os.path.isdir(jsdir) else []
critical_ok = False
for old, new, label in PAIRS:
    done, hits = False, []
    for p in cand:
        try:
            s = open(p, encoding='utf-8').read()
        except Exception:
            continue
        if new in s:
            done = True; break
        if old in s:
            hits.append((p, s))
    if done:
        print(f'  {label}: 已打过，跳过');
        if '关键' in label: critical_ok = True
        continue
    if len(hits) != 1:
        print(f'  ⚠️ {label}: 锚点漂移(命中{len(hits)}个文件)——跳过，需人工适配')
        continue
    p, s = hits[0]
    open(p, 'w', encoding='utf-8').write(s.replace(old, new))
    print(f'  {label}: ✅ 已追加 zh-Hans')
    if '关键' in label: critical_ok = True

# ===== 重打包 + 自检 =====
OUT = os.path.join(WORK, 'ion-dist.patched.asar')
pack(TREE, OUT)
nv = verify(OUT, TREE)
n_tree = sum(len(fs) for _, _, fs in os.walk(TREE))
if nv != n_tree:
    raise SystemExit(f'❌ 自检文件数不一致：目录 {n_tree} → 包内 {nv}')
print(f'  ✅ 重打包完成，逐文件哈希自检通过（{nv} 个文件）')
if not critical_ok:
    print('  ⚠️⚠️ 关键补丁(选择器渲染点)未生效——界面语言菜单可能不会出现中文，请反馈给维护者')

# ===== 计算新 asar 的 JSON 头哈希（供 plist 指纹备用） =====
with open(OUT, 'rb') as f:
    jl = struct.unpack('<I', f.read(16)[12:16])[0]
    f.seek(16)
    h = hashlib.sha256(f.read(jl)).hexdigest()
open(os.path.join(WORK, 'newhash.txt'), 'w').write(h)
PYEOF

# ---------- 5. 原子替换 ----------
cp "$WORK/ion-dist.patched.asar" "$ASAR.new" && mv "$ASAR.new" "$ASAR"
echo "→ 已替换 ion-dist.asar"

# ---------- 6. plist 指纹同步（fuse 已关，此步为双保险） ----------
NEWHASH=$(cat "$WORK/newhash.txt")
/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/ion-dist.asar:hash $NEWHASH" "$APP/Contents/Info.plist" 2>/dev/null \
  && echo "→ plist 指纹已同步" || echo "→ plist 指纹同步跳过（fuse 已关闭，不影响）"

# ---------- 7. 关闭 asar 完整性校验 fuse（关键） ----------
python3 - "$FW" <<'PYEOF'
import sys
fw = sys.argv[1]
d = bytearray(open(fw, 'rb').read())
MAGIC = b'dL7pKGdnNz796PbbjQWN'
pos, flipped = 0, 0
while True:
    i = d.find(MAGIC, pos)
    if i < 0: break
    bmp = i + 34
    if bmp + 9 <= len(d) and all(chr(c) in '01' for c in d[bmp:bmp+9]):
        if d[bmp+4] == ord('1'):
            d[bmp+4] = ord('0')
            flipped += 1
    pos = i + 1
if not flipped:
    print('❌ 未找到可关闭的 fuse 位图（App 结构可能已变）'); sys.exit(1)
open(fw, 'wb').write(bytes(d))
print(f'→ ✅ AsarIntegrity fuse 已关闭（{flipped} 处）')
PYEOF

# ---------- 8. 清属性 + 重签名 ----------
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null
codesign --verify --deep "$APP" 2>/dev/null && echo "→ ✅ 签名校验通过" || echo "⚠️ 签名校验失败（App 仍可能可用，遇到「已损坏」就重跑一次）"

echo ""
echo "✅ 补丁完成：$APP"
echo "   使用：完全退出原 Claude（菜单栏图标 → Quit），打开 ${APP}，"
echo "   在语言菜单(Choose your language)选「中文（简体）」一次即永久生效。"
echo "   提示：副本可能要求重填一次模型网关凭据（换了签名，属正常）。"
