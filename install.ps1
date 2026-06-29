# orb installer for Windows (PowerShell).
#
# Downloads the latest release binary and installs it as `orb.exe`, adding it to
# your user PATH. Usage:
#
#   irm https://raw.githubusercontent.com/ohidurbappy/orb/main/install.ps1 | iex
#
# Override the install directory with $env:ORB_INSTALL_DIR before running.
$ErrorActionPreference = 'Stop'

$repo = 'ohidurbappy/orb'
$asset = 'orb-windows-x64.exe.gz'
$url = "https://github.com/$repo/releases/latest/download/$asset"

# --- choose install directory ------------------------------------------------
$dir = if ($env:ORB_INSTALL_DIR) { $env:ORB_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'orb\bin' }
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$gzPath = Join-Path $env:TEMP 'orb.exe.gz'
$exePath = Join-Path $dir 'orb.exe'

# --- download ----------------------------------------------------------------
Write-Host "Downloading $asset ..."
Invoke-WebRequest -Uri $url -OutFile $gzPath -UseBasicParsing

# --- decompress gzip ---------------------------------------------------------
$inStream = [System.IO.File]::OpenRead($gzPath)
$outStream = [System.IO.File]::Create($exePath)
$gzip = New-Object System.IO.Compression.GzipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
try {
  $gzip.CopyTo($outStream)
} finally {
  $gzip.Dispose(); $outStream.Dispose(); $inStream.Dispose()
}
Remove-Item $gzPath -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Installed orb to $exePath"

# --- add to user PATH if missing ---------------------------------------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $dir) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$dir", 'User')
  Write-Host "Added $dir to your user PATH — restart your terminal to use 'orb'."
}

Write-Host ""
Write-Host "Run: orb --help"
