# ============================================================
#  lib\60-rescue.ps1   一键救砖
#     Get-RescueBackups    扫 bin\backup 下的时间戳备份
#     Show-RescueBackups   列表显示（序号/时间/机型/固件/system 大小/boot）
#     Invoke-RescueFlow    菜单选项 2 的完整流程
#  原则：只读备份；写入前必须做尺寸校验；写入必须过白名单闸门（system，外加 boot）。
# ============================================================

function Test-SparseFile {
    param([string]$Path)
    try {
        $b = New-Object byte[] 4
        $fs = [IO.File]::OpenRead($Path)
        [void]$fs.Read($b, 0, 4)
        $fs.Close()
        return ($b[0] -eq 0x3A -and $b[1] -eq 0xFF -and $b[2] -eq 0x26 -and $b[3] -eq 0xED)
    } catch { return $false }
}

# 扫描 bin\backup 下的时间戳目录（新的带秒 yyyyMMdd-HHmmss，旧的 yyyyMMdd-HHmm 也认）
function Get-RescueBackups {
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $C.BakDir)) { return $list }
    $dirs = @(Get-ChildItem -LiteralPath $C.BakDir -Directory -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d{8}-\d{4}(\d{2})?(-\d+)?$' } |
              Sort-Object Name -Descending)
    foreach ($d in $dirs) {
        $sys = Join-Path $d.FullName 'system_stock.img'
        $bts = Join-Path $d.FullName 'boot_stock.img'
        $meta = $null
        $metaFile = Join-Path $d.FullName 'backup.json'
        if (Test-Path -LiteralPath $metaFile) {
            try { $meta = (Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $meta = $null }
        }
        $sysBytes = 0L
        if (Test-Path -LiteralPath $sys) { $sysBytes = (Get-Item -LiteralPath $sys).Length }
        $list.Add([pscustomobject]@{
            Name       = $d.Name
            Dir        = $d.FullName
            Time       = $d.Name
            Meta       = $meta
            Model      = $(if ($meta -and $meta.model) { [string]$meta.model } else { '未知' })
            Firmware   = $(if ($meta -and $meta.firmware) { [string]$meta.firmware } else { '未知' })
            SystemImg  = $sys
            BootImg    = $bts
            HasSystem  = (Test-Path -LiteralPath $sys)
            HasBoot    = (Test-Path -LiteralPath $bts)
            SystemBytes= $sysBytes
            PartitionBytes= $(if ($meta -and $meta.systemBytes) { [int64]$meta.systemBytes } else { $sysBytes })
            HasMeta    = ($null -ne $meta)
        })
    }
    return $list
}

function Show-RescueBackups {
    param($Backups)

    Say ''
    Say '  [INFO] 备份列表' 'Cyan'
    $i = 0
    foreach ($b in $Backups) {
        $i++
        $gb = [math]::Round($b.PartitionBytes / 1GB, 2)
        $boot = $(if ($b.HasBoot) { '有 boot' } else { '无 boot' })
        $tag  = $(if ($b.HasMeta) { '' } else { '  [旧备份/无信息]' })
        Say ('   ' + $i + '. ' + $b.Time + '   ' + $b.Model + ' / ' + $b.Firmware + '   system ' + $gb + ' GB   ' + $boot + $tag) 'Gray'
    }
    Say ''
}

function Invoke-RescueFlow {
    Set-Title 'OPPOA5 救砖中'
    $backups = @(Get-RescueBackups)
    if ($backups.Count -eq 0) {
        Say ''
        Warn 'bin\backup 里没有备份, 先做一次原机备份'
        Pause-ForUser
        return
    }

    Show-RescueBackups $backups
    $pick = Read-Line '  输入序号按Enter继续: '
    if ($pick -eq '' -or $pick -eq '0') { return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $backups.Count) {
        Err '输入错误, 请重新输入.'; Start-Sleep -Milliseconds 900; return
    }
    $bak = $backups[$idx - 1]
    if (-not $bak.HasSystem) { Err '这份备份里没有 system_stock.img，不能用'; Pause-ForUser; return }

    Say ''
    Say '  [INFO] 选择范围' 'Cyan'
    Say ''
    Say '  1.只恢复 system'
    Say ''
    Say ('  2.system + boot' + $(if ($bak.HasBoot) { '' } else { ' - 无 boot' }))
    Say ''
    Say '  0.返回'
    Say ''
    $scope = Read-Line '  输入序号按Enter继续: '
    $doBoot = $false
    if ($scope -eq '0') { return }
    elseif ($scope -eq '1') { $doBoot = $false }
    elseif ($scope -eq '2') { $doBoot = $bak.HasBoot; if (-not $bak.HasBoot) { Warn '这份备份没有 boot，只恢复 system' } }
    else { Warn '输入无效'; Start-Sleep -Milliseconds 900; return }

    # ---- 缺元数据的老备份：强警告 + 要求输入完整单词确认 ----
    if (-not $bak.HasMeta) {
        Warn '旧备份, 没有机型/分区信息, 刷错会变砖'
        Warn '输入 RESTORE 确认'
        $ok = Read-Line '  确认'
        if ($ok -cne 'RESTORE') { Say '  已取消。' 'Yellow'; Pause-ForUser; return }
    }

    # ---- 磁盘空间（稀疏转 raw 要再占一份 system 大小）----
    if (-not (Test-DiskSpace)) { Pause-ForUser; return }

    # ---- 进 9008 / 读分区表 ----
    Say ''
    Say '  [INFO] 进 9008' 'Cyan'
    $port = Wait-9008
    $geo  = Read-PartitionGeometry $port

    # ---- 稀疏转 raw（只读备份，产物放暂存区）----
    $stageRaw = Join-Path $C.StageDir 'restore_system.raw.img'
    if (Test-Path -LiteralPath $stageRaw) { Remove-Item -LiteralPath $stageRaw -Force }
    if (Test-SparseFile $bak.SystemImg) {
        Info '稀疏转 raw'
        [void](Run-Tee (Join-Path $C.ToolDir 'simg2img.exe') @($bak.SystemImg, $stageRaw) 'restore_simg2img')
    } else {
        Info '复制 raw'
        Copy-Item -LiteralPath $bak.SystemImg -Destination $stageRaw -Force
    }
    if (-not (Test-Path -LiteralPath $stageRaw)) { Err '还原成 raw 失败，已中止'; Pause-ForUser; return }
    $rawBytes = (Get-Item -LiteralPath $stageRaw).Length

    # ---- 尺寸校验：不通过就中止，绝不生成 XML ----
    if ($bak.HasMeta) {
        $metaBytes = [int64]$bak.Meta.systemBytes
        if ($metaBytes -ne $geo.SystemBytes) {
            Err ('备份 system ' + $metaBytes + ' != 手机 ' + $geo.SystemBytes)
            Err '备份与手机不匹配, 已中止'
            Pause-ForUser; return
        }
        if ($rawBytes -ne $metaBytes) {
            Err ('raw ' + $rawBytes + ' != 备份记录 ' + $metaBytes)
            Err '备份不完整, 已中止'
            Pause-ForUser; return
        }
    } else {
        if ($rawBytes -ne $geo.SystemBytes) {
            Err ('raw ' + $rawBytes + ' != 手机 system ' + $geo.SystemBytes)
            Err '尺寸不符, 已中止'
            Pause-ForUser; return
        }
    }
    Ok ('尺寸校验通过 ' + $rawBytes)

    $bootInfo = $null
    if ($doBoot) {
        $stageBoot = Join-Path $C.StageDir 'restore_boot.img'
        if (Test-Path -LiteralPath $stageBoot) { Remove-Item -LiteralPath $stageBoot -Force }
        Copy-Item -LiteralPath $bak.BootImg -Destination $stageBoot -Force
        $bootBytes = (Get-Item -LiteralPath $stageBoot).Length
        $wantBoot = [int64]($geo.BootSectors * 512)
        if ($bootBytes -ne $wantBoot) {
            Err ('备份 boot ' + $bootBytes + ' != 手机 boot ' + $wantBoot)
            Err '尺寸不符, 已中止'
            Pause-ForUser; return
        }
        $bootInfo = [pscustomobject]@{ Path = $stageBoot; Name = 'restore_boot.img'; Sectors = $geo.BootSectors }
    }

    # ---- 生成 restore XML 并过白名单闸门 ----
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<?xml version="1.0" ?>')
    $lines.Add('<data>')
    $lines.Add('  <program SECTOR_SIZE_IN_BYTES="512" filename="restore_system.raw.img" label="system" physical_partition_number="0" start_sector="' + $geo.SystemStart + '" num_partition_sectors="' + $geo.SystemSectors + '" sparse="false" />')
    if ($bootInfo) {
        $lines.Add('  <program SECTOR_SIZE_IN_BYTES="512" filename="' + $bootInfo.Name + '" label="boot" physical_partition_number="0" start_sector="' + $geo.BootStart + '" num_partition_sectors="' + $bootInfo.Sectors + '" sparse="false" />')
    }
    $lines.Add('</data>')
    $body = ($lines -join "`n") + "`n"
    Assert-ProgramLabels -XmlBody $body -Allowed @('system', 'boot')

    $xml = Join-Path $C.StageDir 'restore.xml'
    [IO.File]::WriteAllText($xml, $body, (New-Object Text.UTF8Encoding($false)))
    Info '已生成 restore.xml'

    if (-not (Ask ('确认写入？' + $(if ($bootInfo) { ' system + boot' } else { ' 只 system' })) 'n')) {
        Say '  已取消.' 'Yellow'; Pause-ForUser; return
    }

    Warn '写入中 3.75GB, 别拔线别按电源键'
    $r = Invoke-FhProgram -port $port -xmlPath $xml -searchPath $C.StageDir -logName 'rescue'
    if (-not (($r.Text -match '\{SUCCESS\}') -and ($r.Text -match 'All Finished Successfully'))) {
        Err '没看到成功标记'
        Say ('  日志: ' + (Get-LogPath)) 'Cyan'
        if (-not (Ask '仍然继续重启吗？' 'n')) { throw '救砖未确认成功，已停止' }
    } else {
        Ok '恢复写入成功'
    }

    Info '发送重启'
    if (Reset-Device -port $port) { Ok '已重启' } else { Warn '请长按电源键开机' }

    # 清掉大中间产物（备份目录只读，没动过）
    if (Test-Path -LiteralPath $stageRaw) { Remove-Item -LiteralPath $stageRaw -Force }
    if ($bootInfo -and (Test-Path -LiteralPath $bootInfo.Path)) { Remove-Item -LiteralPath $bootInfo.Path -Force }

    [void](Wait-Boot)
    Pause-ForUser
}
