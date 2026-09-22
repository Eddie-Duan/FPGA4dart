# -*- coding: utf-8 -*-
"""to_simplified_gbk.py -- 把工程内代码档的中文由「繁体」转成「简体」，并统一存成 GBK 编码

用法（在专案根目录执行）：
    python tools\\to_simplified_gbk.py                       # dry-run：只产生报告，不改档
    python tools\\to_simplified_gbk.py --apply               # 实际写入
    python tools\\to_simplified_gbk.py --apply --also-tools  # 连 tools/*.py、.gitignore 一起转文字

设计要点：
    * 逐档自动侦测编码（先试 UTF-8，失败再试 GBK）。
    * 用 zhconv 做繁 -> 简（含词汇级转换，例如「灯条」「门限」）。
    * rtl/ sim/ prj/ 底下的档案一律写回 **GBK**（Vivado 在中文 Windows 用 ANSI）。
    * tools/*.py、.gitignore 只转文字、**保持原编码**（GBK 的 Python 原始码会直译失败）。
    * 写入前先备份到 %TEMP%\\fpga4dart_zh_backup，写入后立刻读回位元组比对，不一致立刻还原。
    * 输出报告写到 %TEMP%\\fpga_zh_convert_report.txt（UTF-8）。
"""
import argparse
import difflib
import os
import re
import shutil
import sys
import tempfile

try:
    from zhconv import convert
except ImportError:
    sys.stderr.write('please install zhconv first: pip install zhconv\n')
    raise SystemExit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKUP_DIR = os.path.join(tempfile.gettempdir(), 'fpga4dart_zh_backup')
REPORT = os.path.join(tempfile.gettempdir(), 'fpga_zh_convert_report.txt')

GBK_TOP_DIRS = ('rtl', 'sim', 'prj')
CODE_SUBDIRS = ('rtl', 'sim', 'prj')
CODE_EXTS = ('.v', '.vh', '.sv', '.xdc', '.ucf', '.tcl')

# zhconv 是「字级 + 常用词」转换，仍会留下一些台湾用语。
# 这里再补一层大陆常用术语，让注释和 README 的简体段落用词一致。
# 只列确定安全的词（不会误伤“参考资料”之类的常见搭配）。
TERM_MAP = [
    ('记忆体', '内存'),
    ('暂存器', '寄存器'),
    ('汇流排', '总线'),
    ('解析度', '分辨率'),
    ('使用者', '用户'),
    ('模组', '模块'),
    ('除错', '调试'),
    ('门槛', '阈值'),
    ('萤幕', '屏幕'),
    ('讯号', '信号'),
    ('资讯', '信息'),
    ('预设', '默认'),
    ('档案', '文件'),
    ('影像', '图像'),
    ('阵列', '数组'),
    ('介面', '接口'),
    ('位址', '地址'),
    ('时脉', '时钟'),
    ('遮罩', '掩膜'),
    ('脚位', '引脚'),
    ('连结', '连接'),
    ('范本', '模板'),
    ('韧体', '固件'),
    ('硬体', '硬件'),
    ('软体', '软件'),
    ('视讯', '视频'),
    ('撷取', '采集'),
    ('侦测', '检测'),
    ('致能', '使能'),
    ('实作', '实现'),
    ('座标', '坐标'),
]

# 「资料」在对岸=resource、在大陆=data，不能无差别替换：
# 正点原子例程的版权宣告有「免费获取...资料」这种用法，碰到就跳过。
GUARDED_MAP = [('资料', '数据')]
GUARD_STR = '免费获取'

# TERM_RE 只含无条件词表；GUARDED_MAP 由 apply_guarded_terms 单独处理
TERM_RE = re.compile('|'.join(re.escape(k) for k, _ in
                              sorted(TERM_MAP, key=lambda kv: -len(kv[0]))))
TERM_DICT = dict(TERM_MAP)
TERM_LABEL = dict(TERM_MAP + GUARDED_MAP)   # 报告用（含条件词表）

# 不转换自己（否则自己的 TERM_MAP 字面值会被改掉），也不动本次任务的临时扫描脚本
EXCLUDE = {
    'tools/to_simplified_gbk.py',
    'tools/scan_zh.py',
}


def decode(b):
    """回传 (text, encoding)；无法解码回传 (None, None)。"""
    try:
        return b.decode('utf-8'), 'utf-8'
    except UnicodeDecodeError:
        pass
    try:
        return b.decode('gbk'), 'gbk'
    except UnicodeDecodeError:
        return None, None


def collect(also_tools):
    files = []
    for sub in CODE_SUBDIRS:
        base = os.path.join(ROOT, sub)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames
                           if d not in ('xsim.dir', 'webtalk', '__pycache__')]
            for fn in filenames:
                if fn.lower().endswith(CODE_EXTS):
                    files.append(os.path.join(dirpath, fn))
    if also_tools:
        tdir = os.path.join(ROOT, 'tools')
        if os.path.isdir(tdir):
            for fn in sorted(os.listdir(tdir)):
                if fn.lower().endswith('.py'):
                    files.append(os.path.join(tdir, fn))
        gi = os.path.join(ROOT, '.gitignore')
        if os.path.isfile(gi):
            files.append(gi)
    keep = []
    for p in sorted(set(files)):
        rel = os.path.relpath(p, ROOT).replace(os.sep, '/')
        if rel not in EXCLUDE:
            keep.append(p)
    return keep


def han_count(t):
    return sum(1 for c in t if '\u4e00' <= c <= '\u9fff')


def changed_chars(a, b):
    """用 difflib 算真正被改动的字数（避免长度变化导致 zip 对不上）。"""
    n = 0
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != 'equal':
            n += max(i2 - i1, j2 - j1)
    return n


def apply_terms(text, counter):
    def repl(m):
        key = m.group(0)
        counter[key] = counter.get(key, 0) + 1
        return TERM_DICT[key]
    return TERM_RE.sub(repl, text)


def apply_guarded_terms(text, counter):
    """只对「没有厂商版权宣告」的档案做 资料 -> 数据（对岸 resource/data 区分）。"""
    if GUARD_STR in text:
        return text
    for k, v in GUARDED_MAP:
        n = text.count(k)
        if n:
            counter[k] = counter.get(k, 0) + n
            text = text.replace(k, v)
    return text


def target_encoding(rel):
    """回传要写回的编码名称；None 表示保持原编码。"""
    top = rel.replace('\\', '/').split('/')[0]
    return 'gbk' if top in GBK_TOP_DIRS else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--apply', action='store_true', help='actually write files')
    ap.add_argument('--also-tools', action='store_true',
                    help='also convert tools/*.py and .gitignore text (keep their encoding)')
    args = ap.parse_args()

    lines = []
    lines.append('mode      : %s' % ('APPLY (writing files)' if args.apply else 'DRY-RUN (no change)'))
    lines.append('also_tools: %s' % args.also_tools)
    lines.append('')

    table = []
    details = []
    problems = []
    term_used = {}
    n_written = 0

    for p in collect(args.also_tools):
        rel = os.path.relpath(p, ROOT)
        raw = open(p, 'rb').read()
        text, enc = decode(raw)
        if text is None:
            problems.append('%s : cannot decode as UTF-8 or GBK -> SKIPPED' % rel)
            continue

        han = han_count(text)
        if han == 0:
            continue

        new = apply_terms(convert(text, 'zh-cn'), term_used)
        new = apply_guarded_terms(new, term_used)
        if new == text:
            table.append((rel, enc, han, 0, 'already simplified -> SKIPPED'))
            continue

        dst_enc = target_encoding(rel) or enc
        try:
            new_bytes = new.encode(dst_enc)
        except UnicodeEncodeError as e:
            bad = new[e.start:e.end]
            problems.append('%s : cannot encode %r to %s -> SKIPPED' % (rel, bad, dst_enc))
            continue

        # 位元组层面没有变化（例如只有 \r\n 之类）就不用写
        if new_bytes == raw:
            table.append((rel, enc, han, 0, 'no byte change -> SKIPPED'))
            continue

        nchg = changed_chars(text, new)
        table.append((rel, enc, han, nchg, 'convert -> %s' % dst_enc.upper()))

        # 逐行差异预览
        buf = []
        for i, (a, b) in enumerate(zip(text.splitlines(), new.splitlines()), 1):
            if a != b and len(buf) < 6:
                buf.append('    L%-5d - %s' % (i, a.rstrip()[:110]))
                buf.append('           + %s' % b.rstrip()[:110])
        details.append('--- %s (%s -> %s, %d chars changed)' % (rel, enc, dst_enc, nchg))
        details.extend(buf if buf else ['    (only encoding changes)'])
        details.append('')

        if args.apply:
            bak = os.path.join(BACKUP_DIR, rel)
            os.makedirs(os.path.dirname(bak), exist_ok=True)
            shutil.copy2(p, bak)
            with open(p, 'wb') as f:
                f.write(new_bytes)
            back = open(p, 'rb').read()
            if back != new_bytes:
                shutil.copy2(bak, p)
                problems.append('%s : read-back mismatch -> RESTORED from backup' % rel)
            else:
                n_written += 1

    lines.append('%-46s %-6s %6s %7s  %s' % ('file', 'enc', 'han', 'chg', 'action'))
    for rel, enc, han, chg, act in table:
        lines.append('%-46s %-6s %6d %7d  %s' % (rel, enc, han, chg, act))
    lines.append('')
    lines.append('=== terminology applied (Taiwan -> Mainland) ===')
    if term_used:
        for k, v in sorted(term_used.items(), key=lambda kv: -kv[1]):
            lines.append('  %s -> %s   x%d' % (k, TERM_LABEL[k], v))
    else:
        lines.append('  (none)')
    lines.append('')
    lines.append('=== preview of changes ===')
    lines.extend(details)
    if problems:
        lines.append('=== problems ===')
        lines.extend(problems)
    lines.append('')
    lines.append('files to convert: %d, written: %d, problems: %d'
                 % (sum(1 for r in table if r[3] > 0), n_written, len(problems)))
    if args.apply:
        lines.append('backup dir: %s' % BACKUP_DIR)

    with open(REPORT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

    print('report : %s' % REPORT)
    print('files to convert: %d  written: %d  problems: %d'
          % (sum(1 for r in table if r[3] > 0), n_written, len(problems)))


if __name__ == '__main__':
    main()
