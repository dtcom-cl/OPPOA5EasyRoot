#!/system/bin/sh
# Magisk On System - 基于 magisk-on-system 官方逻辑重写
# 触发时机: post-fs-data (zygote 启动前), 由 init 的 magisk.rc 一次性触发
# 官方逻辑: 初始化环境 -> magisk --post-fs-data(挂载模块) -> --service -> --boot-complete -> --zygote-restart
# 本版本修复:
#   1) mount-modules.sh 恢复官方 "umount + bind"（此前误改为 mountpoint 检查导致模块永不 bind）
#   2) 幂等检查: 仅当模块真实挂载(modules 目录非空)才退出, 空挂载点不再误判
#   3) sepolicy.rule 的 apply 参数修正（官方脚本 $patch 变量未定义, 规则从未生效）
#   4) 全程日志打点(文件+属性+logcat), 记录每步退出码, 便于排查
umask 022

LOG=/data/adb/magisk-setup.log
log_msg() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
  chmod 644 "$LOG" 2>/dev/null
  setprop magisk.setup.stage "$*" 2>/dev/null
  /system/bin/log -t magisk-setup "$*" 2>/dev/null
}

log_msg "=== magisk-setup start (single-stage) ==="

# ---- 环境状态快照(诊断) ----
log_msg "[diag] sbin mount: $(mount | grep ' /sbin ' | head -1)"
log_msg "[diag] /sbin/magisk exists: $([ -f /sbin/magisk ] && echo yes || echo no)"
log_msg "[diag] /sbin/.magisk exists: $([ -e /sbin/.magisk ] && echo yes || echo no)"
log_msg "[diag] modules dir content: [$(ls -A /sbin/.magisk/modules/ 2>/dev/null | tr '\n' ' ')]"
log_msg "[diag] /data/adb/modules exists: $([ -d /data/adb/modules ] && echo yes || echo no)"
log_msg "[diag] modules: $(ls /data/adb/modules/ 2>/dev/null | tr '\n' ' ')"

# ---- mount-modules.sh: 官方逻辑 (无条件 umount + bind) ----
# magisk --post-fs-data 会执行 /data/adb/post-fs-data.d/*.sh;
# 先卸载 magisk 内部 modules 挂载点, 再把整个模块目录 bind 过去, 确保模块文件对系统可见。
# 注意: 不加 2>/dev/null, mount 的真实错误会出现在 magisk 日志(/cache/magisk.log),
#       用于定位开机早期 bind 偶发失败的原因。
# 此写入必须在幂等检查之前: 否则已挂载成功时直接 exit, 设备上会残留旧版脚本。
cat << 'EOF' > /data/adb/post-fs-data.d/mount-modules.sh
#!/system/bin/sh
# Magisk On System (官方逻辑)
MAGISKTMP="$(magisk --path)"
umount -l "$MAGISKTMP"/.magisk/modules
mount -o bind,shared /data/adb/modules "$MAGISKTMP"/.magisk/modules
exit 0
EOF
chmod 755 /data/adb/post-fs-data.d/mount-modules.sh
log_msg "mount-modules.sh written (umount+bind, no stderr suppression)"

# ---- 幂等检查 ----
# 仅当模块已真实 magic mount(modules 目录非空)才跳过。
# .magisk/modules 挂载点存在 ≠ 模块已挂载(快速启动/残留时可能是空 tmpfs)。
if [ -f /sbin/magisk ] && [ -d /sbin/.magisk/modules ] && [ -n "$(ls -A /sbin/.magisk/modules/ 2>/dev/null)" ]; then
  log_msg "exit: magisk already installed (modules mounted)"
  exit 0
fi
[ -f /sbin/magisk ] && log_msg "warn: /sbin/magisk exists but modules NOT mounted -> force mount"

# ---- 复制 magisk 到 /data/adb (幂等) ----
if [ ! -d /data/adb/magisk/ ]; then
  log_msg "copy magisk files to /data/adb/magisk"
  mkdir -p /data/adb/magisk/
  cp -r /system/etc/magisk/* /data/adb/magisk/ && log_msg "copy OK" || log_msg "copy FAILED"
  chmod 755 -R /data/adb/magisk/
fi
log_msg "data/adb/magisk ready"

for dir in post-fs-data.d service.d; do
  mkdir /data/adb/"$dir"/ 2>/dev/null
done
log_msg "post-fs-data.d/service.d ready"

# ---- 初始化 magisk 环境 (tmpfs /sbin) ----
MAGISKTMP=/sbin

if mount | grep -q 'magisk on /sbin'; then
  # /sbin 已是 magisk tmpfs(残留/重复触发), 直接复用, 避免重复挂载
  log_msg "/sbin already magisk tmpfs, reuse"
elif mount | grep -q rootfs; then
  log_msg "mount tmpfs /sbin (rootfs branch)"
  mount -o rw,remount /
  rm -rf /root/
  mkdir -m 750 /root/
  ln /sbin/* /root
  mount -o ro,remount /
  mount -t tmpfs -o 'mode=0755' magisk /sbin && log_msg "tmpfs /sbin OK" || log_msg "tmpfs /sbin FAILED"
  chcon u:object_r:rootfs:s0 /sbin
  ln -s /root/* /sbin
elif [ -e /sbin/ ]; then
  log_msg "mount tmpfs /sbin (sbin branch)"
  mount -t tmpfs -o 'mode=0755' magisk /sbin
  chcon u:object_r:rootfs:s0 /sbin
  mkdir -p /dev/sysroot/
  block="$(target="$(mount | grep ' / ' | xargs -n 1 | head -n 1)"; [ "$target" = /dev/root ] && echo "/dev/block/vda1" || echo "$target")"
  mount -o ro "$block" /dev/sysroot
  for file in /dev/sysroot/sbin/*; do
    [ ! -e "$file" ] && break
    if [ -L "$file" ]; then
      cp -af "$file" /sbin
    else
      touch /sbin/"$(basename "$file")"
      mount -o bind "$file" /sbin/"$(basename "$file")"
    fi
  done
  umount -l /dev/sysroot/
  rm -rf /dev/sysroot/
else
  log_msg "mount tmpfs /debug_ramdisk branch"
  MAGISKTMP=/debug_ramdisk
  mount -t tmpfs -o 'mode=0755' magisk /debug_ramdisk
fi

log_msg "MAGISKTMP=$MAGISKTMP"

grep -q ' /cache ' /proc/mounts || mount -t tmpfs -o 'mode=0755' tmpfs /cache

# 确保模块目录存在(首次开机/magisk app 尚未创建时, mount-modules.sh 的 bind 源需存在)
mkdir -p /data/adb/modules

# 仅创建官方需要的目录(block/mirror/worker), 不创建/不提前 bind modules 挂载点:
# magisk --post-fs-data 会自己管理 .magisk/modules(tmpfs), 提前 bind 会与之冲突,
# 由 mount-modules.sh 在 post-fs-data.d 阶段统一 umount+bind。
for dir in block mirror worker; do
  mkdir -p "$MAGISKTMP"/.magisk/"$dir"/
done

cd /system/etc/magisk
touch "$MAGISKTMP"/.magisk/config
for file in magisk32 magisk64 magiskinit magiskpolicy; do
  cp ./"$file" "$MAGISKTMP"/"$file" 2>/dev/null
  chmod 755 "$MAGISKTMP"/"$file" 2>/dev/null
done
log_msg "binaries copied to $MAGISKTMP"

chmod 750 "$MAGISKTMP"/magiskinit
cd "$MAGISKTMP"
[ -f "$MAGISKTMP"/magisk64 ] && ln -s ./magisk64 ./magisk || ln -s ./magisk32 ./magisk
ln -s ./magisk ./resetprop
ln -s ./magiskpolicy ./supolicy
ln -s ./magisk ./su
cd /

# ---- SELinux 注入 (修复 apply 参数) ----
if [ "$(getenforce)" != Disabled ]; then
  apply=""
  for rule in $(find /data/adb/modules/ /data/adb/modules_update/ -name "sepolicy.rule" 2>/dev/null); do
    apply="$apply --apply $rule"
  done
  log_msg "sepolicy rules: [$apply]"
  sepolicy=""
  for file in /sys/fs/selinux/policy /sepolicy /sepolicy_debug /sepolicy.unlocked /system/etc/selinux/precompiled_sepolicy /vendor/etc/selinux/precompiled_sepolicy /odm/etc/selinux/precompiled_sepolicy; do
    [ ! -f "$file" ] && continue
    sepolicy="$file"
    break
  done
  log_msg "sepolicy file: $sepolicy"
  "$MAGISKTMP"/magiskpolicy --load "$sepolicy" --live --magisk $apply
  log_msg "magiskpolicy --live rc=$?"
  setenforce "$(getprop magisk.selinux.state)" 2>/dev/null
fi

# ---- magisk 命令序列 (官方: post-fs-data 一次性执行) ----
# FBE block 加密设备: post-fs-data 早期 /data 可能尚未完全就绪,
# magisk 可能读到空模块列表 -> 模块未挂载 -> RUtils 校验重新执行 -> sprc=-1。
# 挂载后检测 modules 目录, 为空则等待 /data 就绪并重跑 (手动重跑已验证有效)。
attempt=0
while [ "$attempt" -lt 5 ]; do
  attempt=$((attempt+1))
  log_msg "run magisk --post-fs-data (attempt $attempt/5)"
  "$MAGISKTMP"/magisk --post-fs-data
  rc=$?
  log_msg "magisk --post-fs-data rc=$rc"
  if [ -n "$(ls -A "$MAGISKTMP"/.magisk/modules/ 2>/dev/null)" ]; then
    log_msg "[diag] modules dir after post-fs-data: [$(ls -A "$MAGISKTMP"/.magisk/modules/ | tr '\n' ' ')]"
    log_msg "[diag] modules mount: $(mount | grep "$MAGISKTMP/.magisk/modules" | head -1)"
    log_msg "[diag] librutils64: $(md5sum /system/lib64/librutils.so 2>/dev/null)"
    break
  fi
  log_msg "[retry] modules empty, /data/adb/modules=[$(ls -A /data/adb/modules/ 2>/dev/null | tr '\n' ' ')], wait 2s"
  sleep 2
done

# OPPO A5 A.30: 曾因 Zygisk(v27) 注入 zygote 触发 ART JIT 崩溃(SIGSEGV /memfd:jit-cache)而强制关闭。
# 2026-08-07 面具提前到 post-fs-data 后, 为验证 zygisk+lsposed 是否仍崩溃, 临时移除强制关闭,
# 尊重 Magisk App 中的 zygisk 设置(测试前需先在 App 开启 Zygisk)。
# 如再次复现崩溃循环, 恢复下面两行:
# "$MAGISKTMP"/magisk --sqlite "UPDATE settings SET value=0 WHERE key='zygisk';" 2>/dev/null
# log_msg "zygisk disabled (crash workaround)"
zygisk_val="$("$MAGISKTMP"/magisk --sqlite 'SELECT value FROM settings WHERE key="zygisk";' 2>/dev/null)"
log_msg "zygisk setting: $zygisk_val"

log_msg "run magisk --service"
"$MAGISKTMP"/magisk --service
log_msg "magisk --service rc=$?"

log_msg "run magisk --boot-complete"
"$MAGISKTMP"/magisk --boot-complete
log_msg "magisk --boot-complete rc=$?"

log_msg "run magisk --zygote-restart"
"$MAGISKTMP"/magisk --zygote-restart
log_msg "magisk --zygote-restart rc=$?"

log_msg "=== magisk-setup done ==="
exit 0
