# 编译 NAPI 桥（entry/libs/arm64-v8a/libngnapi.so）
# 用法：把 OHOS_SDK 环境变量指到你的 SDK 根目录后执行
#   $env:OHOS_SDK = "C:\path\to\ohos\sdk"    # 例如 E:\dev\ohos\sdk
#   pwsh .\tools\build-napi.ps1
param(
    [string]$Sdk = $env:OHOS_SDK,
    [string]$Api = "15"
)

$ErrorActionPreference = "Stop"
if (-not $Sdk) { throw "请先设置 OHOS_SDK 环境变量，或用 -Sdk 传入 SDK 根目录" }

$ndk = Join-Path $Sdk "$Api\native"
if (-not (Test-Path -LiteralPath $ndk)) { throw "找不到 NDK：$ndk" }

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$cpp = Join-Path $repo "app\entry\src\main\cpp\napi_init.cpp"
$outDir = Join-Path $repo "app\entry\libs\arm64-v8a"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir "libngnapi.so"

$inc = Join-Path $ndk "sysroot\usr\include"
$libdir = Join-Path $ndk "sysroot\usr\lib\aarch64-linux-ohos"
$clang = Join-Path $ndk "llvm\bin\clang++.exe"

$args = @(
    "-target", "aarch64-linux-ohos",
    "--sysroot=$(Join-Path $ndk 'sysroot')",
    "-D__MUSL__", "-O2", "-fPIC", "-shared", "-std=c++17",
    "-I$inc",
    "-o", $out,
    $cpp,
    "-L$libdir",
    "-lace_napi.z", "-lhilog_ndk.z",
    "-Wl,-z,max-page-size=16384"
)
& $clang @args
if ($LASTEXITCODE -ne 0) { throw "clang 编译失败，exit=$LASTEXITCODE" }

$readelf = Join-Path $ndk "llvm\bin\llvm-readelf.exe"
"built: $out  size=$((Get-Item -LiteralPath $out).Length)"
if (Test-Path -LiteralPath $readelf) {
    & $readelf -d $out 2>&1 | Select-String "NEEDED" | ForEach-Object { $_.Line }
}
