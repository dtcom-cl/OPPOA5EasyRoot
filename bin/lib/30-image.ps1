# ============================================================
#  lib\30-image.ps1   阶段5：制作要刷入的镜像
#     Resolve-SystemImage   永远走现场制作：基于本机备份的原机 system 做一份匹配镜像
#                           （不再存在任何「读取现成镜像」的分支）
#     New-SystemImage       用本机原版 system 制作「原厂 system + 内置 Magisk」
#
#  制作流程（每一步都是本项目实测验证过的）：
#    ① 备份的稀疏镜像 → raw（①结束后立刻删掉备份副本，省一次 2.4GB 的驻留）
#    ② imgkit 解包 → 文件树 + fs_config/file_contexts（②结束后删掉 raw）
#    ③ 注入 MOS 载荷（setup-magisk.sh / magisk.rc / etc/magisk/*）
#    ④ 补 magisk32（32 位 Zygisk 必需）
#    ⑤ 放 env_check / fix_env 桩（治 Magisk App「需要修复运行环境」探测）
#    ⑥ prop.default 补丁（ro.secure=0 / ro.adb.secure=0 / ro.debuggable=1）
#    ⑦ 合并配置：前缀换成 AOSP 的 system/ 与 /system/，逐条追加新文件权限+标签
#    ⑧ make_ext4fs 按原分区字节数重打包（⑧成功后删掉解包树）
#    ⑨ 反向解包自检，任何一项不过就报错停止（绝不刷入未验证的镜像）
# 说明：中间产物「用完即删」是为了压低磁盘峰值（实测峰值从约 17.0GB 降到约 8.6GB），
#       删的每一个文件在删除点之后都不再被读取。
# ============================================================

function Resolve-SystemImage {
    param($dev, $bak)
    # 本工具箱不再使用任何现成镜像：每次都基于这台手机自己的 system 现场制作匹配镜像。
    # （$dev 保留在参数里是为了不改调用方签名；实际分支不再依赖固件版本。）
    if (-not $bak) { throw '做镜像要先有原机备份，别用 -SkipBackup' }
    $miss = @(Get-MissingMakeTools)
    if ($miss.Count -gt 0) {
        Err ('缺工具: ' + ($miss -join '、'))
        foreach ($m in $miss) { Say ('         期望路径: ' + (Join-Path $C.ToolDir $m)) 'DarkGray' }
        throw '缺工具，已停止'
    }
    try {
        return (New-SystemImage -Bak $bak -Dev $dev)
    } catch {
        # 制作失败时特别提醒：bin\images 里可能还躺着以前做好的镜像，别拿旧镜像去刷
        $oldImgs = @(Get-ChildItem -LiteralPath $C.OutDir -Filter '*.img' -File -Force -ErrorAction SilentlyContinue)
        if ($oldImgs.Count -gt 0) {
            Warn ('这次做镜像失败了。下面这些是以前做的，别拿旧的刷：')
            $oldImgs | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
                Say ('  ' + $_.Name + '  ' + [math]::Round($_.Length / 1GB, 2) + ' GB  ' + $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) 'DarkGray'
            }
        }
        throw
    }
}

function New-SystemImage {
    param($Bak, $dev)

    $mk     = $C.ToolDir
    $imgkit = Join-Path $mk 'imgkit.exe'
    $mkfs   = Join-Path $mk 'make_ext4fs.exe'
    $s2i    = Join-Path $mk 'simg2img.exe'
    if (-not (Test-Path $imgkit)) { throw ('缺少 imgkit.exe: ' + $imgkit) }
    if (-not (Test-Path $mkfs))   { throw ('缺少 make_ext4fs.exe: ' + $mkfs) }

    $work = Join-Path $C.StageDir 'build'          # imgkit 解包输出目录（-c 会清空这里，输入文件不能放里面）
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    # ---------- ① 源镜像转 raw ----------
    # 注意：$src / $raw 必须放在 $work 之外。imgkit unpack 带 -c 时会清空输出目录，
    #      输入文件若在输出目录里会被它自己删掉（实测：imgkit 探测到文件系统类型后立刻清目录）。
    $src = Join-Path $C.StageDir ('bak_' + (Split-Path $Bak.SystemImg -Leaf))
    Copy-Item -LiteralPath $Bak.SystemImg -Destination $src -Force
    $raw = Join-Path $C.StageDir 'base_raw.img'
    Info '准备原版 system 镜像'
    $fsH = [IO.File]::OpenRead($src)
    $bytes = New-Object byte[] 4
    [void]$fsH.Read($bytes, 0, 4)
    $fsH.Close()
    # 稀疏镜像判断：Android sparse 魔数 0xED26FF3A，小端写进文件就是 3A FF 26 ED
    # （旧代码写成 3A ED 26 FF，永远判不出来 → 稀疏备份被当 raw 直接拷，
    #  重打包时按稀疏文件大小建文件系统，必然 "out of space" 失败。实测踩过。）
    $isSparse = ($bytes.Length -ge 4 -and $bytes[0] -eq 0x3A -and $bytes[1] -eq 0xFF -and $bytes[2] -eq 0x26 -and $bytes[3] -eq 0xED)
    if ($isSparse) {
        if (-not (Test-Path $s2i)) { throw '备份是稀疏格式，但缺少 simg2img.exe，无法还原' }
        Info '  稀疏转 raw'
        [void](Run-Tee $s2i @($src, $raw) 'simg2img')
    } else {
        Copy-Item $src $raw -Force
    }
    if (-not (Test-Path $raw)) { throw '准备 raw 镜像失败' }
    # 再自检一次：raw 里绝不能还是稀疏魔数（否则后面会按错大小打包）
    $h2 = [IO.File]::OpenRead($raw)
    $chk4 = New-Object byte[] 4
    [void]$h2.Read($chk4, 0, 4)
    $h2.Close()
    if ($chk4[0] -eq 0x3A -and $chk4[1] -eq 0xFF -and $chk4[2] -eq 0x26 -and $chk4[3] -eq 0xED) {
        throw '备份没转成 raw，已停止'
    }
    $rawBytes = (Get-Item $raw).Length
    $rawGB = [math]::Round($rawBytes / 1GB, 2)
    Ok ('raw 就绪 ' + $rawGB + ' GB')
    # 备份副本只用来转 raw，转完就可以删（后面只读 $raw / $rawBytes），省约 2.4GB 磁盘峰值
    if (Test-Path $src) { Remove-Item -LiteralPath $src -Force }

    # ---------- ② 解包 ----------
    Info '解包 system'
    $r = Run-Tee $imgkit @('unpack', '-i', $raw, '-o', $work, '-l', '1', '-c') 'unpack'
    $tree = (Get-ChildItem $work -Directory | Where-Object { $_.Name -ne 'config' } | Select-Object -First 1)
    if (-not $tree) { throw '解包失败，见日志' }
    $treePath = $tree.FullName
    $imgName  = $tree.Name
    $fileCount0 = (Get-ChildItem $treePath -Recurse -File).Count
    Ok ('解包完成，' + $fileCount0 + ' 个文件')
    # 解包完成后 raw 不再被读取（重打包用的是 $rawBytes），删掉省约 3.8GB 磁盘峰值
    if (Test-Path $raw) { Remove-Item -LiteralPath $raw -Force }

    $cfgSrc = Join-Path $work 'config'
    $fsc = Get-ChildItem $cfgSrc -Filter '*_fs_config'     | Select-Object -First 1
    $fcl = Get-ChildItem $cfgSrc -Filter '*_file_contexts' | Select-Object -First 1
    if (-not $fsc -or -not $fcl) { throw '解包没生成 fs_config / file_contexts' }

    # ---------- ③ 注入 MOS 载荷 ----------
    Info '注入 Magisk 载荷'
    $payload = Join-Path $C.RefDir 'extracted'
    $etcSrc  = Join-Path $payload 'etc'
    $etcDst  = Join-Path $treePath 'etc'
    if (-not (Test-Path $etcDst)) { New-Item -ItemType Directory -Force -Path $etcDst | Out-Null }
    Copy-Item (Join-Path $etcSrc 'setup-magisk.sh') (Join-Path $etcDst 'setup-magisk.sh') -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $etcDst 'init') | Out-Null
    Copy-Item (Join-Path $etcSrc 'init\magisk.rc') (Join-Path $etcDst 'init\magisk.rc') -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $etcDst 'magisk') | Out-Null
    Get-ChildItem (Join-Path $etcSrc 'magisk') -File | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $etcDst ('magisk\' + $_.Name)) -Force
    }

    # ---------- ④ 补 magisk32 ----------
    $m32 = Join-Path $C.RefDir 'magisk32_v27.0'
    if (Test-Path $m32) {
        Copy-Item $m32 (Join-Path $etcDst 'magisk\magisk32') -Force
        Ok '已补 magisk32'
    } else { Warn '没有 magisk32_v27.0，32 位 Zygisk 不可用' }

    # ---------- ⑤ env_check / fix_env 桩 ----------
    $stub = "#!/system/bin/sh`nexit 0`n"
    $stubPaths = @('bin\env_check', 'bin\fix_env', 'xbin\env_check', 'xbin\fix_env')
    foreach ($sp in $stubPaths) {
        $d = Join-Path $treePath (Split-Path $sp -Parent)
        if (Test-Path $d) {
            [IO.File]::WriteAllText((Join-Path $treePath $sp), $stub, (New-Object Text.UTF8Encoding($false)))
        }
    }
    Ok '已放 env_check / fix_env 桩'

    # ---------- ⑥ prop.default 补丁 ----------
    $propPath = Join-Path $treePath 'etc\prop.default'
    if (Test-Path $propPath) {
        $lines = @(Get-Content -LiteralPath $propPath -Encoding UTF8)
        $want = [ordered]@{ 'ro.secure' = '0'; 'ro.adb.secure' = '0'; 'ro.debuggable' = '1' }
        foreach ($k in $want.Keys) {
            $idx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=')) { $idx = $i; break } }
            if ($idx -ge 0) { $lines[$idx] = ($k + '=' + $want[$k]) }
            else { $lines += ($k + '=' + $want[$k]) }
        }
        [IO.File]::WriteAllText($propPath, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        Ok 'prop.default 已打补丁'
    } else {
        Warn '这个固件没有 /system/etc/prop.default，adb root 可能不可用'
    }

    # ---------- ⑦ 合并配置 ----------
    Info '生成打包配置'

    # 前缀转换：<镜像名>/…  →  system/… ； /<镜像名>/… → /system/…
    # 注意 file_contexts 的兜底行是带正则的：/镜像名(/.*)? —— 它后面接的是 "(" 不是 "/"，
    # 只替换 "^/镜像名/" 会漏掉它，make_ext4fs 会直接报
    # "cannot lookup security context for /system/" 并拒绝打包（实测踩过，必须一起换）。
    $esc    = [regex]::Escape($imgName)
    $fsText = @(Get-Content -LiteralPath $fsc.FullName -Encoding UTF8)
    $fsText = $fsText -replace ('^' + $esc + '/'), 'system/'
    $fsText = $fsText -replace ('^' + $esc + '(?=\s)'), 'system'
    $fcText = @(Get-Content -LiteralPath $fcl.FullName -Encoding UTF8)
    $fcText = $fcText -replace ('^/' + $esc + '/'), '/system/'
    $fcText = $fcText -replace ('^/' + $esc + '\(/\.\*\)\?'), '/system(/.*)?'
    $fcText = $fcText -replace ('^/' + $esc + '(?=\s)'), '/system'
    $badPrefix = @($fsText | Where-Object { $_ -match ('^' + $esc + '[/\s]') }) +
                 @($fcText | Where-Object { $_ -match ('^/?' + $esc + '[/\s(]') })
    if ($badPrefix.Count -gt 0) {
        throw ('打包配置里有 ' + $badPrefix.Count + ' 行前缀没换掉，已停止')
    }
    # 找 /system/bin/sh 的标签作为 env_check 的标签（保证 App 能执行）
    $shLabel = 'u:object_r:shell_exec:s0'
    $shLine = $fcText | Where-Object { $_ -match '^\s*/system/bin/sh\s' } | Select-Object -First 1
    if ($shLine) { $shLabel = ($shLine -split '\s+')[1] }
    Add-Log ("env_check 使用标签: $shLabel")

    $fsAdd = New-Object System.Collections.Generic.List[string]
    $fcAdd = New-Object System.Collections.Generic.List[string]
    $fsAdd.Add('system/etc/setup-magisk.sh 0 0 0755')
    $fcAdd.Add('/system/etc/setup-magisk.sh u:object_r:system_file:s0')
    $fsAdd.Add('system/etc/init/magisk.rc 0 0 0644')
    $fcAdd.Add('/system/etc/init/magisk.rc u:object_r:system_file:s0')
    Get-ChildItem (Join-Path $etcDst 'magisk') -File | ForEach-Object {
        $mode = if ($_.Name -eq 'stub.apk') { '0644' } else { '0755' }
        $fsAdd.Add(('system/etc/magisk/{0} 0 0 {1}' -f $_.Name, $mode))
        $fcAdd.Add(('/system/etc/magisk/{0} u:object_r:system_file:s0' -f $_.Name))
    }
    foreach ($sp in $stubPaths) {
        $p = ($sp -replace '\\', '/')
        $full = Join-Path $treePath $sp
        if (Test-Path $full) {
            $fsAdd.Add(('system/{0} 0 0 0755' -f $p))
            $fcAdd.Add(('/system/{0} {1}' -f $p, $shLabel))
        }
    }

    $fsOut = Join-Path $work 'fs_config'
    $fcOut = Join-Path $work 'file_contexts'
    # 合并规则：同路径已存在就【替换】原来那条，不存在才追加。
    # 为什么必须去重：make_ext4fs 的 file_contexts 解析器遇到同一路径两条规格会直接报
    # "Multiple same specifications for ..." 并拒绝打包。原机 system 里本来就可能已经有
    # /system/bin/env_check、/system/xbin/fix_env 这类文件（MOS 桩就是冲它们去的），
    # 一旦撞上就会整包失败 —— 现在每次都要现场制作，这条必须处理掉。
    $fsMerged = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($fsText)) { [void]$fsMerged.Add($l) }
    $fsRepl = 0; $fsAppend = 0
    foreach ($add in $fsAdd) {
        $key = ($add -split '\s+')[0]
        $idx = -1
        for ($i = 0; $i -lt $fsMerged.Count; $i++) {
            if (($fsMerged[$i] -split '\s+')[0] -eq $key) { $idx = $i; break }
        }
        if ($idx -ge 0) { $fsMerged[$idx] = $add; $fsRepl++ } else { [void]$fsMerged.Add($add); $fsAppend++ }
    }

    $fcMerged = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($fcText)) { [void]$fcMerged.Add($l) }
    $fcRepl = 0; $fcAppend = 0
    foreach ($add in $fcAdd) {
        $key = ($add -split '\s+')[0]
        $idx = -1
        for ($i = 0; $i -lt $fcMerged.Count; $i++) {
            if (($fcMerged[$i] -split '\s+')[0] -eq $key) { $idx = $i; break }
        }
        if ($idx -ge 0) { $fcMerged[$idx] = $add; $fcRepl++ } else { [void]$fcMerged.Add($add); $fcAppend++ }
    }

    [IO.File]::WriteAllLines($fsOut, $fsMerged, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllLines($fcOut, $fcMerged, (New-Object Text.UTF8Encoding($false)))
    Ok ('配置 fs ' + @($fsText).Count + ' 行 / fc ' + @($fcText).Count + ' 行')

    # ---------- ⑧ 重打包 ----------
    $outImg = Join-Path $C.StageDir (($imgName -replace '_raw$', '') + '_magisk.img')
    if (Test-Path $outImg) { Remove-Item $outImg -Force }
    Info '重打包'
    $r2 = Run-Tee $mkfs @(
        '-l', "$rawBytes", '-a', '/system',
        '-S', $fcOut, '-C', $fsOut, '-L', 'system',
        $outImg, $treePath
    ) 'make_ext4fs' $work
    if (-not (Test-Path $outImg)) { throw '重打包失败，make_ext4fs 没出镜像' }
    $outBytes = (Get-Item $outImg).Length
    if ($outBytes -ne $rawBytes) {
        throw ('镜像大小不对：期望 ' + $rawBytes + ' 实际 ' + $outBytes + '')
    }
    Ok ('镜像已生成：' + [math]::Round($outBytes / 1GB, 2) + ' GB')
    # 重打包已成功，解包树后面不再被读取，删掉省约 2.4GB 磁盘峰值
    if (Test-Path $treePath) { Remove-Item -LiteralPath $treePath -Recurse -Force }

    # ---------- ⑨ 反向自检 ----------
    Info '反向解包自检'
    $verify = Join-Path (Get-AsciiWorkDir) 'verify'
    if (Test-Path $verify) { Remove-Item $verify -Recurse -Force }
    [void](Run-Tee $imgkit @('unpack', '-i', $outImg, '-o', $verify, '-l', '1', '-c') 'verify')
    $vTree = (Get-ChildItem $verify -Directory | Where-Object { $_.Name -ne 'config' } | Select-Object -First 1)
    $vCfg  = Join-Path $verify 'config'
    $vFs   = Get-ChildItem $vCfg -Filter '*_fs_config' | Select-Object -First 1
    $vFc   = Get-ChildItem $vCfg -Filter '*_file_contexts' | Select-Object -First 1
    $bad = 0
    if (-not $vTree) { Err '自检失败：镜像解不开'; $bad++ }

    if ($vFs) {
        $fsLines = Get-Content -LiteralPath $vFs.FullName -Encoding UTF8
        $checks = @(
            @{ k = 'etc/magisk/magisk32'; want = '0755'; n = 'magisk32 可执行' },
            @{ k = 'etc/magisk/magisk64'; want = '0755'; n = 'magisk64 可执行' },
            @{ k = 'etc/setup-magisk.sh'; want = '0755'; n = 'setup-magisk.sh 可执行' },
            @{ k = 'bin/env_check';       want = '0755'; n = 'env_check 可执行' },
            @{ k = 'bin/sh';              want = '0755'; n = 'bin/sh 权限正常' }
        )
        # 变量名不要用 $c：PowerShell 变量名大小写不敏感，$c 会覆盖全局配置 $C，
        # 导致后面读 $C.OutDir 拿到空值（实测踩过：成品镜像最后一步直接失败）
        foreach ($chk in $checks) {
            $hit = $fsLines | Where-Object { $_ -match ('/' + [regex]::Escape($chk.k) + '\s') } | Select-Object -First 1
            if ($hit -and $hit -match $chk.want) { Ok ('  ' + $chk.n) }
            else { Err ('  ' + $chk.n + ' -> 期望 ' + $chk.want + '，实际: ' + $hit); $bad++ }
        }
        $cnt = ($fsLines | Where-Object { $_ -notmatch '^#' -and $_.Trim() -ne '' }).Count
        Info ('  镜像内文件条目: ' + $cnt)
        if ($cnt -lt 1000) { Err '  条目太少，镜像可能不完整'; $bad++ }
    } else { Err '自检失败：读不到 fs_config'; $bad++ }

    if ($vFc) {
        $fcLines = Get-Content -LiteralPath $vFc.FullName -Encoding UTF8
        foreach ($k in @('bin/env_check', 'etc/magisk/magisk64')) {
            if (@($fcLines | Where-Object { $_ -match [regex]::Escape($k) }).Count -gt 0) { Ok ('  标签存在: ' + $k) }
            else { Warn ('  标签缺失: ' + $k) }
        }
    }

    if ($bad -gt 0) { throw ('镜像自检没通过: ' + $bad + ' 项，没刷。日志: ' + (Get-LogPath)) }
    Ok '自检通过，可以刷入'

    try {
        if (Test-Path $verify) { Remove-Item $verify -Recurse -Force }
        if (Test-Path $work)   { Remove-Item $work   -Recurse -Force }
    } catch {
        throw ('清理中间目录失败: ' + $_.Exception.Message + ' @' + $_.InvocationInfo.PositionMessage)
    }

    # 同卷时用 Move（瞬时改名，不再多占一份 3.8GB）；跨卷时 Move 会自动退化为复制+删除
    try {
        New-Item -ItemType Directory -Force -Path $C.OutDir | Out-Null
        # 产物名带上 机型 / 固件 / 时间戳：以前固定叫 base_magisk.img 而且直接覆盖，
        # 刷过几轮以后根本分不清哪份镜像是哪台机器、哪个固件做的。
        $modelTag = 'UNKNOWN'
        $fwTag    = 'UNKNOWN'
        if ($dev -and $dev.Model) { $modelTag = ($dev.Model -replace '[^A-Za-z0-9._-]', '_') }
        if ($dev -and $dev.Build) { $fwTag    = ($dev.Build -replace '[^A-Za-z0-9._-]', '_') }
        $finalName = 'system_' + $modelTag + '_' + $fwTag + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.img'
        $finalImg = Join-Path $C.OutDir $finalName
        if (Test-Path -LiteralPath $finalImg) { Remove-Item -LiteralPath $finalImg -Force }
        Move-Item -LiteralPath $outImg -Destination $finalImg -Force
    } catch {
        throw ('移动成品镜像失败: ' + $_.Exception.Message + ' @' + $_.InvocationInfo.PositionMessage)
    }
    return [pscustomobject]@{ Path = $finalImg; Built = $true; Bytes = $outBytes }
}
