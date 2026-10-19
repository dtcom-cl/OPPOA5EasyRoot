#!/system/bin/sh
# usage: sh install_module.sh /data/local/tmp/xxx.zip
ZIP="$1"
[ -z "$ZIP" ] && echo "usage: sh install_module.sh <zip>" && exit 1
[ -f "$ZIP" ] || { echo "no such file: $ZIP"; exit 1; }
BB=/system/etc/magisk/busybox
ID=$($BB unzip -p "$ZIP" module.prop 2>/dev/null | grep '^id=' | head -1 | cut -d= -f2 | tr -d '\r')
[ -z "$ID" ] && { echo "cannot read id= from module.prop"; exit 1; }
MOD=/data/adb/modules/$ID
echo "installing module id=$ID -> $MOD"
rm -rf "$MOD"; mkdir -p "$MOD"
$BB unzip -o "$ZIP" -d "$MOD" >/dev/null 2>&1
rm -rf "$MOD/META-INF"
touch "$MOD/update"
chown -R 0:0 "$MOD"
chmod 0755 "$MOD"
# ?????????????Shamiko ? machikado.* ?????
find "$MOD" -type f ! -name "*.so" ! -name "*.apk" ! -name "*.json" ! -name "*.md" ! -name "*.sha256" ! -name "*.prop" ! -name "*.txt" -exec chmod 0755 {} \; 2>/dev/null
echo "--- ????? ---"
find "$MOD" -type f -perm -u+x | head -20
echo "done. reboot to activate."