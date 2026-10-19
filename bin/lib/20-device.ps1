# ============================================================
#  lib\20-device.ps1   阶段1~4
#     Get-DeviceInfo        读机型/固件（adb）
#     Test-Gate             安全门：型号必须 PBAM00；固件版本只影响提示，都会现场制作镜像
#     Wait-9008             中文引导 + 自动识别 9008 端口
#     Push-Sahara           推送 Firehose 引导（devprg_450）
#     Read-PartitionGeometry 读 GPT，拿 system / boot 的真实起止扇区
#     Backup-Partitions     刷前备份（boot raw + system 稀疏化）
# ============================================================

function Get-DeviceInfo {
    if ((Adb-Devices).Count -eq 0) {
        Warn '手机没有通过 adb 连接'
        return $null
    }
    $d = [ordered]@{
        Model = (Get-Prop 'ro.product.model')
        Brand = (Get-Prop 'ro.product.brand')
        Build = (Get-Prop 'ro.build.display.id')
        Sdk   = (Get-Prop 'ro.build.version.sdk')
    }
    return [pscustomobject]$d
}

function Test-Gate {
    param($dev)
    if (-not $dev) {
        Say ''
        Say '  读不到机型。这台必须是 OPPO A5 2018 PBAM00，刷错镜像会开不了机。' 'Red'
        return (Ask '确认是 PBAM00？' 'n')
    }
    Info ('机型 ' + $dev.Model + ' / ' + $dev.Build + ' / SDK ' + $dev.Sdk)

    if ($dev.Model -ne 'PBAM00') {
        Err ('机型是 ' + $dev.Model + '，不是 PBAM00，已停止')
        return $false
    }
    Ok '机型 OK'

    if ($dev.Build -notmatch 'A\.35') {
        Warn ('固件不是 A.35: ' + $dev.Build + ', 现场做镜像约 8~10 分钟')
        if (-not (Ask '继续？' 'y')) { return $false }
    }
    return $true
}

function Wait-9008 {
    Say ''
    Say '  让手机进入 9008：' 'White'
    Say '   1) 关机：长按电源键 10~15 秒，屏幕全黑' 'White'
    Say '   2) 同时按住 电源 + 音量上 + 音量下，别松手' 'White'
    Say '   3) 保持按住，插数据线，3 秒后可松手' 'White'
    Say '   4) 设备管理器出现 Qualcomm HS-USB QDLoader 9008 就成了' 'White'
    Say ''
    Warn '9008 下屏幕是黑的，正常。全程别拔线、别按电源键、别开其它刷机软件。'
    Say ''

    $t0 = Get-Date
    $port = $null
    Say '  不限时间；随时可按 Ctrl+C 停。' 'DarkGray'
    $nextHint = 60
    Write-Host '  正在等待 9008 设备 ' -NoNewline -ForegroundColor Cyan
    while ($true) {
        $port = Find-9008Port
        if ($port) { break }
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 500
        $el = [int]((Get-Date) - $t0).TotalSeconds
        if ($el -ge $nextHint) {
            $nextHint += 60
            Write-Host ''
            Warn ('等了 ' + $el + ' 秒还没看到 9008，确认：')
            Say '  真关机 / 三键同按才插线 / 换数据线 / 驱动装好 / 关掉别的刷机软件' 'DarkGray'
            Write-Host '  正在等待 9008 设备 ' -NoNewline -ForegroundColor Cyan
        }
    }
    Write-Host ''
    Ok ('9008 已识别：COM' + $port)
    Add-Log ("9008 端口: COM$port")
    return $port
}

function Push-Sahara {
    param([int]$port)
    $qs = Get-StageTool 'QSaharaServer.exe'
    $ds = Get-StageTool 'devprg_450'
    Info '推送引导 devprg_450 ...'
    $r = Run-Tee $qs @('-p', ('\\.\COM' + $port), '-s', ('13:' + $ds)) 'sahara'
    if ($r.Text -match 'Sahara protocol error' -or $r.Text -match 'FIREHOSE MODE DETECTED') {
        Warn '已在 Firehose 状态, 正常'
    }
    if ($r.Code -ne 0 -and -not ($r.Text -match 'FIREHOSE')) {
        Warn ("QSaharaServer 返回码 " + $r.Code)
    }
    return $true
}

function Parse-Gpt {
    param([string]$file)
    $b = [IO.File]::ReadAllBytes($file)
    if ($b.Length -lt 2048) { throw ('GPT 文件太小: ' + $file) }
    $sig = [Text.Encoding]::ASCII.GetString($b, 512, 8)
    if ($sig -ne 'EFI PART') { throw 'GPT 解析失败：偏移 512 处没有 EFI PART 签名' }
    $entryLba = [BitConverter]::ToUInt64($b, 512 + 72)
    $numEnt   = [BitConverter]::ToUInt32($b, 512 + 80)
    $entSize  = [BitConverter]::ToUInt32($b, 512 + 84)
    # 头字段合理性校验：GPT 头是设备上读回来的裸数据，脏了的话直接进循环会挂死
    # （实测：entSize=0 + numEnt 很大 → 死循环）或抛出难看的 .NET 转换异常
    # （实测：entryLba 极大 → "无法将值 2.36E+21 转换为类型 Int32"）。
    # 这两种都不是用户能理解的信息，所以在这里用中文拦下。
    if ($entSize -lt 128 -or $entSize -gt 4096)     { throw ('GPT 解析失败: 条目大小 ' + $entSize + ' 字节') }
    if ($numEnt  -lt 1   -or $numEnt  -gt 4096)     { throw ('GPT 解析失败: 条目数量 ' + $numEnt + ' 条') }
    if ($entryLba -lt 1  -or $entryLba -gt 1048575) { throw ('GPT 解析失败: 起始 LBA ' + $entryLba) }
    $base = [int]($entryLba * 512)
    if ($base -lt 512 -or $base -ge $b.Length)      { throw ('GPT 解析失败: 起始偏移 ' + $base) }
    $list = @()
    for ($i = 0; $i -lt $numEnt; $i++) {
        $o = $base + $i * $entSize
        if (($o + 128) -gt $b.Length) { break }
        $first = [BitConverter]::ToUInt64($b, $o + 32)
        $last  = [BitConverter]::ToUInt64($b, $o + 40)
        if ($first -eq 0) { continue }
        $name = [Text.Encoding]::Unicode.GetString($b, $o + 56, 72)
        $name = $name.Trim([char]0).Trim()
        $list += [pscustomobject]@{ Name = $name; Start = $first; Sectors = ($last - $first + 1) }
    }
    return $list
}

function Read-PartitionGeometry {
    param([int]$port)
    Push-Sahara $port | Out-Null

    $fh  = Get-StageTool 'fh_loader.exe'
    $gpt = Join-Path $C.StageDir 'gpt_main.bin'
    if (Test-Path $gpt) { Remove-Item $gpt -Force }
    $xml = Join-Path $C.StageDir 'read-gpt.xml'
    $xmlBody = @'
<?xml version="1.0" ?>
<data>
  <read SECTOR_SIZE_IN_BYTES="512" filename="gpt_main.bin" label="PrimaryGPT" physical_partition_number="0" start_sector="0" num_partition_sectors="34" />
</data>
'@
    [IO.File]::WriteAllText($xml, ($xmlBody -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))

    Info '读分区表 ...'
    $r = Run-Tee $fh @(
        ('--port=\\.\COM' + $port), '--memoryname=emmc',
        ('--search_path=' + $C.StageDir), ('--sendxml=' + $xml),
        ('--mainoutputdir=' + $C.StageDir), '--noprompt'
    ) 'readgpt'

    if (-not (Test-Path $gpt)) { throw '读取 GPT 失败，没生成 gpt_main.bin' }
    $parts = Parse-Gpt $gpt
    if ($parts.Count -lt 5) { throw ('GPT 解析结果异常，只拿到 ' + $parts.Count + ' 个分区') }

    Say ''
    Say '  分区表 前 20 项:' 'DarkGray'
    $parts | Select-Object -First 20 | ForEach-Object {
        Say ("    {0,-20} 起 {1,-9} 扇区 {2,-9} {3} MB" -f $_.Name, $_.Start, $_.Sectors, [math]::Round($_.Sectors * 512 / 1MB, 1)) 'DarkGray'
    }
    Say ''

    $sys  = $parts | Where-Object { $_.Name -eq 'system' } | Select-Object -First 1
    $boot = $parts | Where-Object { $_.Name -eq 'boot' }   | Select-Object -First 1
    if (-not $sys)  { throw '分区表里找不到 system 分区' }
    if (-not $boot) { throw '分区表里找不到 boot 分区' }

    Ok ("system: 起 " + $sys.Start + " 扇区数 " + $sys.Sectors + " / " + [math]::Round($sys.Sectors * 512 / 1MB, 1) + " MB")
    Ok ("boot: 起 " + $boot.Start + " 扇区数 " + $boot.Sectors + " / " + [math]::Round($boot.Sectors * 512 / 1MB, 1) + " MB")

    return [pscustomobject]@{
        SystemStart   = [int64]$sys.Start
        SystemSectors = [int64]$sys.Sectors
        SystemBytes   = [int64]($sys.Sectors * 512)
        BootStart     = [int64]$boot.Start
        BootSectors   = [int64]$boot.Sectors
        All           = $parts
    }
}

# 备份保留上限：只保留最近 $Keep 份「时间戳目录」，更旧的先打印再删除。
# 只认 yyyyMMdd-HHmm 形式的名字，绝不碰用户在 bin\backup 里放的其它东西；
# $Protect 指定的目录（本次刚生成的那份）永远不会被删。
function Remove-OldBackups {
    param([int]$Keep = 3, [string]$Protect = '')

    if (-not (Test-Path -LiteralPath $C.BakDir)) { return }
    $dirs = @(Get-ChildItem -LiteralPath $C.BakDir -Directory -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d{8}-\d{4}(\d{2})?(-\d+)?$' } |
              Sort-Object Name -Descending)
    if ($dirs.Count -le $Keep) { return }

    $toDel = @($dirs | Select-Object -Skip $Keep | Where-Object { $_.FullName -ne $Protect })
    if ($toDel.Count -eq 0) { return }

    Warn ('只保留最近 ' + $Keep + ' 份备份，下面这些将被删除：')
    foreach ($d in $toDel) {
        $sz = 0L
        try { $sz = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum } catch {}
        Say ('  - ' + $d.Name + '  ' + [math]::Round($sz / 1MB, 1) + ' MB  (' + $d.FullName + ')') 'DarkGray'
    }
    foreach ($d in $toDel) {
        try {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
            Add-Log ('已删除旧备份: ' + $d.FullName)
            Ok ('已删除: ' + $d.Name)
        } catch {
            Warn ('删不掉: ' + $d.Name)
        }
    }
}

function Backup-Partitions {
    param([int]$port, $geo, $dev)
    if ($Global:SkipBak) {
        Warn '跳过原机备份，出问题没法刷回'
        return $null
    }

    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $dir = Join-Path $C.BakDir $stamp
    $n = 1
    while (Test-Path -LiteralPath $dir) { $n++; $dir = Join-Path $C.BakDir ($stamp + '-' + $n) }
    $tag = Split-Path $dir -Leaf
    New-Item -ItemType Directory -Path $dir | Out-Null
    $fh  = Get-StageTool 'fh_loader.exe'
    $mki = Join-Path $C.ToolDir 'img2simg.exe'

    # ---- boot（小，直接 raw）----
    Info '备份 boot 分区'
    $xmlBoot = Join-Path $C.StageDir 'read-boot.xml'
    $xb = @"
<?xml version="1.0" ?>
<data>
  <read SECTOR_SIZE_IN_BYTES="512" filename="boot_stock.img" label="boot" physical_partition_number="0" start_sector="$($geo.BootStart)" num_partition_sectors="$($geo.BootSectors)" />
</data>
"@
    [IO.File]::WriteAllText($xmlBoot, ($xb -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    [void](Run-Tee $fh @(
        ('--port=\\.\COM' + $port), '--memoryname=emmc',
        ('--search_path=' + $C.StageDir), ('--sendxml=' + $xmlBoot),
        ('--mainoutputdir=' + $C.StageDir), '--noprompt', '--showpercentagecomplete'
    ) 'bakboot')
    if (Test-Path (Join-Path $C.StageDir 'boot_stock.img')) { Move-Item (Join-Path $C.StageDir 'boot_stock.img') (Join-Path $dir 'boot_stock.img') -Force; Ok 'boot 备份完成' } else { Warn 'boot 备份没成功，继续' }

    # ---- system（大，先 raw 再稀疏化）----
    Info '备份 system 分区，别拔线'
    $xmlSys = Join-Path $C.StageDir 'read-system.xml'
    $xs = @"
<?xml version="1.0" ?>
<data>
  <read SECTOR_SIZE_IN_BYTES="512" filename="system_stock.raw.img" label="system" physical_partition_number="0" start_sector="$($geo.SystemStart)" num_partition_sectors="$($geo.SystemSectors)" />
</data>
"@
    [IO.File]::WriteAllText($xmlSys, ($xs -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    [void](Run-Tee $fh @(
        ('--port=\\.\COM' + $port), '--memoryname=emmc',
        ('--search_path=' + $C.StageDir), ('--sendxml=' + $xmlSys),
        ('--mainoutputdir=' + $C.StageDir), '--noprompt', '--showpercentagecomplete'
    ) 'baksys')

    $raw = Join-Path $C.StageDir 'system_stock.raw.img'
    if (-not (Test-Path $raw)) { throw 'system 备份失败：没生成 raw 文件' }
    # 尺寸校验：回读中断（拔线/供电不稳）时 fh_loader 仍会留下一个「看起来正常」的短文件，
    # 旧代码只判断存在性就接受它，于是这份短备份会被当成好备份：后面做出来的镜像也偏小，
    # 刷进去只会把 system 尾部新数据之外的部分留成旧数据（混合状态，比直接失败更危险）。
    $rawLen = (Get-Item $raw).Length
    $needBytes = [int64]$geo.SystemBytes
    if ($rawLen -lt $needBytes) {
        Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue
        throw ('回读不完整：只有 ' + $rawLen + ' 字节，分区是 ' + $needBytes + ' 字节。已丢弃，检查数据线后重来。')
    }
    if ($rawLen -gt $needBytes) { Warn ('回读多了 ' + ($rawLen - $needBytes) + ' 字节，按分区大小用') }
    $rawMB = [math]::Round($rawLen / 1MB, 1)
    Ok ('system 备份 ' + $rawMB + ' MB')

    # 稀疏化，省空间
    $sparse = Join-Path $C.StageDir 'system_stock.img'
    $keptSparse = $false
    if (Test-Path $mki) {
        Info '稀疏化'
        $rs = Run-Tee $mki @($raw, $sparse) 'simg'
        if (Test-Path $sparse) {
            $smb = [math]::Round((Get-Item $sparse).Length / 1MB, 1)
            Remove-Item $raw -Force
            $keptSparse = $true
            Ok ('稀疏化后 ' + $smb + ' MB')
        } else {
            Warn '稀疏化失败，保留 raw'
        }
    } else {
        Warn '没有 img2simg.exe，保留 raw'
    }
    # 不管稀疏成功还是失败，都必须把文件真正搬进备份目录。
    # 旧代码在失败分支里只把 raw 挪到暂存区的 system_stock.img，运行结束时暂存区被整体清空，
    # 于是「提示保留 raw 备份」而实际 3.75GB 备份被丢掉，返回的 SystemImg 还指向不存在的文件。
    $bakImg = Join-Path $dir 'system_stock.img'
    if ($keptSparse) { Move-Item -LiteralPath $sparse -Destination $bakImg -Force }
    else             { Move-Item -LiteralPath $raw    -Destination $bakImg -Force }

    # ---- 机器可读的元数据（救砖靠它校验尺寸/认机型）----
    $bootFile = Join-Path $dir 'boot_stock.img'
    $bootBytes = 0L
    if (Test-Path -LiteralPath $bootFile) { $bootBytes = (Get-Item -LiteralPath $bootFile).Length }
    $fileSize = [ordered]@{}
    foreach ($fn in @('system_stock.img', 'boot_stock.img')) {
        $fp = Join-Path $dir $fn
        if (Test-Path -LiteralPath $fp) { $fileSize[$fn] = (Get-Item -LiteralPath $fp).Length } else { $fileSize[$fn] = 0 }
    }
    $meta = [ordered]@{
        toolkit           = 'OPPOA5-EasyRoot'
        version           = '1.0'
        backupTime        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        backupDir         = $tag
        model             = $(if ($dev -and $dev.Model) { [string]$dev.Model } else { '' })
        brand             = $(if ($dev -and $dev.Brand) { [string]$dev.Brand } else { '' })
        firmware          = $(if ($dev -and $dev.Build) { [string]$dev.Build } else { '' })
        androidSdk        = $(if ($dev -and $dev.Sdk) { [string]$dev.Sdk } else { '' })
        systemStartSector = [int64]$geo.SystemStart
        systemSectors     = [int64]$geo.SystemSectors
        systemBytes       = [int64]$geo.SystemBytes
        bootStartSector   = [int64]$geo.BootStart
        bootSectors       = [int64]$geo.BootSectors
        bootBytes         = [int64]$bootBytes
        systemSparse      = [bool]$keptSparse
        files             = $fileSize
    }
    [IO.File]::WriteAllText((Join-Path $dir 'backup.json'), ($meta | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    # ---- 救砖说明（指向菜单的 2. 一键救砖；手工命令给绝对路径）----
    $sysRef = $(if ($keptSparse) { 'system_stock.raw.img' } else { 'system_stock.img' })
    $fmtTxt = $(if ($keptSparse) { '稀疏格式' } else { 'raw 格式' })
    $step2  = $(if ($keptSparse) {
        '     a) 备份是稀疏格式，先转 raw：' + "`r`n" +
        '        ' + $C.ToolDir + '\simg2img.exe "' + $dir + '\system_stock.img" "' + $dir + '\system_stock.raw.img"'
    } else {
        '     a) 备份是 raw，不需要转换，XML 里直接用 system_stock.img'
    })
    $restoreTxt = @"
OPPO A5 原机备份  $tag
=========================
这是刷机【之前】从这台手机回读出来的分区，出问题时用它刷回。

包含：
  boot_stock.img        boot 分区 $([math]::Round($bootBytes / 1MB, 0)) MB
  system_stock.img      system 分区 $fmtTxt
  backup.json           机型 / 固件 / 分区大小

原机分区:
  system: 起始扇区 $($geo.SystemStart)，共 $($geo.SystemSectors) 扇区 / $([math]::Round($geo.SystemBytes / 1MB, 1)) MB
  boot  : 起始扇区 $($geo.BootStart)，共 $($geo.BootSectors) 扇区

怎么刷回：
  1) 打开工具箱，菜单选「2. 一键救砖」，挑这份备份，按提示走。
  2) 万一要手工，COM 口按设备管理器里 "Qualcomm HS-USB QDLoader 9008" 的数字改：

$step2
     b) 把下面内容存成本目录下的 restore.xml：
     <?xml version="1.0" ?>
     <data>
       <program SECTOR_SIZE_IN_BYTES="512" filename="$sysRef" label="system" physical_partition_number="0" start_sector="$($geo.SystemStart)" num_partition_sectors="$($geo.SystemSectors)" sparse="false" />
     </data>
     c) 推引导：
     $($C.ToolDir)\QSaharaServer.exe -p \\.\COMx -s 13:"$($C.ToolDir)\devprg_450"
     d) 写入，--search_path 指向本备份目录，XML 里的 filename 相对它：
     $($C.ToolDir)\fh_loader.exe --port=\\.\COMx --memoryname=emmc --search_path="$dir" --sendxml="$dir\restore.xml" --mainoutputdir="$dir" --noprompt --showpercentagecomplete
     e) 重启：
     $($C.ToolDir)\fh_loader.exe --port=\\.\COMx --memoryname=emmc --search_path="$($C.ToolDir)" --sendxml="$($C.ToolDir)\reset.xml" --mainoutputdir="$($C.ToolDir)" --noprompt

成功标志：输出里同时出现 {SUCCESS} 和 All Finished Successfully。
"@
    [IO.File]::WriteAllText((Join-Path $dir 'RESTORE.txt'), $restoreTxt, (New-Object Text.UTF8Encoding($true)))

    Ok ('备份已保存：' + $dir)    # 只保留最近 3 份备份（只认自己生成的时间戳目录，本次这份受保护）
    Remove-OldBackups -Keep 3 -Protect $dir
    return [pscustomobject]@{ Dir = $dir; SystemImg = (Join-Path $dir 'system_stock.img'); BootImg = (Join-Path $dir 'boot_stock.img') }
}
