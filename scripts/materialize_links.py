#!/usr/bin/env python3
"""materialize_links.py <module_root>
把模块树里所有能解析的符号链接替换成真实文件副本。
原因：KernelSU 的 busybox unzip 不创建符号链接，链接会整批丢失；
而 32 位运行时依赖 /system/lib/libc.so -> /apex/.../bionic/libc.so 这类链接。
"""
import os, sys, shutil

MOD = sys.argv[1]
PREFIX = [
    ('/apex/', 'apex/'),
    ('/system_ext/', 'system/system_ext/'),
    ('/system/vendor/', 'system/vendor/'),
    ('/system/odm/', 'system/odm/'),
    ('/system/product/', 'system/product/'),
    ('/system/', 'system/'),
    ('/vendor/', 'system/vendor/'),
    ('/odm/', 'system/odm/'),
    ('/product/', 'system/product/'),
]


def resolve(target, linkdir):
    """把链接目标映射成模块树内的真实路径；返回绝对路径或 None"""
    if os.path.isabs(target):
        for pre, rep in PREFIX:
            if target.startswith(pre):
                cand = os.path.join(MOD, rep + target[len(pre):])
                if os.path.exists(cand) or os.path.islink(cand):
                    return cand
        return None
    cand = os.path.normpath(os.path.join(linkdir, target))
    if os.path.exists(cand) or os.path.islink(cand):
        return cand
    return None


links = []
for root, dirs, files in os.walk(MOD):
    for n in dirs + files:
        p = os.path.join(root, n)
        if os.path.islink(p):
            links.append(p)

ok = kept = 0
for p in links:
    tgt = os.readlink(p)
    real = resolve(tgt, os.path.dirname(p))
    if real is None:
        print('  KEEP (无法解析) %s -> %s' % (os.path.relpath(p, MOD), tgt))
        kept += 1
        continue
    # 顺着链接链找到最终真实文件
    seen = 0
    while os.path.islink(real) and seen < 10:
        t2 = os.readlink(real)
        r2 = resolve(t2, os.path.dirname(real))
        if r2 is None:
            break
        real = r2
        seen += 1
    if not os.path.isfile(real):
        print('  KEEP (目标不是文件) %s -> %s' % (os.path.relpath(p, MOD), tgt))
        kept += 1
        continue
    mode = os.stat(real).st_mode & 0o777
    os.unlink(p)
    shutil.copyfile(real, p)
    os.chmod(p, mode)
    ok += 1

print('实体化 %d 个符号链接，保留 %d 个' % (ok, kept))
