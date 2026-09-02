#!/usr/bin/env python3
"""比对两份 Swift 源码的记号流，用来证明一次改动「只改了排版」。

用途：重排既有文件时，构建通过和测试全绿都无法排除「手滑改了逻辑」。
这个脚本去掉注释、折叠字面量之外的空白，再把不影响记号边界的空格也去掉，
两份只在换行、缩进、注释上不同的源码，输出必须逐字相同。

字面量整段保留不参与折叠。多行字符串的缩进变化会被如实报成差异——
Swift 按结束分隔符的缩进剥离前导空白，所以那种差异需要另行用编译器
核对真实字符串值，不能靠这个脚本下结论。

    python3 Scripts/swift-token-diff.py 改前.swift 改后.swift
"""

import sys, re

def normalize(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # 行注释
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            out.append(" ")
            continue
        # 块注释（Swift 可嵌套）
        if src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i): depth += 1; i += 2
                elif src.startswith("*/", i): depth -= 1; i += 2
                else: i += 1
            out.append(" ")
            continue
        # 原始字符串 #"..."# / #"""..."""#
        m = re.match(r'(#+)("""|")', src[i:])
        if m:
            hashes, quote = m.group(1), m.group(2)
            close = quote + hashes
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            out.append(src[i:j]); i = j
            continue
        # 多行字符串
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(src[i:j]); i = j
            continue
        # 普通字符串
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\": j += 2; continue
                if src[j] == '"': j += 1; break
                j += 1
            out.append(src[i:j]); i = j
            continue
        if c.isspace():
            out.append(" ")
            while i < n and src[i].isspace(): i += 1
            continue
        out.append(c); i += 1
    # 只折叠字面量之外的空白：字面量整段用占位符换出去，折叠完再换回来。
    parts, guarded = [], []
    for piece in out:
        if piece.startswith('"') or piece.startswith("#"):
            guarded.append(piece)
            parts.append(f"\x00{len(guarded) - 1}\x00")
        else:
            parts.append(piece)
    collapsed = re.sub(r" +", " ", "".join(parts)).strip()
    return re.sub(r"\x00(\d+)\x00", lambda m: guarded[int(m.group(1))], collapsed)

# --- 第二遍：只保留「不加就会粘成另一个记号」的空格 ---
WORD = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$")
# `.` 与 `?` 不列入：`x? .f()` 和 `x?.f()` 是同一段代码，
# 去掉它们之间的空格不会粘成另一个记号。
OPER = set("/=-+!*%<>&|^~")

def tighten(s: str) -> str:
    # 字面量内部不动
    guarded = []
    def stash(m):
        guarded.append(m.group(0))
        return f"\x01{len(guarded) - 1}\x01"
    s = re.sub(r'"""(?:.|\n)*?"""|"(?:\\.|[^"\\])*"', stash, s)
    out = []
    for i, ch in enumerate(s):
        if ch != " ":
            out.append(ch); continue
        prev = out[-1] if out else ""
        nxt = s[i + 1] if i + 1 < len(s) else ""
        if (prev in WORD and nxt in WORD) or (prev in OPER and nxt in OPER):
            out.append(" ")
    joined = "".join(out)
    return re.sub(r"\x01(\d+)\x01", lambda m: guarded[int(m.group(1))], joined)

if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3:
        print("用法: swift-token-diff.py <改前.swift> <改后.swift>")
        raise SystemExit(2)

    a = tighten(normalize(open(sys.argv[1]).read()))
    b = tighten(normalize(open(sys.argv[2]).read()))

    if a == b:
        print(f"\u2713 记号流逐字相同（{len(a)} 字符）")
        raise SystemExit(0)

    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            lo = max(0, i - 90)
            print("\u2717 首个差异在第", i, "字符")
            print("  前：…" + a[lo:i + 90])
            print("  后：…" + b[lo:i + 90])
            raise SystemExit(1)

    print(f"\u2717 长度不同：{len(a)} vs {len(b)}")
    raise SystemExit(1)
