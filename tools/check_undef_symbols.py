#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_undef_symbols.py — prefs bundle 自包含性守卫

背景（v5.25.1 的坑）：
    prefs bundle 用 -Wl,-undefined,dynamic_lookup 链接（因为 PSListController 等来自
    Preferences 私有框架，编译期链接不到）。这个开关会把「符号解析」推迟到运行时。
    一旦 bundle 里引用了 *本项目自己* 的类/函数，而这些符号只编进了 tweak dylib，
    那么在设置进程里 dlopen 就会失败：
        symbol not found in flat namespace '_OBJC_CLASS_$_AskAIEngine'
    表现：设置 → 超级截图 不显示 / 空白 / 「未能载入软件包」。
    plist 语法检查、plistlib 解析都发现不了这个问题 —— 这是二进制层面的。

用法：
    python3 tools/check_undef_symbols.py <MachO路径> [源码目录，默认 src]

退出码：
    0 = 通过；1 = 发现自有符号未定义（会列出具体符号与可能的修复方法）
"""

import os
import re
import struct
import sys

# 这些前缀来自 Apple 的系统框架，bundle 里留着未定义是正常的（运行时由 dyld 解析）
SYSTEM_PREFIXES = (
    "NS", "UI", "CA", "CG", "CF", "PS", "AV", "AU", "CL", "CT", "EK", "GC", "HK",
    "ML", "MP", "MT", "NE", "PK", "SC", "SK", "SL", "SS", "TW", "VA", "WC", "AB",
    "AD", "AS", "AT", "BS", "CB", "CN", "DA", "DM", "EA", "FI", "FS", "GL", "HM",
    "HS", "IC", "LA", "LC", "LN", "LS", "MC", "MF", "MK", "MS", "NF", "NI", "NL",
    "NM", "PB", "PH", "QL", "RP", "RT", "SB", "SF", "SM", "SP", "TL", "TS", "UA",
    "UC", "UM", "VS", "WF", "WK", "XC", "CC", "PX", "PU", "SF", "SBS", "BKS",
    "FBS", "RBS", "TU", "AX", "CH", "HD", "ID", "IM", "LP", "MA", "NT", "OS",
    "PT", "SA", "SI", "SR", "TD", "TK", "VG", "Web", "JS", "WK",
)

# 明确的 C 符号白名单（dyld / libobjc / libc / libdispatch）
SYSTEM_C_SYMBOLS = {
    "dyld_stub_binder", "___stack_chk_fail", "___stack_chk_guard",
    "___CFConstantStringClassReference", "___objc_personality_v0",
    "__NSConcreteStackBlock", "__NSConcreteGlobalBlock", "__NSConcreteMallocBlock",
    "___NSDictionary0__struct", "___NSArray0__struct", "__objc_empty_cache",
    "__objc_empty_vtable", "_dispatch_async", "__dispatch_main_q",
    "_CFNotificationCenterGetDarwinNotifyCenter", "_CFNotificationCenterPostNotification",
    "_UIApplicationDidBecomeActiveNotification", "_NSLog", "__Unwind_Resume",
    "_objc_msgSend", "_objc_msgSendSuper", "_objc_msgSendSuper2", "_objc_alloc",
    "_objc_retain", "_objc_release", "_objc_autoreleaseReturnValue",
    "_objc_retainAutoreleasedReturnValue", "_objc_retainAutoreleaseReturnValue",
    "_objc_storeStrong", "_objc_begin_catch", "_objc_end_catch", "_objc_opt_class",
    "_objc_opt_isKindOfClass", "_objc_opt_respondsToSelector", "_objc_exception_throw",
    "_OBJC_EHTYPE_$_NSException", "___cxa_throw", "___cxa_begin_catch",
    "___cxa_end_catch", "_malloc", "_free", "_memcpy", "_strlen", "_strcmp",
    # Block 运行时 / CoreFoundation 常量
    "__Block_object_assign", "__Block_object_dispose", "__Block_copy",
    "__Block_release", "___kCFBooleanTrue", "___kCFBooleanFalse",
    "__NSConcreteFinalizingBlock", "_kCFAllocatorDefault", "_kCFNull",
}


def project_class_names(src_dir):
    """扫描源码里我们自己定义的 ObjC 类名。"""
    names = set()
    if not os.path.isdir(src_dir):
        return names
    pat = re.compile(r"^\s*@(?:interface|implementation)\s+([A-Za-z_][A-Za-z0-9_]*)")
    for root, _dirs, files in os.walk(src_dir):
        for fn in files:
            if not fn.endswith((".m", ".mm", ".h", ".xm", ".xmi")):
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as fp:
                    for line in fp:
                        m = pat.match(line)
                        if m:
                            names.add(m.group(1))
            except OSError:
                pass
    return names


def macho_slices(data):
    if len(data) < 8:
        return []
    mag = struct.unpack(">I", data[:4])[0]
    if mag == 0xCAFEBABE:
        n = struct.unpack(">I", data[4:8])[0]
        out = []
        for i in range(n):
            a = 8 + i * 20
            if a + 20 > len(data):
                break
            _ct, _cs, off, size, _align = struct.unpack(">iiIII", data[a:a + 20])
            out.append((off, size))
        return out
    return [(0, len(data))]


def undefined_symbols(path):
    """返回 {arch描述: [未定义符号名, ...]}"""
    with open(path, "rb") as f:
        data = f.read()
    result = {}
    for idx, (base, size) in enumerate(macho_slices(data)):
        if base + 32 > len(data):
            continue
        magic = struct.unpack("<I", data[base:base + 4])[0]
        if magic not in (0xFEEDFACF, 0xFEEDFACE):
            continue
        ncmds = struct.unpack("<I", data[base + 16:base + 20])[0]
        p = base + 32
        symtab = None
        undef_range = None
        for _ in range(ncmds):
            if p + 8 > len(data):
                break
            cmd, cmdsize = struct.unpack("<II", data[p:p + 8])
            if cmdsize < 8:
                break
            if cmd == 0x2:  # LC_SYMTAB
                symtab = struct.unpack("<IIII", data[p + 8:p + 24])
            elif cmd == 0xB:  # LC_DYSYMTAB
                _iloc, _nloc, _iext, _next, iundef, nundef = struct.unpack("<6I", data[p + 8:p + 32])
                undef_range = (iundef, nundef)
            p += cmdsize
        if not symtab or not undef_range:
            continue
        symoff, nsyms, stroff, _strsize = symtab
        iundef, nundef = undef_range
        names = []
        for i in range(iundef, min(iundef + nundef, nsyms)):
            e = base + symoff + i * 16
            if e + 16 > len(data):
                break
            n_strx = struct.unpack("<I", data[e:e + 4])[0]
            end = data.find(b"\x00", base + stroff + n_strx)
            if end < 0:
                continue
            names.append(data[base + stroff + n_strx:end].decode("utf-8", "replace"))
        result["slice#%d" % idx] = names
    return result


def classify(sym, our_classes):
    """返回 ('own', 类名) / ('system', None) / ('unknown', None)"""
    for prefix in ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"):
        if sym.startswith(prefix):
            cls = sym[len(prefix):]
            if cls in our_classes:
                return ("own", cls)
            return ("system", None)
    bare = sym.lstrip("_")
    if sym in SYSTEM_C_SYMBOLS:
        return ("system", None)
    for pre in SYSTEM_PREFIXES:
        if bare.startswith(pre):
            return ("system", None)
    return ("unknown", None)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    target = sys.argv[1]
    src_dir = sys.argv[2] if len(sys.argv) > 2 else "src"
    if not os.path.exists(target):
        print("!! 找不到文件: %s" % target)
        return 1

    our_classes = project_class_names(src_dir)
    print(">> 目标: %s" % target)
    print(">> 本项目源码类 (%d): %s" % (len(our_classes), ", ".join(sorted(our_classes))))

    per_arch = undefined_symbols(target)
    if not per_arch:
        print("!! 解析不到符号表，跳过（无法保证安全）")
        return 1

    bad, unknown = set(), set()
    for arch, syms in per_arch.items():
        own = []
        for s in syms:
            kind, cls = classify(s, our_classes)
            if kind == "own":
                bad.add(cls)
                own.append(s)
            elif kind == "unknown":
                unknown.add(s)
        print("\n[%s] 未定义符号 %d 个" % (arch, len(syms)))
        if own:
            for s in sorted(own):
                print("    ✗ 自有符号: %s" % s)

    if bad:
        print("\n" + "=" * 66)
        print("✗ 失败：prefs bundle 引用了只存在于 tweak dylib 的自有类")
        print("=" * 66)
        for cls in sorted(bad):
            src = None
            for root, _d, files in os.walk(src_dir):
                for fn in files:
                    if fn == cls + ".m":
                        src = os.path.join(root, fn).replace("\\", "/")
            print("  • %s%s" % (cls, ("  → 源码 %s" % src) if src else ""))
        print("\n修复：把上面这些 .m 加进 Makefile 的 <BundleName>_FILES，让 bundle 自包含。")
        print("原因：tweak dylib 的 Filter 里没有 com.apple.Preferences，设置进程")
        print("      加载不到这些类，-undefined,dynamic_lookup 会让 dlopen 直接失败。")
        return 1

    if unknown:
        print("\n[!] 以下未定义符号不属于已知系统前缀，请人工确认（不阻断构建）：")
        for s in sorted(unknown):
            print("    ? " + s)

    print("\n✓ 通过：prefs bundle 自包含，未引用 tweak dylib 里的自有符号。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
