# ============================================================
#  lib\40-flash.ps1   阶段6~7
#     Assert-ProgramLabels  白名单闸门（只允许白名单里的分区）
#     Invoke-Flash          刷入 system（引导 → 写分区 → 重启）
#     Invoke-FhProgram      通用 fh_loader 写入（救砖复用）
#     Reset-Device          发 reset.xml 重启
#     Wait-Boot / Wait-Adb  等开机 / 等 adb
# ============================================================

# 白名单闸门：检查即将交给 fh_loader 的 XML 里每个 <program> 的 label 是否都在白名单里。
# 常规刷写只允许 system；一键救砖额外允许 boot。persist/modemst1/modemst2/fsg/ocdt/recovery
# 等永远不在白名单里 —— 宁可中止，绝不写坏分区。
function Assert-ProgramLabels {
    param([string]$XmlBody, [string[]]$Allowed)

    $progTags = @([regex]::Matches($XmlBody, '<program\b[^>]*>'))
    $labels = @($progTags | ForEach-Object { if ($_.Value -match 'label="([^"]+)"') { $Matches[1] } })
    $bad = @($labels | Where-Object { $Allowed -notcontains $_ })
    if ($progTags.Count -lt 1 -or $labels.Count -ne $progTags.Count -or $bad.Count -gt 0) {
        $seen = @($labels)
        if ($labels.Count -ne $progTags.Count) { $seen += '(无标签)' }
        $seen = @($seen | Sort-Object -Unique)
        Err ('拒绝执行，分区不允许: ' + ($seen -join '、'))
        Add-Log ('闸门拦截：' + ($seen -join '、'))
        throw '刷写指令包含非白名单分区，已阻止执行。'
    }
    Add-Log ('闸门通过：' + (($labels | Sort-Object -Unique) -join ' + '))
}

# 通用 fh_loader 写入：救砖与常规刷写共用
function Invoke-FhProgram {
    param([int]$port, [string]$xmlPath, [string]$searchPath, [string]$logName = 'flash')

    $fh = Get-StageTool 'fh_loader.exe'
    return (Run-Tee $fh @(
        ('--port=\\.\COM' + $port), '--memoryname=emmc',
        ('--search_path=' + $searchPath), ('--sendxml=' + $xmlPath),
        ('--mainoutputdir=' + $searchPath), '--noprompt', '--showpercentagecomplete'
    ) $logName)
}

function Reset-Device {
    param([int]$port)

    $reset = Get-StageTool 'reset.xml'
    if (-not (Test-Path -LiteralPath $reset)) { Warn '找不到 reset.xml，请长按电源键开机'; return $false }
    $fh = Get-StageTool 'fh_loader.exe'
    [void](Run-Tee $fh @(
        ('--port=\\.\COM' + $port), '--memoryname=emmc',
        ('--search_path=' + $C.StageDir), ('--sendxml=' + $reset),
        ('--mainoutputdir=' + $C.StageDir), '--noprompt'
    ) 'reset')
    return $true
}

function Invoke-Flash {
    param([int]$port, $img, $geo)

    $imgPath  = Get-StageImage $img.Path 'system_flash.img'
    $imgName  = Split-Path $imgPath -Leaf
    $imgBytes = (Get-Item $imgPath).Length
    $sectors  = [int64]($imgBytes / 512)

    Info ('待刷: ' + [math]::Round($imgBytes / 1GB, 2) + ' GB / ' + $sectors + ' 扇区')
    Info ('system 起 ' + $geo.SystemStart + ' / ' + $geo.SystemSectors + ' 扇区')

    if ($sectors -ne $geo.SystemSectors) {
        Warn ('镜像 ' + $sectors + ' 扇区, 分区 ' + $geo.SystemSectors + ' 扇区, 不一致')
        if ($sectors -lt $geo.SystemSectors) {
            Say ('  少 ' + ($geo.SystemSectors - $sectors) + ' 扇区: 分区尾部留旧数据, 系统可能异常') 'Red'
        } else {
            Say ('  多 ' + ($sectors - $geo.SystemSectors) + ' 扇区: 可能失败或写到别的分区') 'Red'
        }
        if (-not (Ask '确定继续刷？' 'n')) { throw '用户取消刷写' }
    }

    $body = @"
<?xml version="1.0" ?>
<data>
  <program SECTOR_SIZE_IN_BYTES="512" filename="$imgName" label="system" physical_partition_number="0" start_sector="$($geo.SystemStart)" num_partition_sectors="$sectors" sparse="false" />
</data>
"@
    Assert-ProgramLabels -XmlBody $body -Allowed @('system')

    $xml = Join-Path $C.StageDir 'program-flash.xml'
    [IO.File]::WriteAllText($xml, ($body -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))

    Warn '正在刷 system，别拔线，别按电源键'
    $r = Invoke-FhProgram -port $port -xmlPath $xml -searchPath $C.StageDir -logName 'flash'

    if (-not (($r.Text -match '\{SUCCESS\}') -and ($r.Text -match 'All Finished Successfully'))) {
        Err '刷写没看到成功标记'
        Say ('  日志: ' + (Get-LogPath)) 'Cyan'
        if (-not (Ask '仍然继续后面的步骤吗？' 'n')) { throw '刷写未确认成功，已停止' }
    } else {
        Ok '刷写成功'
    }

    Info '发送重启'
    if (Reset-Device -port $port) { Ok '已重启，等开机' } else { Ok '请长按电源键开机' }
}

function Wait-Boot {
    Info '等手机开机'
    Say '  不限时间；随时可按 Ctrl+C 停。' 'DarkGray'
    $t0 = Get-Date
    $nextHint = 120
    Write-Host '  等待开机 ' -NoNewline -ForegroundColor Cyan
    while ($true) {
        if ((Adb-Devices).Count -gt 0) {
            $bc = (Get-Prop 'sys.boot_completed')
            if ($bc -eq '1') { Write-Host ''; Ok '手机已开机'; return $true }
        }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
        $el = [int]((Get-Date) - $t0).TotalSeconds
        if ($el -ge $nextHint) {
            $nextHint += 120
            Write-Host ''
            Warn ('等了 ' + $el + ' 秒还没开机，看这几种情况：')
            Say '  卡在开机动画 → 强制关机，第二屏时按住音量减进安全模式，删掉可疑模块' 'Yellow'
            Say '  adb 看不到手机 → 通知栏把 USB 用途改成「传输文件」' 'Yellow'
            Say '  想回到刷机前 → 退出后菜单选 2 一键救砖' 'Yellow'
            Write-Host '  等待开机 ' -NoNewline -ForegroundColor Cyan
        }
    }
}

function Wait-Adb {
    Info '检查 adb 连接'
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 60) {
        if ((Adb-Devices).Count -gt 0) { break }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
    Write-Host ''

    if ((Adb-Devices).Count -eq 0) {
        Warn 'adb 连不上手机。手机上做两件事：'
        Say '  1) 通知栏 → USB 用途 → 传输文件 MTP' 'White'
        Say '  2) 弹「允许 USB 调试」→ 允许' 'White'
        if (-not (Ask '弄好后回车继续, 输入 n 跳过自动配置' 'y')) { throw '用户放弃 adb 配置阶段' }
        $t0 = Get-Date
        $nextHint = 60
        Write-Host '  等待 adb ' -NoNewline -ForegroundColor Cyan
        while ($true) {
            if ((Adb-Devices).Count -gt 0) { break }
            Write-Host '.' -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
            $el = [int]((Get-Date) - $t0).TotalSeconds
            if ($el -ge $nextHint) {
                $nextHint += 60
                Write-Host ''
                Warn ('等了 ' + $el + ' 秒还没连上：换根数据线 / 换个 USB 口，确认上面两步做了')
                Write-Host '  等待 adb ' -NoNewline -ForegroundColor Cyan
            }
        }
        Write-Host ''
    }
    Ok ('adb 已连接：' + ((Adb-Devices) -join ', '))

    [void](Adb root)
    Start-Sleep -Seconds 2
    $id = (Adb shell 'id')
    if ($id -notmatch 'uid=0') { Warn 'adb 不是 root，改用 su 执行' } else { Ok 'adb 已是 root' }
}
