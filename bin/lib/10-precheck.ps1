# ============================================================
#  lib\10-precheck.ps1   前置自检
#     Test-DiskSpace      磁盘空间（自检与一键救砖共用）
#     Test-Preliminaries  文件 / 工具 / 空间 / 环境
# ============================================================

function Test-DiskSpace {
    # 现场做镜像峰值约 8.6 GB；低于 12 GB 直接判失败，低于 18 GB 提醒
    $spaceFail = 12
    $spaceWarn = 18

    $drvList = @()
    $rootQ = Split-Path -Qualifier $Root -ErrorAction SilentlyContinue
    if ($rootQ) { $drvList += $rootQ.TrimEnd(':') }
    $stageQ = Split-Path -Qualifier $C.StageDir -ErrorAction SilentlyContinue
    if ($stageQ) { $sq = $stageQ.TrimEnd(':'); if ($drvList -notcontains $sq) { $drvList += $sq } }

    $ok = $true
    foreach ($d in $drvList) {
        $free = $null
        try { $free = (Get-PSDrive $d -ErrorAction Stop).Free } catch {}
        if ($free -eq $null) { Warn ($d + ' 盘空间读不到，跳过'); continue }
        $freeGB = [math]::Round($free / 1GB, 2)
        $who = $(if ($d -eq $rootQ.TrimEnd(':')) { $d + ' 盘' } else { $d + ' 盘 暂存区' })
        if ($freeGB -lt $spaceFail) {
            Err ($who + ' 只剩 ' + $freeGB + ' GB，做镜像要 8.6 GB')
            $bakInfo = ''
            try {
                $bd = @(Get-ChildItem -LiteralPath $C.BakDir -Directory -Force -ErrorAction SilentlyContinue)
                if ($bd.Count -gt 0) {
                    $bs = (Get-ChildItem -LiteralPath $C.BakDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    $bakInfo = '；bin\backup 里有 ' + $bd.Count + ' 份备份占 ' + [math]::Round($bs / 1GB, 2) + ' GB'
                }
            } catch {}
            Say ('  删 bin\backup 里的旧备份可腾空间' + $bakInfo) 'DarkGray'
            $ok = $false
        } elseif ($freeGB -lt $spaceWarn) {
            Warn ($who + ' 只剩 ' + $freeGB + ' GB，偏紧')
            Say '  bin\backup 里的旧备份可直接删' 'DarkGray'
        } else {
            Ok ($who + ' 空间够：' + $freeGB + ' GB')
        }
    }
    return $ok
}

function Test-Preliminaries {
    $fail = 0

    # ---------- 0. 参数 ----------
    if ($Global:SkipBak) {
        Err '-SkipBackup 不能用：每次都只能用手机自己的 system 现场做镜像，没有备份做不出来'
        $fail++
    }

    # ---------- 1. 必需文件 ----------
    Say ''
    Say '  [INFO] 检查文件' 'Cyan'
    $need = @(
        @{ p = (Join-Path $C.ToolDir 'fh_loader.exe');                       n = 'fh_loader.exe' },
        @{ p = (Join-Path $C.ToolDir 'QSaharaServer.exe');                   n = 'QSaharaServer.exe' },
        @{ p = (Join-Path $C.ToolDir 'devprg_450');                          n = 'devprg_450' },
        @{ p = (Join-Path $C.ToolDir 'reset.xml');                           n = 'reset.xml' },
        @{ p = (Join-Path $C.ModDir  'rutils-disable-module.zip');           n = 'rutils-disable-module.zip' },
        @{ p = (Join-Path $C.ModDir  'dialog-killer-module.zip');            n = 'dialog-killer-module.zip' },
        @{ p = (Join-Path $C.ModDir  'install_module.sh');                   n = 'install_module.sh' },
        @{ p = (Join-Path $C.RefDir  'extracted\etc\setup-magisk.sh');       n = 'ref\extracted\etc\setup-magisk.sh' },
        @{ p = (Join-Path $C.RefDir  'extracted\etc\init\magisk.rc');        n = 'ref\extracted\etc\init\magisk.rc' },
        @{ p = (Join-Path $C.RefDir  'extracted\etc\magisk\magisk64');       n = 'ref\extracted\etc\magisk\magisk64' },
        @{ p = (Join-Path $C.RefDir  'magisk32_v27.0');                      n = 'ref\magisk32_v27.0' },
        @{ p = (Join-Path $C.RefDir  'Magisk-v27.0.apk');                    n = 'ref\Magisk-v27.0.apk' }
    )
    $missFile = 0
    foreach ($x in $need) {
        if (Test-Path -LiteralPath $x.p) { Add-Log ('  有: ' + $x.n) }
        else { Err ('缺文件: ' + $x.n); Say ('    ' + $x.p) 'DarkGray'; $fail++; $missFile++ }
    }
    if ($missFile -eq 0) { Ok '文件齐全' }

    # ---------- 2. 外部工具（缺一不可）----------
    Say ''
    Say '  [INFO] 检查工具' 'Cyan'
    $tools = @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll', 'imgkit.exe', 'make_ext4fs.exe', 'simg2img.exe', 'img2simg.exe', 'cygwin1.dll')
    $missTool = 0
    foreach ($t in $tools) {
        $full = Join-Path $C.ToolDir $t
        if (Test-Path -LiteralPath $full) { Add-Log ('  有: ' + $t) }
        else { Err ('缺文件: ' + $t); Say ('    ' + $full) 'DarkGray'; $fail++; $missTool++ }
    }
    if ($missTool -eq 0) { Ok '工具齐全' }

    # ---------- 3. 磁盘空间 ----------
    Say ''
    Say '  [INFO] 检查磁盘' 'Cyan'
    if (-not (Test-DiskSpace)) { $fail++ }

    # ---------- 4. 运行环境 ----------
    Say ''
    Say '  [INFO] 检查环境' 'Cyan'
    try {
        $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($adm) { Ok '有管理员权限' } else { Warn '不是管理员，失败时改用管理员运行' }
    } catch {}
    $os = [Environment]::OSVersion.Version
    Info ('Win ' + $os.Major + '.' + $os.Minor + ' / PS ' + $PSVersionTable.PSVersion)
    if ($PSVersionTable.PSVersion.Major -lt 5) { Err 'PowerShell 太老，需要 5.1+'; $fail++ }

    Say ''
    if ($fail -eq 0) { Ok '自检通过'; return $true }
    Err ('自检未通过: ' + $fail + ' 项')
    return $false
}
