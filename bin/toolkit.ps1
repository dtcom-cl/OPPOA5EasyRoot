#Requires -Version 5.1
param(
    [switch]$Check,
    [switch]$SkipBackup,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $Root

# ------------------------------------------------------------
#  路径配置：外部工具都在 bin\tools\
# ------------------------------------------------------------
$C = [ordered]@{
    ToolDir = Join-Path $Root 'tools'
    ImgDir  = Join-Path $Root 'images'
    ModDir  = Join-Path $Root 'modules'
    RefDir  = Join-Path $Root 'ref'
    BakDir  = Join-Path $Root 'backup'
    WorkDir = Join-Path $Root 'work'
    StageDir = $null
    LogDir  = Join-Path $Root 'logs'
    OutDir  = Join-Path $Root 'images'
}
$Global:C = $C
$Global:AutoYes = [bool]$Yes
$Global:SkipBak = [bool]$SkipBackup

# ------------------------------------------------------------
#  加载库（lib 下按文件名顺序全部载入）
# ------------------------------------------------------------
. (Join-Path $Root 'lib\00-common.ps1')
Get-ChildItem (Join-Path $Root 'lib') -Filter '*.ps1' |
    Where-Object { $_.Name -ne '00-common.ps1' } |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

# ------------------------------------------------------------
#  一键 root 主流程（Step 0~11）
# ------------------------------------------------------------
function Invoke-RootFlow {
    Step 0 '前置自检'
    if (-not (Test-Preliminaries)) { throw '自检未通过，先解决上面列出的问题。' }

    Step 1 '检查手机'
    Set-Title 'OPPOA5 检查手机'
    $dev = Get-DeviceInfo
    if (-not (Test-Gate $dev)) { throw '机型不在支持范围，已停止。' }

    Step 2 '进 9008'
    Set-Title 'OPPOA5 等待 9008'
    $port = Wait-9008

    Step 3 '读分区表'
    $geo = Read-PartitionGeometry $port

    Step 4 '备份原机分区'
    Set-Title 'OPPOA5 备份中'
    $bak = Backup-Partitions $port $geo $dev

    Step 5 '制作镜像'
    Set-Title 'OPPOA5 制作镜像'
    $img = Resolve-SystemImage $dev $bak

    Step 6 '刷入 system'
    Set-Title 'OPPOA5 刷写中'
    Invoke-Flash $port $img $geo

    Step 7 '等开机'
    Set-Title 'OPPOA5 等开机'
    [void](Wait-Boot)
    Wait-Adb

    Step 8 '装模块'
    Set-Title 'OPPOA5 装模块'
    Install-Modules

    Step 9 '配置 Magisk'
    Set-MagiskConfig

    Step 10 '重启'
    Restart-And-Wait

    Step 11 '验收'
    Confirm-Result

    Goodbye
}

# ------------------------------------------------------------
#  主流程
# ------------------------------------------------------------
$exitCode = 0
try {
    Initialize-StageDir | Out-Null
    Init-Log
    Add-Log "工具箱启动：$Root"
    foreach ($n in @($Global:StageNotes)) { Add-Log $n }
    Add-Log ("暂存区: " + $C.StageDir)
    Set-Title 'OPPOA5 就绪'

    if ($Check) {
        Set-Title 'OPPOA5 自检'
        Show-Logo
        Step 0 '前置自检'
        if (-not (Test-Preliminaries)) { throw '自检未通过，先解决上面列出的问题。' }
        Ok '干跑模式：自检通过，没碰手机'
        exit 0
    }

    $quit = $false
    $badIn = 0
    while (-not $quit) {
        Show-Menu
        $sel = Read-Line '  输入序号按Enter继续: '
        switch ($sel) {
            '1' { Invoke-RootFlow; $quit = $true }
            '2' { Invoke-RescueFlow; $badIn = 0 }
            '3' { Show-About; $badIn = 0 }
            default {
                Err '输入错误, 请重新输入.'
                $badIn++
                if ($badIn -ge 5) { Err '多次输入错误, 退出.'; $quit = $true }
            }
        }
    }
}
catch {
    Set-Title 'OPPOA5 出错'
    Err $_.Exception.Message
    Say ('  日志: ' + (Get-LogPath)) 'Cyan'
    Say '  手机开不了机：菜单里选「2. 一键救砖」刷回原机备份。' 'Yellow'
    $exitCode = 1
}
finally {
    # 成功 / 异常 / Ctrl+C 都会走到这里，清掉暂存区
    Clear-StageDir
}
exit $exitCode
