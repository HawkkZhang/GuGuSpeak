[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ModelName,
    [Parameter(Mandatory)] [string] $ModelUrl,
    [Parameter(Mandatory)] [string] $CacheDir,
    [Parameter(Mandatory)] [string] $OutDir
)

$ErrorActionPreference = 'Stop'

$archive = Join-Path $CacheDir "$ModelName.tar.bz2"
$tarPath = Join-Path $CacheDir "$ModelName.tar"
$marker  = Join-Path $OutDir "$ModelName\tokens.txt"

if (Test-Path $marker) { exit 0 }

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir   | Out-Null

if (-not (Test-Path $archive)) {
    Write-Host "==> Downloading ASR model: $ModelName"
    $tmp = "$archive.partial"
    Invoke-WebRequest -UseBasicParsing -Uri $ModelUrl -OutFile $tmp
    Move-Item -Force $tmp $archive
}

if (-not (Test-Path $tarPath)) {
    Write-Host "==> Decompressing bz2"
    $bzPath = (Get-Command bzip2 -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $bzPath) {
        $candidate = 'C:\Program Files\Git\usr\bin\bzip2.exe'
        if (Test-Path $candidate) { $bzPath = $candidate }
    }
    if (-not $bzPath) {
        throw "bzip2 not found. Install Git for Windows (provides bzip2.exe) or add bzip2 to PATH."
    }
    # `>` in PowerShell 5.1 writes UTF-16 and corrupts binary output, so we
    # use Start-Process -RedirectStandardOutput to write raw bytes.
    $tmp = "$tarPath.partial"
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
    $proc = Start-Process -FilePath $bzPath -ArgumentList @('-dkc', $archive) `
        -NoNewWindow -PassThru -RedirectStandardOutput $tmp -Wait
    if ($proc.ExitCode -ne 0) {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        throw "bzip2 decompression failed (exit $($proc.ExitCode))"
    }
    Move-Item -Force $tmp $tarPath
}

Write-Host "==> Extracting tar to $OutDir"
& tar -xf $tarPath -C $OutDir
if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit $LASTEXITCODE)" }

if (-not (Test-Path $marker)) {
    throw "Extraction completed but tokens.txt missing at $marker"
}
Write-Host "==> Model ready: $marker"
