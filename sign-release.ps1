<#
.SYNOPSIS
    用正式（release）证书给 HAP 签名。

.DESCRIPTION
    本工程默认用调试证书打包，只能装在自己白名单里的设备上。
    要出可分发/可上架的包，需要先在 AppGallery Connect 生成一套 release 材料：

        .p12  密钥库（自己生成，务必备份）
        .cer  release 证书（AGC 用你的 .csr 签发）
        .p7b  release Profile（AGC 创建，绑定 bundleName + 证书）

    拿到这三样后运行本脚本，它会对 build.ps1 产出的 unsigned HAP 重新签名。

.PARAMETER Keystore      .p12 路径
.PARAMETER KeyAlias      密钥别名（AGC 生成密钥时填的那个）
.PARAMETER StorePassword 密钥库密码
.PARAMETER KeyPassword   密钥密码（多数情况与密钥库密码相同）
.PARAMETER Cert          release 证书 .cer
.PARAMETER Profile       release Profile .p7b
.PARAMETER InFile        待签名的 unsigned HAP（默认取最新构建产物）
.PARAMETER OutFile       输出路径（默认 dist\lingxin-release-signed.hap）

.EXAMPLE
    .\sign-release.ps1 -Keystore C:\sign\lingxin.p12 -KeyAlias lingxin `
        -StorePassword 123456 -KeyPassword 123456 `
        -Cert C:\sign\lingxin-release.cer -Profile C:\sign\lingxin-release.p7b
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Keystore,
    [Parameter(Mandatory)] [string]$KeyAlias,
    [Parameter(Mandatory)] [string]$StorePassword,
    [Parameter(Mandatory)] [string]$Cert,
    [Parameter(Mandatory)] [string]$Profile,
    [string]$KeyPassword,
    [string]$InFile,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
Set-Location $ProjectRoot

if (-not $KeyPassword) { $KeyPassword = $StorePassword }

foreach ($f in @($Keystore, $Cert, $Profile)) {
    if (-not (Test-Path $f)) { throw "找不到文件: $f" }
}

# 找 unsigned HAP
if (-not $InFile) {
    $hap = Get-ChildItem 'entry\build' -Recurse -File -Filter '*unsigned.hap' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $hap) { throw '没有找到 unsigned HAP，先跑 .\build.ps1' }
    $InFile = $hap.FullName
}
if (-not $OutFile) {
    New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot 'dist') | Out-Null
    $OutFile = Join-Path $ProjectRoot 'dist\lingxin-release-signed.hap'
}

$signTool = 'E:\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$java = 'E:\DevEco Studio\jbr\bin\java.exe'
if (-not (Test-Path $signTool)) { throw "找不到 hap-sign-tool.jar: $signTool" }
if (-not (Test-Path $java)) { throw "找不到 java: $java" }

Write-Host "输入: $InFile" -ForegroundColor DarkGray
Write-Host "输出: $OutFile" -ForegroundColor DarkGray

& $java -jar $signTool sign-app `
    -mode localSign `
    -keyAlias $KeyAlias `
    -keyPwd $KeyPassword `
    -keystorePwd $StorePassword `
    -appCertFile $Cert `
    -profileFile $Profile `
    -keystoreFile $Keystore `
    -inFile $InFile `
    -outFile $OutFile `
    -signAlg SHA256withECDSA

if ($LASTEXITCODE -ne 0) {
    Write-Host "签名失败（exit=$LASTEXITCODE）" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host '签名成功：' -ForegroundColor Green
$sizeKb = [math]::Round((Get-Item $OutFile).Length / 1KB)
Write-Host ('  ' + $OutFile + '  (' + $sizeKb + ' KB)')
Write-Host ''
Write-Host '验证签名：' -ForegroundColor DarkGray
Write-Host ('  java -jar "' + $signTool + '" verify-app -inFile "' + $OutFile + '" -outCertChain out.cer -outProfile out.p7b') -ForegroundColor DarkGray
