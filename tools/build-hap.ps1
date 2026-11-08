# 用 hvigor 命令行构建 HAP（不依赖 DevEco Studio）
# 用法：
#   $env:OHOS_SDK = "E:\dev\ohos\sdk"     # SDK 根目录
#   $env:JAVA_HOME = "E:\dev\ohos\jbr"    # 任一 JDK 17
#   pwsh .\tools\build-hap.ps1
param(
    [string]$Sdk = $env:OHOS_SDK,
    [string]$JavaHome = $env:JAVA_HOME,
    [string]$Module = "entry@default",
    [string]$Product = "default"
)

$ErrorActionPreference = "Stop"
if (-not $Sdk) { throw "请先设置 OHOS_SDK 环境变量，或用 -Sdk 传入 SDK 根目录" }
if (-not $JavaHome) { throw "请先设置 JAVA_HOME 环境变量，或用 -JavaHome 传入 JDK 目录" }

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$app = Join-Path $repo "app"

# hvigor 需要这两个环境变量定位 SDK
$env:OHOS_BASE_SDK_HOME = $Sdk
$env:OHOS_SDK_HOME = $Sdk
$env:JAVA_HOME = $JavaHome
$env:PATH = "$JavaHome\bin;" + (Join-Path $Sdk "toolchains") + ";" + $env:PATH

$hvigor = Join-Path $app "node_modules\@ohos\hvigor\bin\hvigor.js"
if (-not (Test-Path -LiteralPath $hvigor)) { throw "缺少 hvigor 依赖，请先在 app 目录执行 npm install" }

Push-Location $app
try {
    & node $hvigor --mode module -p "module=$Module" -p "product=$Product" assembleHap --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "hvigor 构建失败，exit=$LASTEXITCODE" }
}
finally {
    Pop-Location
}

$hapDir = Join-Path $app "entry\build\$Product\outputs\$Product"
Get-ChildItem -LiteralPath $hapDir -Filter "*.hap" -ErrorAction SilentlyContinue |
    ForEach-Object { "unsigned: $($_.FullName)  $([Math]::Round($_.Length/1MB,1)) MB" }
"提示：产物未签名，装机前需要用 DevEco Studio 自动签名或 hap-sign-tool 手动签名。"
