# 把 core-native 里的 mihomo 交叉编译成 OpenHarmony arm64 的 c-shared 库（libngcore.so）。
#
# 需要 OpenHarmony Go 工具链（fork 支持 GOOS=openharmony），普通官方 Go 包不支持该目标。
# 用 -trimpath 构建，产物里不会带本机路径；-ldflags "-s -w" 去掉符号表，体积小一半。
#
# 用法：
#   pwsh -NoProfile -File tools\build-core.ps1 `
#     -Sdk "E:\dev\ohos\sdk" -Api "15" -GoRoot "E:\dev\tools\ohos-go-src"
#
# 产物默认写回 app/entry/libs/arm64-v8a/libngcore.so，并打印 size 与 sha256，
# 可与 Release 里 SHA256SUMS.txt 的对应行核对。

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Sdk,
  [string]$Api = "15",
  [Parameter(Mandatory = $true)][string]$GoRoot,
  [string]$Out = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreDir = Join-Path $repoRoot "core-native"
$sysroot = Join-Path $Sdk "$Api/native/sysroot"
$clang = Join-Path $Sdk "$Api/native/llvm/bin/clang.exe"
$go = Join-Path $GoRoot "bin/go.exe"

foreach ($p in @($coreDir, $sysroot, $clang, $go)) {
  if (-not (Test-Path -LiteralPath $p)) {
    throw "missing required path: $p"
  }
}
if ([string]::IsNullOrWhiteSpace($Out)) {
  $Out = Join-Path $repoRoot "app/entry/libs/arm64-v8a/libngcore.so"
}

$env:GOROOT = $GoRoot
$env:GOTOOLCHAIN = "local"
$env:GOOS = "openharmony"
$env:GOARCH = "arm64"
$env:CGO_ENABLED = "1"
$env:CGO_CFLAGS_ALLOW = ".*"
$env:CGO_LDFLAGS_ALLOW = ".*"
$env:CC = $clang
$env:CGO_CFLAGS = "--target=aarch64-linux-ohos --sysroot=$sysroot -D__MUSL__ -fPIC -Wno-error -O2"
$env:CGO_LDFLAGS = "--target=aarch64-linux-ohos --sysroot=$sysroot"

Push-Location $coreDir
try {
  & $go build -buildmode=c-shared -tags "with_gvisor" -trimpath -ldflags="-s -w" -o $Out .
  if ($LASTEXITCODE -ne 0) {
    throw "go build failed with exit code $LASTEXITCODE"
  }
}
finally {
  Pop-Location
}

$item = Get-Item -LiteralPath $Out
$hash = (Get-FileHash -LiteralPath $Out -Algorithm SHA256).Hash.ToLower()

# 本机路径不该出现在产物里；出现在这里说明 -trimpath 没生效
$bytes = [IO.File]::ReadAllBytes($Out)
$latin1 = [Text.Encoding]::GetEncoding(28591)
$text = $latin1.GetString($bytes)
$leaks = 0
foreach ($needle in @($GoRoot, $repoRoot)) {
  $forms = @($needle, ($needle -replace '\\', '/'))
  foreach ($f in $forms) {
    if ($text.Contains($f)) {
      $leaks++
      Write-Warning "build path leaked into binary: $f"
    }
  }
}

Write-Output "built:  $($item.FullName)"
Write-Output "size:   $($item.Length) bytes"
Write-Output "sha256: $hash"
Write-Output "path leak: $leaks"
