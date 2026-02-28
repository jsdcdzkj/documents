# =========================================================
# PowerShell 5.1 - CSV 批量下载器（断点续跑 · 稳定增强版）
# =========================================================

# ================== 基础配置 ==================
$txtPath   = "C:\Users\Administrator\Desktop\20251214file.csv"
$baseUrl   = "https://zhtc.aldwxa.top/file/2025/12/"
$saveRoot  = "D:\zhtc-file\12"

$threadMax = 4
$maxRetries = 3
$connectTimeoutMs = 30000
$batchSize = 500

# ================== 路径校验 ==================
if (-not (Test-Path $txtPath)) {
    Write-Host "? CSV 文件不存在：" -ForegroundColor Red
    Write-Host $txtPath -ForegroundColor Yellow
    exit 1
}

# ================== 环境初始化 ==================
New-Item -ItemType Directory -Force -Path $saveRoot | Out-Null
$logDir = Join-Path $saveRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$failedCsv = Join-Path $logDir ("failed_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

# ================== 解析 CSV ==================
Write-Host "?? 正在解析 CSV 文件…" -ForegroundColor Cyan
$rows = Import-Csv -Path $txtPath

$jobs = New-Object System.Collections.Generic.List[object]

foreach ($r in $rows) {

    if (-not $r.file_url) { continue }

    $file = $r.file_url.Trim()
    if ($file -eq "") { continue }

    $savePath = Join-Path $saveRoot $file

    # ? 已存在文件 → 直接跳过（断点续跑核心）
    if (Test-Path $savePath) {
        continue
    }

    $jobs.Add([PSCustomObject]@{
        File     = $file
        Url      = "$baseUrl$file"
        SavePath = $savePath
    })
}

$totalFiles = $jobs.Count
Write-Host "? 需要下载文件数：$totalFiles" -ForegroundColor Green

if ($totalFiles -eq 0) {
    Write-Host "?? 所有文件已存在，无需下载" -ForegroundColor Cyan
    exit 0
}

# ================== Runspace 池 ==================
$pool = [RunspaceFactory]::CreateRunspacePool(1, $threadMax)
$pool.Open()

# ================== 下载函数 ==================
$downloadScript = {
    param($url, $savePath, $maxRetries, $timeout)

    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $req = [Net.HttpWebRequest]::Create($url)
            $req.Timeout = $timeout
            $req.ReadWriteTimeout = $timeout

            $resp = $req.GetResponse()
            $stream = $resp.GetResponseStream()

            $dir = Split-Path $savePath -Parent
            if (-not (Test-Path $dir)) {
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
            }

            $fs = [IO.File]::Create($savePath)
            $buf = New-Object byte[] 81920

            while (($r = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $r)
            }

            $fs.Close()
            $stream.Close()
            $resp.Close()
            return $true
        }
        catch {
            if (Test-Path $savePath) {
                Remove-Item $savePath -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds (2 * $i)
        }
    }
    return $false
}

# ================== 批量下载 ==================
$completed = 0
$batches = [Math]::Ceiling($totalFiles / $batchSize)

for ($b = 0; $b -lt $batches; $b++) {

    $slice = $jobs[
        ($b * $batchSize) ..
        ([Math]::Min(($b + 1) * $batchSize - 1, $totalFiles - 1))
    ]

    $psList = @()

    foreach ($job in $slice) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool

        $null = $ps.AddScript($downloadScript)
        $null = $ps.AddArgument($job.Url)
        $null = $ps.AddArgument($job.SavePath)
        $null = $ps.AddArgument($maxRetries)
        $null = $ps.AddArgument($connectTimeoutMs)

        $psList += [PSCustomObject]@{
            PS     = $ps
            Handle = $ps.BeginInvoke()
            Job    = $job
        }
    }

    foreach ($e in $psList) {
        $ok = $e.PS.EndInvoke($e.Handle)
        $completed++

        if (-not $ok) {
            "$($e.Job.File),$($e.Job.Url)" |
                Out-File -Append -Encoding UTF8 $failedCsv
        }

        Write-Progress `
            -Activity "?? 批量下载中" `
            -Status "$completed / $totalFiles" `
            -PercentComplete (($completed / $totalFiles) * 100)

        $e.PS.Dispose()
    }
}

Write-Progress -Activity "完成" -Completed
$pool.Close()
$pool.Dispose()

Write-Host "?? 下载完成：$completed / $totalFiles" -ForegroundColor Cyan
Write-Host "?? 失败记录（如有）：$failedCsv" -ForegroundColor Yellow
