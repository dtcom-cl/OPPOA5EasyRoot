# ============================================================
#  lib\00-公共.ps1   输出 / 日志 / 外部命令 / 设备操作 公共库
# ============================================================

$Global:LogFile = $null

# ---------------- 界面 ----------------
# 启动界面：原样打印 bin\ref\logo.txt，再打菜单；-Check 只打 logo 不进菜单。
function Show-Logo {
    try { Clear-Host } catch {}
    $logo = Join-Path $C.RefDir 'logo.txt'
    if (Test-Path -LiteralPath $logo) {
        Get-Content -LiteralPath $logo -Encoding UTF8 | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
    } else {
        Write-Host '  [logo.txt missing]' -ForegroundColor DarkGray
    }
    Write-Host ('=' + ('-' * 71)) -ForegroundColor DarkGray
    Write-Host ''
}

# 窗口标题：只在几个大阶段更新（参考项目的 TITLE 用法）
function Set-Title {
    param([string]$t)
    try { $Host.UI.RawUI.WindowTitle = $t } catch {}
}

function Show-About {
    Say ''
    Say '  Version 1.0' 'White'
    Say '  By ycgj' 'White'
    Say '  交流群 623908523' 'White'
    Say ''
    Pause-ForUser '回车返回菜单'
}

function Show-Menu {
    Show-Logo
    Write-Host '  [INFO] 请选择' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1.一键root' -ForegroundColor Green
    Write-Host ''
    Write-Host '  2.一键救砖' -ForegroundColor Green
    Write-Host ''
    Write-Host '  3.关于' -ForegroundColor Green
    Write-Host ''
}

function Add-Log {
    param([string]$m)
    if ($Global:LogFile) {
        try {
            $line = "[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $m
            [IO.File]::AppendAllText($Global:LogFile, $line, (New-Object Text.UTF8Encoding($false)))
        } catch {}
    }
}

function Init-Log {
    foreach ($d in @($C.LogDir, $C.BakDir, $C.WorkDir, $C.StageDir, $C.OutDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Global:LogFile = Join-Path $C.LogDir ("run-$stamp.log")
    Add-Log "==== OPPO A5 一键 Root 工具箱  开始 $stamp ===="
}

function Get-LogPath { return $Global:LogFile }

function Say {
    param([string]$m = '', [string]$color = 'Gray', [switch]$NoNewline)
    if ($NoNewline) { Write-Host $m -ForegroundColor $color -NoNewline }
    else            { Write-Host $m -ForegroundColor $color }
    Add-Log $m
}

function Step {
    param([int]$n, [string]$title)
    Write-Host ''
    Write-Host ("  [{0,2}/11]  {1}" -f $n, $title) -ForegroundColor Black -BackgroundColor Gray
    Add-Log ("===== [步骤 $n] $title =====")
}

function Ok   { param([string]$m) Say ("  [OK] " + $m) 'Green' }
function Warn { param([string]$m) Say ("  [WARN] " + $m) 'Yellow' }
function Err  { param([string]$m) Say ("  [ERROR] " + $m) 'Red' }
function Info { param([string]$m) Say ("  [INFO] " + $m) 'Cyan' }

function Ask {
    param([string]$q, [string]$def = 'n')
    if ($Global:AutoYes) {
        # -Yes 的语义是「自动采用默认值」，不是「一律回答 y」。
        # 默认 n 的三处确认（机型确认 / 尺寸不一致 / 刷写未确认成功）必须自动拦下，
        # 否则 -Yes 会把安全闸门全部跳过（旧代码无条件 return $true，属缺陷）。
        $ans = ($def -eq 'y')
        Info ("$q -> -Yes 自动采用默认值: " + $(if ($ans) { 'y' } else { 'n' }))
        Add-Log ("$q -> -Yes 自动采用默认值: " + $(if ($ans) { 'y' } else { 'n' }))
        return $ans
    }
    while ($true) {
        Write-Host ("  " + $q + $(if ($def -eq 'y') { ' [Y/n] ' } else { ' [y/N] ' })) -ForegroundColor Yellow -NoNewline
        $a = Read-Host
        if ([string]::IsNullOrWhiteSpace($a)) { $a = $def }
        switch ($a.Trim().ToLower()) {
            'y' { Add-Log "$q -> y"; return $true }
            'yes' { Add-Log "$q -> y"; return $true }
            'n' { Add-Log "$q -> n"; return $false }
            'no' { Add-Log "$q -> n"; return $false }
            default { Warn '请输入 y 或 n' }
        }
    }
}

# 读一行输入：Read-Host 在输入被重定向且已经读完时会返回 $null，
# 直接 .Trim() 会抛 "不能对 Null 值表达式调用方法"。这里统一兜住。
function Read-Line {
    param([string]$Prompt = '')
    $v = Read-Host $Prompt
    if ($null -eq $v) { return '' }
    return ([string]$v).Trim()
}

function Pause-ForUser {
    param([string]$msg = '完成后按回车继续')
    if ($Global:AutoYes) { return }
    Write-Host ("  [Tips] " + $msg + ' ') -ForegroundColor Yellow -NoNewline
    [void](Read-Host)
}

# ---------------- 暂存区（纯 ASCII 路径） ----------------
# 老式工具（fh_loader / QSaharaServer）不认中文路径，所以刷写用的中间产物一律放暂存区。
# 暂存区必须是「纯 ASCII 且不含空格」的绝对路径；优先与项目同卷，这样大镜像可以用硬链接，
# 不需要复制 3.8GB（跨卷硬链接必然失败，会退化为复制）。
# 同卷判定用真实硬链接探测得出，不按盘符字符串猜（subst / 挂载卷 / junction 都会让猜测出错）。

$Global:StageRoot       = $null
$Global:StageRootOurOwn = $false
$Global:StageReady      = $false
$Global:StageSameVolume = $false
$Global:StageNotes      = New-Object System.Collections.Generic.List[string]
$Global:StageProbeDirs  = New-Object System.Collections.Generic.List[string]

function Test-AsciiPath {
    param([string]$p)
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    return [bool]($p -match '^[A-Za-z0-9_\\:.\-]+$')
}

# 真实写入探测：建目录 + 写临时文件 + 删除，全部成功才算可用
function Test-DirWritable {
    param([string]$dir)
    $probe = $null
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
        $probe = Join-Path $dir ('w-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($probe, 'ok')
        if (-not (Test-Path -LiteralPath $probe)) { return $false }
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        if ($probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

# 真实硬链接探测：能把暂存区里的文件硬链接到项目内文件，才算同卷
function Test-SameVolumeAsProject {
    param([string]$dir)
    $src = Join-Path $C.WorkDir ('hl-src-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $dst = Join-Path $dir      ('hl-dst-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if (-not (Test-Path -LiteralPath $C.WorkDir)) { New-Item -ItemType Directory -Force -Path $C.WorkDir -ErrorAction Stop | Out-Null }
        [IO.File]::WriteAllText($src, 'ok')
        New-Item -ItemType HardLink -Path $dst -Target $src -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    }
}

function Get-StageCandidateDirs {
    $list = New-Object System.Collections.Generic.List[string]
    $q = Split-Path -Qualifier $Root -ErrorAction SilentlyContinue
    if ($q -and $q -match '^[A-Za-z]:$') { $list.Add((Join-Path ($q + '\') 'OPPOA5ROOT_stage')) }
    $sd = $env:SystemDrive
    if ($sd) {
        $p = Join-Path ($sd + '\') 'OPPOA5ROOT_stage'
        if (-not $list.Contains($p)) { $list.Add($p) }
    }
    if ($env:TEMP) {
        $p = Join-Path $env:TEMP 'OPPOA5ROOT_stage'
        if (-not $list.Contains($p)) { $list.Add($p) }
    }
    return $list
}

# 选定并创建本次运行的暂存区，落到 $C.StageDir；返回该路径
function Initialize-StageDir {
    $probed = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-StageCandidateDirs)) {
        if (-not (Test-AsciiPath $d))   { [void]$Global:StageNotes.Add('  暂存候选跳过 非 ASCII: ' + $d); continue }
        $existed = Test-Path -LiteralPath $d
        if (-not (Test-DirWritable $d)) { [void]$Global:StageNotes.Add('  暂存候选跳过 不可写: ' + $d); continue }
        if (-not $existed) { [void]$Global:StageProbeDirs.Add($d) }   # 探测时新建的目录，若没被选中要清理掉
        $sv = Test-SameVolumeAsProject $d
        [void]$Global:StageNotes.Add('  暂存候选可用: ' + $d + ' 同卷: ' + $sv)
        $probed.Add([pscustomobject]@{ Dir = $d; Same = $sv })
    }

    $ordered = @($probed | Where-Object { $_.Same }) + @($probed | Where-Object { -not $_.Same })
    $picked = $null
    $same   = $false
    if ($ordered.Count -gt 0) { $picked = $ordered[0].Dir; $same = $ordered[0].Same }

    if (-not $picked) {
        # 全部候选都不可用 → 退回项目内的 bin\_stage，并明确警告中文路径风险
        $picked = Join-Path $Root '_stage'
        $same = $true
        New-Item -ItemType Directory -Force -Path $picked | Out-Null
        Warn '没有可用的纯 ASCII 暂存路径，退回 bin\_stage'
        Warn '  项目路径含中文或空格时 fh_loader 可能失败，建议换纯英文路径'
    }

    # 没被选中的候选目录：只清「本次探测新建的、空的」那些，不在盘根 / TEMP 留垃圾
    foreach ($p in $probed) {
        if ($p.Dir -eq $picked) { continue }
        if (-not $Global:StageProbeDirs.Contains($p.Dir)) { continue }
        try {
            $left = @(Get-ChildItem -LiteralPath $p.Dir -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) { Remove-Item -LiteralPath $p.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        } catch {}
    }

    $Global:StageRoot = $picked
    $Global:StageSameVolume = $same
    $marker = Join-Path $picked '_oppoa5_stage.txt'
    if (Test-Path -LiteralPath $marker) {
        $Global:StageRootOurOwn = $true
        # 上一次异常中断（例如被强杀）留下的 run-* 残留，顺手清掉
        Get-ChildItem -LiteralPath $picked -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'run-*' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        $existing = @(Get-ChildItem -LiteralPath $picked -Force -ErrorAction SilentlyContinue)
        if ($existing.Count -eq 0) {
            [IO.File]::WriteAllText($marker, "OPPOA5 EsayROOT 临时暂存区，运行结束后会自动删除。`r`n可以安全手动删除。`r`n", (New-Object Text.UTF8Encoding($false)))
            $Global:StageRootOurOwn = $true
        } else {
            $Global:StageRootOurOwn = $false
        }
    }

    $run = 'run-' + $PID + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $C.StageDir = Join-Path $picked $run
    New-Item -ItemType Directory -Force -Path $C.StageDir | Out-Null
    $Global:StageReady = $true
    return $C.StageDir
}

# 退出清理：成功 / 异常 / 用户 Ctrl+C（PowerShell 的 finally 都会走到）三条路径共用
function Clear-StageDir {
    if (-not $Global:StageReady) { return }
    $Global:StageReady = $false
    foreach ($d in @($C.StageDir, $Global:StageDir)) {
        try {
            if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    # 探测时新建、但最后没被选中的候选目录（空目录），一并清掉
    foreach ($d in @($Global:StageProbeDirs)) {
        try {
            if ($d -and (Test-Path -LiteralPath $d)) {
                $left = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)
                if ($left.Count -eq 0) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
            }
        } catch {}
    }
    try {
        if ($Global:StageRootOurOwn -and $Global:StageRoot -and (Test-Path -LiteralPath $Global:StageRoot)) {
            $left = @(Get-ChildItem -LiteralPath $Global:StageRoot -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -ne '_oppoa5_stage.txt' })
            if ($left.Count -eq 0) { Remove-Item -LiteralPath $Global:StageRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

# 需要给外部工具当工作目录时用这个：优先 ASCII 暂存区，暂存区没准备好才退回项目内目录
function Get-AsciiWorkDir {
    if ($C.StageDir -and (Test-Path -LiteralPath $C.StageDir)) { return $C.StageDir }
    return $C.WorkDir
}

# ---------------- 现场制作镜像前的工具检查 ----------------
function Get-MissingMakeTools {
    $miss = New-Object System.Collections.Generic.List[string]
    foreach ($f in @('imgkit.exe', 'make_ext4fs.exe', 'simg2img.exe', 'img2simg.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $C.ToolDir $f))) { [void]$miss.Add($f) }
    }
    return $miss
}

# ---------------- 外部命令 ----------------
function Run-Tee {
    param(
        [string]$exe,
        [string[]]$arguments,
        [string]$logName = 'cmd',
        [string]$workdir = $null
    )
    $tmp = Join-Path (Get-AsciiWorkDir) ("out-$logName.txt")
    $old = Get-Location
    # 外部工具（imgkit / make_ext4fs / fh_loader ...）都会往 stderr 打进度和日志。
    # PowerShell 5.1 在 $ErrorActionPreference='Stop' 下会把原生命令的 stderr 当成
    # 终止性错误（NativeCommandError），导致管道被掐断、工具被半途杀掉。
    # 所以这里临时改成 Continue：只要拿到真正的退出码，就不算失败。
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($workdir) { Set-Location -LiteralPath $workdir }
        Add-Log ("执行: {0} {1}" -f $exe, ($arguments -join ' '))
        & $exe @arguments 2>&1 | Tee-Object -FilePath $tmp
        $code = $LASTEXITCODE
    } catch {
        Add-Log ("执行异常: " + $_.Exception.Message)
        $code = -1
        try { Add-Content -LiteralPath $tmp -Value ("[工具调用异常] " + $_.Exception.Message) -Encoding UTF8 } catch {}
    } finally {
        Set-Location $old
        $ErrorActionPreference = $oldEap
    }
    $text = ''
    if (Test-Path $tmp) { $text = Get-Content -LiteralPath $tmp -Raw }
    Add-Log ("返回码=$code")
    if ($text) { Add-Log $text }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Wait-For {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSec = 60,
        [string]$Message = '等待中',
        [int]$IntervalMs = 1000
    )
    Info $Message
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        try { if (& $Condition) { Write-Host ''; return $true } } catch {}
        Write-Host '.' -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds $IntervalMs
    }
    Write-Host ''
    return $false
}

# ---------------- 设备操作 ----------------
# 把老式刷机工具复制到 ASCII 暂存区，返回暂存区里的路径（避免中文路径导致工具失败）
function Get-StageTool {
    param([string]$name)
    if (-not (Test-Path $C.StageDir)) { New-Item -ItemType Directory -Force -Path $C.StageDir | Out-Null }
    $dst = Join-Path $C.StageDir $name
    $src = Join-Path $C.ToolDir $name
    if (-not (Test-Path $dst)) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    return $dst
}

# 把大镜像硬链接进 ASCII 暂存区（同卷瞬时、不占额外空间）
# 跨卷时硬链接必然失败，只能在确认空间足够后退化为复制（否则会占满磁盘）
function Get-StageImage {
    param([string]$imgPath, [string]$asName = 'system_flash.img')
    if (-not (Test-Path $C.StageDir)) { New-Item -ItemType Directory -Force -Path $C.StageDir | Out-Null }
    $dst = Join-Path $C.StageDir $asName
    if (Test-Path $dst) { Remove-Item -LiteralPath $dst -Force }
    try {
        New-Item -ItemType HardLink -Path $dst -Target $imgPath -ErrorAction Stop | Out-Null
        return $dst
    } catch {
        $bytes = (Get-Item -LiteralPath $imgPath).Length
        $free = $null
        try { $free = (Get-PSDrive (Split-Path -Qualifier $dst).TrimEnd(':')).Free } catch {}
        if (($free -ne $null) -and ($free -lt ($bytes + 512MB))) {
            throw ('暂存区所在盘空间不足：复制镜像需要 ' + [math]::Round($bytes / 1GB, 2) + ' GB，可用 ' + [math]::Round($free / 1GB, 2) + ' GB。请清理空间，或把工具箱放到与暂存区同卷。')
        }
        Warn ('暂存区不同卷, 只能复制 ' + [math]::Round($bytes / 1GB, 2) + ' GB')
        Add-Log ('硬链接失败，改为复制: ' + $imgPath + ' -> ' + $dst)
        Copy-Item -LiteralPath $imgPath -Destination $dst -Force
        return $dst
    }
}

function Get-AdbExe { return (Join-Path $C.ToolDir 'adb.exe') }

function Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $exe = Get-AdbExe
    # adb 经常往 stderr 打完全正常的信息（首次调用会打 "* daemon not running; starting now at tcp:5037"，
    # "adbd cannot run as root in production builds"，设备端命令的 stderr 也会被转发回来）。
    # PowerShell 5.1 在 $ErrorActionPreference='Stop' 下会把原生命令的 stderr 当成终止性错误，
    # 于是「第一次运行 adb（服务还没起）」就会直接把整个流程打断 —— 实测过，属缺陷。
    # 这里临时放宽，调用方按输出内容自己判断成败。
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        # 2>&1 会把 stderr 变成 ErrorRecord，Out-String 会连 "所在位置 / CategoryInfo" 一起渲染出来；
        # 这里还原成纯文本，调用方拿到的就是工具真正打印的内容。
        $out = @(& $exe @a 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
        })
    } finally {
        $ErrorActionPreference = $oldEap
    }
    return ($out | Out-String)
}

function Adb-Devices {
    $o = Adb devices
    return @($o -split "`r?`n" | Where-Object { $_ -match "\tdevice$" } | ForEach-Object { ($_ -split "\t")[0] })
}

# 在手机 root shell 跑一段脚本：写入本地 -> push -> su 执行（最稳，避免引号地狱）
function Run-OnDevice {
    param([string]$ScriptText, [string]$Name = 'task')
    $local = Join-Path (Get-AsciiWorkDir) ("dev-$Name.sh")
    $body = ($ScriptText -replace "`r`n", "`n")
    [IO.File]::WriteAllText($local, $body, (New-Object Text.UTF8Encoding($false)))
    Adb push $local /data/local/tmp/ | Out-Null
    return (Adb shell "su -c 'sh /data/local/tmp/dev-$Name.sh'")
}

function Get-Prop {
    param([string]$key)
    $v = Adb shell "getprop $key"
    return ($v | Out-String).Trim()
}

# ---------------- 9008 检测 ----------------
function Find-9008Port {
    $devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -match 'VID_05C6&PID_9008' })
    foreach ($d in $devs) {
        if ($d.FriendlyName -match '\(COM(\d+)\)') { return [int]$Matches[1] }
        try {
            $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_FriendlyName' -ErrorAction SilentlyContinue
            if ($p -and $p.Data -and $p.Data -match '\(COM(\d+)\)') { return [int]$Matches[1] }
        } catch {}
    }
    return $null
}

function Get-9008Devices {
    return @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -match 'VID_05C6&PID_9008' })
}

# ---------------- 收尾 ----------------
function Goodbye {
    Say ''
    Write-Host '  完成，手机已经是 root 状态。' -ForegroundColor Green
    Say ''
    Say '  自己确认一下：' 'White'
    Say '   1) Magisk App 首页显示「已安装 + Zygisk 已开启」'
    Say '   2) 超级用户页签能看到应用列表'
    Say ''
    Say '  两条禁忌：' 'Yellow'
    Say '   * 别点 Magisk 里的「安装/修补 boot」——本机 boot 有校验，改了会变砖'
    Say '   * 别装 Shamiko——本机实测开不了机'
    Add-Log '完成'
}
