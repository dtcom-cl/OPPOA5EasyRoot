# ============================================================
#  lib\50-config.ps1   阶段8~11
#     Install-Modules     装两个 Magisk 模块（OPPO 去校验 + 弹窗自动关闭）
#     Set-MagiskConfig    装 Magisk App + 开 Zygisk + DenyList + 授权
#     Restart-And-Wait    重启并等待
#     Confirm-Result      自动验收 + 中文报告
# ============================================================

function Install-Modules {
    Info '推送模块到手机'
    $push = @(
        (Join-Path $C.ModDir 'install_module.sh'),
        (Join-Path $C.ModDir 'rutils-disable-module.zip'),
        (Join-Path $C.ModDir 'dialog-killer-module.zip')
    )
    foreach ($p in $push) {
        if (-not (Test-Path $p)) { throw ('缺少文件: ' + $p) }
        [void](Adb push $p /data/local/tmp/)
    }
    Ok '推送完成'

    $script = @'
#!/system/bin/sh
echo "=== 安装模块 ==="
for z in rutils-disable-module.zip dialog-killer-module.zip; do
  echo "--- $z ---"
  sh /data/local/tmp/install_module.sh /data/local/tmp/$z
done
echo "=== 已装模块 ==="
ls /data/adb/modules/
'@
    $out = Run-OnDevice -ScriptText $script -Name 'mods'
    Say $out 'DarkGray'

    if ($out -match 'rutils-disable' -and $out -match 'dialog-killer') {
        Ok '两个模块都装上了'
    } else {
        # dialog-killer 可能名字不同，单独确认
        $ls = (Adb shell 'ls /data/adb/modules/')
        if ($ls -match 'rutils') { Ok '完整性绕过模块装上了' } else { Warn '没看到 rutils 模块' }
        if ($ls -match 'dialog') { Ok '弹窗关闭模块装上了' } else { Warn '没看到 dialog 模块' }
    }
}

function Set-MagiskConfig {
    # ---- 1) 装 Magisk App（版本与 daemon 匹配 27.0）----
    $apk = Join-Path $C.RefDir 'Magisk-v27.0.apk'
    if (Test-Path $apk) {
        Info '装 Magisk App v27.0'
        $r = Adb -a @('install', '-r', $apk)
        if ($r -match 'Success') { Ok 'Magisk App 装上了' } else { Warn ('Magisk App 安装返回: ' + ($r -replace "`r?`n", ' ')) }
    } else { Warn '没有 Magisk-v27.0.apk，跳过装 App' }

    # ---- 2) 取 App 的 uid ----
    $uid = ''
    try {
        $d = Adb shell 'dumpsys package com.topjohnwu.magisk'
        if ($d -match 'userId=(\d+)') { $uid = $Matches[1] }
    } catch {}
    if ($uid) { Info ('Magisk App uid = ' + $uid) } else { Warn '读不到 App uid，跳过 su_manager 授权' }

    # ---- 3) 配置 Magisk ----
    $script = @'
#!/system/bin/sh
set -e
echo "=== 开启 Zygisk ==="
magisk --sqlite "REPLACE INTO settings (key,value) VALUES ('zygisk',1);"
echo "=== 授权 ==="
APPUID="__APPUID__"
if [ -n "$APPUID" ] && [ "$APPUID" != "0" ]; then
  magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES ($APPUID,2,0,1,1);"
  magisk --sqlite "REPLACE INTO settings (key,value) VALUES ('su_manager',$APPUID);"
fi
magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES (2000,2,0,1,1);"
magisk --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES (0,2,0,1,1);"
echo "=== DenyList ==="
for p in io.github.vvb2060.mahoshojo com.coloros.accegamesdk bin.mt.plus.canary com.tencent.mobileqq; do
  if pm list packages 2>/dev/null | grep -q "$p"; then
    magisk --denylist add "$p" 2>/dev/null || true
  fi
done
magisk --denylist enable 2>/dev/null || true
echo "=== 当前设置 ==="
magisk --sqlite "SELECT * FROM settings;"
echo "=== DenyList ==="
magisk --denylist ls 2>/dev/null || true
echo "=== 已装模块 ==="
ls /data/adb/modules/
'@
    if ($uid) { $script = $script.Replace('__APPUID__', $uid) } else { $script = $script.Replace('__APPUID__', '0') }
    $out = Run-OnDevice -ScriptText $script -Name 'config'
    Say $out 'DarkGray'

    if ($out -match 'zygisk\|value=1' -or $out -match 'key=zygisk') { Ok 'Zygisk 已开' } else { Warn 'Zygisk 没写进去' }
    if ($out -match 'denylist\|value=1') { Ok 'DenyList 已开' } else { Warn 'DenyList 没开' }
}

function Restart-And-Wait {
    Info '重启手机'
    [void](Adb reboot)
    # 先等设备真的掉线再 Wait-Boot：只睡 8 秒的话，如果手机还没掉线，
    # Wait-Boot 会读到【重启前旧会话】的 sys.boot_completed=1 而立刻返回，
    # 紧接着 Step 11 的自动验收就对着正在重启的手机跑，误报一片"失败"。
    [void](Wait-For { (Adb-Devices).Count -eq 0 } 30 '等待手机重启 ...' 1000)
    Start-Sleep -Seconds 3
    [void](Wait-Boot)
    Wait-Adb
    Ok '重启完成'
}

function Confirm-Result {
    Info '自动验收'
    $script = @'
#!/system/bin/sh
echo "=== 1) root 身份 ==="
id
echo "=== 2) Magisk 版本 ==="
magisk -v 2>/dev/null
magisk -V 2>/dev/null
echo "=== 3) Zygisk 注入 ==="
echo "libzygisk 挂载数: $(grep -c libzygisk /proc/mounts)"
grep -a -i "zygisk64: replace" /cache/magisk.log 2>/dev/null | tail -2
echo "=== 4) 已装模块 ==="
ls /data/adb/modules/ 2>/dev/null
echo "=== 5) 弹窗关闭模块是否在跑 ==="
cat /data/adb/dialog_killer.log 2>/dev/null | tail -3
echo "=== 6) OPPO 完整性绕过 ==="
md5sum /system/lib64/librutils.so 2>/dev/null
md5sum /system/lib/librutils.so 2>/dev/null
echo "=== 7) 设置 ==="
magisk --sqlite "SELECT * FROM settings;" 2>/dev/null
'@
    $out = Run-OnDevice -ScriptText $script -Name 'verify'
    Add-Log $out

    # 期望的 librutils md5（从模块 zip 里现算，避免硬编码）
    $exp64 = ''
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $C.ModDir 'rutils-disable-module.zip'))
        $e = $zip.Entries | Where-Object { $_.FullName -eq 'system/lib64/librutils.so' } | Select-Object -First 1
        if ($e) {
            $ms = New-Object IO.MemoryStream; $e.Open().CopyTo($ms)
            $exp64 = ([BitConverter]::ToString(([Security.Cryptography.MD5]::Create()).ComputeHash($ms.ToArray())) -replace '-', '').ToLower()
        }
        $zip.Dispose()
    } catch {}

    Say ''
    Say '  =---- 验收结果 ----' 'White'
    $script:vPass = 0; $script:vFail = 0
    function V($ok, $msg) {
        if ($ok) { Write-Host ('  [通过] ' + $msg) -ForegroundColor Green; $script:vPass++ }
        else     { Write-Host ('  [失败] ' + $msg) -ForegroundColor Red;   $script:vFail++ }
        Add-Log (($(if ($ok) { '[通过] ' } else { '[失败] ' })) + $msg)
    }

    V ($out -match 'uid=0')                             'root 可用 uid=0'
    V ($out -match 'u:r:magisk:s0')                     'root 上下文正确 u:r:magisk:s0'
    V ($out -match '27000')                             'Magisk 版本 27.0 (27000)'
    V ($out -match 'libzygisk 挂载数: 2')                'Zygisk 双架构库已挂载 lib + lib64'
    V ($out -match 'zygisk64: replace')                 'Zygisk 已注入 zygote'
    V ($out -match 'rutils-disable')                    'OPPO 完整性绕过模块已安装'
    V ($out -match 'dialog-killer')                     '弹窗自动关闭模块已安装'
    if ($exp64) { V ($out -match $exp64) 'OPPO 完整性绕过已生效' }
    else { Write-Host '  [跳过] librutils 校验' -ForegroundColor Yellow }


    Say ''
    if ($script:vFail -eq 0) { Ok ('全部通过: ' + $script:vPass + ' 项') }
    else { Warn ('有 ' + $script:vFail + ' 项没过。日志: ' + (Get-LogPath)) }
}
