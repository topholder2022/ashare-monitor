<#
  A-share Monitor: Auto-deploy to GitHub Pages (API version)
  Uses GitHub Contents API instead of git (more reliable for restricted networks)
#>

$Token = $env:GH_TOKEN
if (-not $Token) { Write-Error "GH_TOKEN environment variable not set"; exit 1 }
$Owner = "topholder2022"
$Repo = "ashare-monitor"
$ScriptDir = $PSScriptRoot
$today = Get-Date -Format 'yyyy-MM-dd'

# === 1. Run fetch script ===
Write-Output "=== Step 1: Fetch announcements ==="
$outputFile = Join-Path (Join-Path $ScriptDir "output") "$today.html"
& "$ScriptDir\fetch_and_report.ps1"
if (-not (Test-Path $outputFile)) {
    Write-Error "Output file not found: $outputFile"; exit 1
}
Write-Output "Output file: $outputFile ($((Get-Item $outputFile).Length) bytes)"

# === 2. Deploy via GitHub API ===
Write-Output "=== Step 2: Deploy via GitHub API ==="
$content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outputFile))
$headers = @{Authorization = "Bearer $Token"; "Content-Type" = "application/json"}

# Get current file SHA (needed to update existing file)
$sha = $null
try {
    $get = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/contents/index.html" -Headers $headers -TimeoutSec 15
    $sha = $get.sha
    Write-Output "Current file SHA: $($sha.Substring(0,7))..."
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Write-Output "File not found (HTTP $statusCode), will create new"
}

# Update file via Contents API
$body = @{
    message = "Daily update $today [$((Get-Date -Format 'HH:mm'))]"
    content = $content
    branch = "master"
} | ConvertTo-Json -Depth 10
if ($sha) { $body = $body -replace '}$',",`"sha`":`"$sha`"}" }

try {
    $result = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/contents/index.html" -Method Put -Headers $headers -Body $body -TimeoutSec 30
    Write-Output "=== Deploy successful! ==="
    Write-Output "Commit: $($result.commit.sha)"
    Write-Output "https://$Owner.github.io/$Repo/"
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    try { $errDetail = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $errDetail = $_.Exception.Message }
    Write-Error "Deploy failed (HTTP $statusCode): $errDetail"
    exit 1
}

# === 3. Keep local copy for cache ===
$PagesDir = Join-Path $ScriptDir "pages-repo"
if (-not (Test-Path $PagesDir)) { New-Item -ItemType Directory -Path $PagesDir -Force | Out-Null }
Copy-Item $outputFile (Join-Path $PagesDir "index.html") -Force
Write-Output "Local copy saved"
