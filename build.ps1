<#
    Build the AudioLoopback demo HAP (Windows / PowerShell).

    Usage:
        .\build.ps1                    # debug
        .\build.ps1 -BuildMode release

    Notes:
        - DevEco's bundled node and jbr are added to PATH (hvigor needs java at
          the packaging step);
        - uses the project-local node_modules (hvigor 6.x) when present,
          otherwise falls back to hvigorw.bat;
        - without a signing config the output is *-unsigned.hap. Configure
          signing in DevEco Studio (Project Structure > Signing Configs) before
          installing on a device.
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$BuildMode = 'debug'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
Set-Location $ProjectRoot

function Find-DevEco {
    # 1) 显式指定 IDE 根目录
    if ($env:DEVECO_HOME -and (Test-Path (Join-Path $env:DEVECO_HOME 'tools\node\node.exe'))) {
        return $env:DEVECO_HOME
    }
    # 2) 从 SDK 路径反推（SDK 位于 <ide>\sdk）
    if ($env:DEVECO_SDK_HOME) {
        $parent = Split-Path $env:DEVECO_SDK_HOME -Parent
        if ($parent -and (Test-Path (Join-Path $parent 'tools\node\node.exe'))) {
            return $parent
        }
    }
    # 3) 常见安装位置
    $candidates = @(
        'E:\DevEco Studio',
        'D:\DevEco Studio',
        'C:\Program Files\Huawei\DevEco Studio',
        (Join-Path $env:LOCALAPPDATA 'Huawei\DevEcoStudio')
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'tools\node\node.exe')) {
            return $c
        }
    }
    throw 'DevEco Studio 未找到。请设置环境变量后重试：setx DEVECO_HOME "E:\DevEco Studio"  或  setx DEVECO_SDK_HOME "E:\DevEco Studio\sdk"'
}

$deveco = Find-DevEco
Write-Host "DevEco: $deveco" -ForegroundColor Cyan

$env:PATH = "$deveco\tools\node;$deveco\jbr\bin;" + $env:PATH
$env:JAVA_HOME = "$deveco\jbr"
$env:DEVECO_SDK_HOME = "$deveco\sdk"
Write-Host "node: $(node --version) | sdk: $env:DEVECO_SDK_HOME" -ForegroundColor DarkGray

$hvigorArgs = @(
    '--mode', 'module',
    '-p', 'product=default',
    '-p', 'module=entry@default',
    '-p', "buildMode=$BuildMode",
    'assembleHap',
    '--no-daemon'
)

$localHvigor = Join-Path $ProjectRoot 'node_modules\@ohos\hvigor\bin\hvigor.js'
if (Test-Path $localHvigor) {
    Write-Host 'hvigor: project node_modules' -ForegroundColor DarkGray
    & node $localHvigor @hvigorArgs
} elseif (Test-Path (Join-Path $ProjectRoot 'hvigorw.bat')) {
    Write-Host 'hvigor: hvigorw.bat' -ForegroundColor DarkGray
    & cmd /c hvigorw.bat @hvigorArgs
} else {
    throw 'Neither node_modules/@ohos/hvigor nor hvigorw.bat found. Open the project in DevEco Studio instead.'
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED (exit=$LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host 'BUILD SUCCESSFUL, artifacts:' -ForegroundColor Green
Get-ChildItem (Join-Path $ProjectRoot 'entry\build') -Recurse -File -Filter '*.hap' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 3 |
    ForEach-Object { Write-Host ('  {0}  ({1:N0} KB)' -f $_.FullName, ($_.Length / 1KB)) }
Write-Host ''
Write-Host 'Install on device (signing required first): hdc install -r <hap>' -ForegroundColor DarkGray
