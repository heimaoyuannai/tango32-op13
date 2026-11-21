# shim_edit.py — 一加13 / OxygenOS 16.0.7.201 版（裁剪）
# 只保留与版本无关的两处 ZygoteInit 改动；其余类在“国行 16.0.7.201 32 位库 vs 欧版 16.0.7.201 框架”
# 这一对同版本固件里 JNI 注册与 Java native 声明完全一致（已用 libandroid_runtime/libhwui/
# libSchedAssistJni 的 JNINativeMethod 表逐条比对），因此不需要签名改写。
# Usage: python3 -I shim_edit.py <smali_root>
import sys, os, re
R = sys.argv[1]
done = []

# 1) ZygoteInit: HttpEngine (Cronet) 预加载在 32 位下没有 libhttpengine.so，
#    把只捕获 NoSuchMethodError 的 catch 放宽到 Throwable（失败只影响日志）。
p = os.path.join(R, 'com/android/internal/os/ZygoteInit.smali'); s = open(p).read()
rx = re.compile(r'(invoke-static \{\}, Landroid/net/http/HttpEngine;->preload\(\)V\n    :try_end_\w+\n    \.catch )Ljava/lang/NoSuchMethodError;')
s, n = rx.subn(r'\1Ljava/lang/Throwable;', s)
assert n == 1, 'HttpEngine.preload catch not found'
done.append('ZygoteInit.preload: HttpEngine catch -> Throwable')

# 2) ZygoteInit.main: runSelectLoop 之前跑 TangoFdFix.run()（fd 白名单兜底）
rx = re.compile(r'(?m)^(    invoke-virtual \{[^}]*\}, Lcom/android/internal/os/ZygoteServer;->runSelectLoop\()')
s, n = rx.subn('    invoke-static {}, Lcom/android/internal/os/TangoFdFix;->run()V\n\n' + r'\1', s)
assert n == 1, 'runSelectLoop call not found'
open(p, 'w').write(s); done.append('ZygoteInit.main: TangoFdFix.run() before runSelectLoop')

print(len(done), 'shim edits:', '; '.join(done))
