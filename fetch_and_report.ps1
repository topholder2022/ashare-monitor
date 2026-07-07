<#
  A-share Announcement Hot Ranking Generator
  Data sources: TDX local base.dbf + Tencent/qt (market data) + CNINFO (announcements)
#>

param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [int]$MaxAnnounceStocks = 500,
    [string]$OutputDir = "$PSScriptRoot\output"
)

$OutputDate = $Date -replace '-', ''
$OutputFile = Join-Path $OutputDir "$Date.html"
$TDXDir = "F:\desktop backup\TDXKXGV2025"
$TDX_SH_LDay = "$TDXDir\vipdoc\sh\lday"
$TDX_SZ_LDay = "$TDXDir\vipdoc\sz\lday"

Write-Output "=== A-Share Monitor (TDX Data Sources) ==="
Write-Output "Date: $Date"

# ============ 1. Read stock list from TDX base.dbf ============
function Get-StockListFromDayFiles {
    $stocks = @()
    foreach ($dir in @($TDX_SH_LDay, $TDX_SZ_LDay)) {
        if (-not (Test-Path $dir)) { Write-Warning "Dir not found: $dir"; continue }
        Get-ChildItem "$dir\*.day" | ForEach-Object {
            $name = $_.BaseName
            if ($name -match '^(sh|sz)(\d{6})$') {
                $stocks += [PSCustomObject]@{Code=$matches[2]; Market=$matches[1]}
            }
        }
    }
    return $stocks
}

Write-Output "Step 1: Loading stock list from TDX .day files..."
$allStocks = Get-StockListFromDayFiles
$stockCount = $allStocks.Count
Write-Output "Stocks loaded: $stockCount"
if ($stockCount -eq 0) { Write-Error "No stocks loaded!"; exit 1 }

# ============ 2. Get quotes from Tencent/qt ============
Write-Output "Step 2: Fetching stock prices..."
$stockMap = @{}
$allPrefixed = @()
foreach ($s in $allStocks) { $stockMap[$s.Code] = $s; $allPrefixed += "$($s.Market)$($s.Code)" }

function Get-BatchQuotes {
    param([string[]]$PrefixedCodes)
    $result = @{}; $batchSize = 50
    for ($i = 0; $i -lt $PrefixedCodes.Count; $i += $batchSize) {
        $end = [Math]::Min($i+$batchSize-1, $PrefixedCodes.Count-1)
        $qs = $PrefixedCodes[$i..$end] -join ','
        try {
            $webResp = Invoke-WebRequest -Uri "http://qt.gtimg.cn/q=$qs" -TimeoutSec 15 -UseBasicParsing
            $resp = $webResp.Content
            $lines = $resp -split "`n"
            foreach ($line in $lines) {
                if ($line.Length -gt 20 -and $line.Contains("=")) {
                    $eqIdx = $line.IndexOf("=")
                    $val = $line.Substring($eqIdx + 1).Trim('"')
                    $parts = $val -split '~'
                    if ($parts.Count -ge 32) {
                        $code = $parts[2]; $cur = [double]($parts[3]); $pc = [double]($parts[4])
                        $change = if ($pc -ne 0) { [Math]::Round(($cur - $pc) / $pc * 100, 2) } else { 0 }
                        $result[$code] = @{Name=$parts[1]; Price=$cur; Change=$change}
                    }
                }
            }
        } catch {
            Write-Warning ("Quote batch ${i}: " + $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 80
    }
    return $result
}

$allPrefixed = $allPrefixed[0..[Math]::Min(4999, $allPrefixed.Count-1)]
$stockQuotes = Get-BatchQuotes -PrefixedCodes $allPrefixed
Write-Output "Quotes: $($stockQuotes.Count) stocks"

# ============ 2.5 Load cache ============
$CacheFile = Join-Path $PSScriptRoot "cache_prev_change.json"
$prevChangeMap = @{}
if (Test-Path $CacheFile) {
    try {
        $json = Get-Content $CacheFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($k in $json.PSObject.Properties) { $prevChangeMap[$k.Name] = [double]$k.Value }
    } catch { }
}

# ============ 3. Fetch announcements ============
Write-Output "Step 3: Fetching announcements from CNINFO..."
function Get-CNINFOAnn {
    param([string]$Plate)
    $all = [System.Collections.ArrayList]::new(); $pageNum = 1; $seDate = "$Date~$Date"
    while ($pageNum -le 100) {
        $body = @{stock=''; pageNum=$pageNum; pageSize=30; tabName='fulltext'; plate=$Plate; seDate=$seDate; sortName='announcementTime'; sortType='desc'}
        try {
            $r = Invoke-RestMethod -Uri 'http://www.cninfo.com.cn/new/hisAnnouncement/query' -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15
            if ($r.announcements -and $r.announcements.Count -gt 0) { $all.AddRange($r.announcements); $pageNum++; if ($all.Count -ge $r.totalAnnouncement) { break } }
            else { break }
        } catch { break }
    }
    return $all
}
$ann = Get-CNINFOAnn -Plate 'sz'
$ann2 = Get-CNINFOAnn -Plate 'sh'
$allAnn = $ann + $ann2
Write-Output "CNINFO: $($allAnn.Count) announcements"

# ============ 4. Process ============
$CATS = @{100="业绩预告";95="分红送转";90="并购重组";85="定期报告";80="股东变动";75="重大事项";70="担保质押";65="关联交易";60="债券相关";55="公司治理";50="补充更正";45="停复牌风险";40="股权激励";35="限售解禁";30="审计评估";20="独立董事";10="其他"}
$CAT_PATTERNS = @(
    @{P=100; R='业绩预告|业绩快报|业绩修正|盈利预告'}, @{P=95; R='分红|送转|利润分配|派息|股息'},
    @{P=90; R='收购|并购|重组|借壳|重大资产'}, @{P=85; R='年报|年度报告|半年度报告|季度报告|中报'},
    @{P=80; R='增持|减持|回购|增发|定增|配股'}, @{P=70; R='担保|质押|授信|借款'},
    @{P=60; R='可转债|债券|债务|兑付|信用评级'}, @{P=55; R='股东大会|董事会|监事会|决议|通知'},
    @{P=50; R='澄清|更正|补充|说明|致歉'}, @{P=45; R='停牌|复牌|ST|退市|风险提示'},
    @{P=40; R='股权激励|员工持股|期权'}, @{P=35; R='解禁|限售'}, @{P=30; R='审计|会计|评估|报告'},
    @{P=20; R='独立董事|提名|述职|意见'}
)
function Get-Cat {
    param([string]$T)
    if ([string]::IsNullOrWhiteSpace($T)) { return 10 }
    foreach ($c in $CAT_PATTERNS) { if ($T -match $c.R) { return $c.P } }
    return 10
}
function Get-Sent {
    param([string]$T)
    if ($T -match '业绩预增|业绩大增|大幅上升|扭亏为盈|中标|重大合同|战略合作|增持|回购|分红|送转|利润分配|收购|并购') { return 1 }
    if ($T -match '业绩预亏|业绩亏损|大幅下降|预亏|风险提示|退市|ST|被调查|处罚|处分|立案|冻结|债务违约') { return -1 }
    return 0
}
function Get-FCAST {
    param([string]$T, [string]$D, [string]$U)
    $r = @{H=$false; D="-"; Tip=""; C=""; U=""}
    if ($T -match '业绩预告|业绩快报|业绩预增|盈利预告|半年度业绩|一季度业绩') {
        $r.H = $true; $r.D = $D; $r.U = $U
        if ($T -match '预增|大增|大幅上升|大幅增长') { $r.Tip = "业绩预增"; $r.C = "up" }
        elseif ($T -match '扭亏为盈') { $r.Tip = "扭亏为盈"; $r.C = "up" }
        elseif ($T -match '大幅下降|业绩亏损|大幅下滑|预亏') { $r.Tip = "业绩预亏"; $r.C = "down" }
        else { $r.Tip = "业绩预告"; $r.C = "neutral" }
    }
    return $r
}

# K-line
function Get-Kline {
    param([string]$Code)
    $p = if ($Code -match '^(60|688)') {"sh"} else {"sz"}
    $f = "$TDXDir\vipdoc\$p\lday\$p$Code.day"
    if (-not (Test-Path $f)) { return $null }
    try {
        $fs = [System.IO.File]::OpenRead($f); $reader = New-Object System.IO.BinaryReader($fs)
        $total = $fs.Length / 32; $s = [Math]::Max(0, $total - 20)
        $reader.BaseStream.Seek($s * 32, [System.IO.SeekOrigin]::Begin) | Out-Null
        $result = @()
        for ($i = $s; $i -lt $total; $i++) {
            $reader.ReadUInt32() | Out-Null
            $result += [Math]::Round($reader.ReadUInt32()/100,2), [Math]::Round($reader.ReadUInt32()/100,2), [Math]::Round($reader.ReadUInt32()/100,2), [Math]::Round($reader.ReadUInt32()/100,2)
            $reader.ReadUInt32() | Out-Null; $reader.ReadUInt32() | Out-Null; $reader.ReadUInt32() | Out-Null
        }
        $reader.Close(); $fs.Close(); return $result
    } catch { return $null }
}
function Get-TREND {
    param([array]$K)
    $labels = @()
    if (-not $K -or $K.Count -lt 60) { return $labels }
    $n = $K.Count / 4; $h = @(); $l = @(); $c = @(); $o = @()
    for ($i = 0; $i -lt $n; $i++) { $o += $K[$i*4]; $h += $K[$i*4+1]; $l += $K[$i*4+2]; $c += $K[$i*4+3] }
    if ($c[-1] -gt $o[-1]) { $labels += "sudden" }
    $i15 = [Math]::Max(0, $n-15); $i75 = [Math]::Max(0, $n-75)
    $d75H = ($h[$i75..($n-1)] | Measure-Object -Maximum).Maximum
    $d15H = ($h[$i15..($n-1)] | Measure-Object -Maximum).Maximum
    if ($d75H -gt 0 -and $d15H -ge $d75H * 0.99) {
        $d2H = ($h[-2..-1] | Measure-Object -Maximum).Maximum; $d2L = ($l[-2..-1] | Measure-Object -Minimum).Minimum; $d2A = ($d2H + $d2L) / 2
        if ($d2A -ge $d75H * 0.9) { $labels += "strong" }
        $d15L = ($l[$i15..($n-1)] | Measure-Object -Minimum).Minimum; $d15A = ($d15H + $d15L) / 2
        if ($d2A -gt $d15A) { $labels += "hold" }
    }
    return $labels
}

Write-Output "Step 4: Processing..."
$processed = [System.Collections.ArrayList]::new(); $seen = @{}
foreach ($annItem in $allAnn) {
    $code = $annItem.secCode; $title = $annItem.announcementTitle; $name = $annItem.secName
    $timeMs = $annItem.announcementTime; $aid = $annItem.announcementId
    if ($seen.ContainsKey($aid)) { continue }; $seen[$aid] = $true
    if ($code -notmatch '^\d{6}$') { continue }
    $qi = $stockQuotes[$code]
    $ps = if ($qi) { 10 + [Math]::Min(90, [Math]::Abs($qi.Change) * 5 + (0 / 10)) } else { 10 }
    $cp = (Get-Cat -T $title); $score = [Math]::Round($ps * 0.4 + $cp * 0.6, 0)
    $board = if ($code -match '^60') {"A"} elseif ($code -match '^30') {"C"} elseif ($code -match '^00') {"B"} elseif ($code -match '^68') {"K"} else {"O"}
    $dtStr = if ($timeMs) { (Get-Date "1970-01-01 00:00:00").AddMilliseconds([long]$timeMs).ToString('HH:mm:ss') } else {'--'}
    $cpNow = if ($qi) { $qi.Change } else { $null }
    $sv = Get-Sent -T $title; $sl = if ($sv -eq 1) {"up"} elseif ($sv -eq -1) {"down"} else {"mid"}
    $pc = $prevChangeMap[$code]; $cs = 50; $cl = "mid"
    if ($pc -ne $null -and $pc -ne 0) {
        $abs = [Math]::Abs($pc)
        if ($sv -eq 1 -and $pc -gt 0) { $cs = [Math]::Min(100,[Math]::Round(80+$abs*2)); $cl = "good" }
        elseif ($sv -eq -1 -and $pc -lt 0) { $cs = [Math]::Min(100,[Math]::Round(80+$abs*2)); $cl = "bad" }
        elseif (($sv -eq 1 -and $pc -lt 0) -or ($sv -eq -1 -and $pc -gt 0)) { $cs = [Math]::Max(10,[Math]::Round(50-$abs*3)); $cl = "warn" }
    }
    $kl = Get-Kline -Code $code; $tl = if ($kl) { Get-TREND -K $kl } else { @() }
    $fc = Get-FCAST -T $title -D $Date -U "http://www.cninfo.com.cn/new/disclosure/detail?announcementId=$aid"
    if ($tl -and $tl.Count -gt 0) {
        $null = $processed.Add([PSCustomObject]@{
            Score=$score; Code=$code; Name=$name; Title=$title; Cat=$cp; Time=$dtStr; Board=$board
            Mcap=if($qi){0}else{0}; CP=$cpNow; S=$sl; CS=$cs; CL=$cl; TL=$tl
            Url="http://www.cninfo.com.cn/new/disclosure/detail?announcementId=$aid"
            FH=$fc.H; FD=$fc.D; FT=$fc.Tip; FC=$fc.C; FU=$fc.U
        })
    }
}
$sorted = $processed | Sort-Object Score -Descending
Write-Output "Final: $($sorted.Count) items"

# Group by stock: keep top item per stock, stash sub-items for hover
$stockGroups = $sorted | Group-Object Code
$groupedItems = @()
foreach ($g in $stockGroups) {
    $top = $g.Group | Sort-Object Score -Descending | Select-Object -First 1
    $subs = $g.Group | Sort-Object Score -Descending | Select-Object -Skip 1
    $top | Add-Member -NotePropertyName Subs -NotePropertyValue $subs -Force
    $groupedItems += $top
}
$sorted = $groupedItems | Sort-Object Score -Descending
Write-Output "Grouped: $($sorted.Count) stocks (with subs for hover)"

# ============ 5. Generate HTML ============
Write-Output "Step 5: Generating HTML..."
$boardMap = @{"A"="沪市主板";"B"="深市主板";"C"="创业板";"K"="科创板";"O"="其他"}
$sentLabel = @{"up"="利好";"down"="利空";"mid"="中性"}
$corrLabel = @{"good"="利好兑现";"bad"="利空释放";"warn"="走势背离";"mid"="中性"}
$catLabel = $CATS

$itemsHtml = ""; $i = 1
foreach ($item in $sorted) {
    $cc = if ($item.Score -ge 80){'high'}elseif($item.Score -ge 60){'medium'}else{'normal'}
    $chv = 999
    $ch = if ($item.CP -ne $null){$chv=[Math]::Round($item.CP,1);$c=if($item.CP-gt0){'up'}elseif($item.CP-lt0){'down'}else{''};"<span class='change $c'>$chv%</span>"}else{''}
    $ms = if($item.Mcap-gt0){"$([Math]::Round($item.Mcap))亿"}else{''}
    $se = $item.Title -replace '"','&quot;'
    $st = $sentLabel[$item.S]
    $stTag = if($st-eq"利好"){"<span class='sentiment positive'>利好</span>"}elseif($st-eq"利空"){"<span class='sentiment negative'>利空</span>"}else{"<span class='sentiment neutral'>中性</span>"}
    $cs = $item.CS; $cl = $corrLabel[$item.CL]
    $corrClass = if($cs-ge70){"high"}elseif($cs-ge45){"medium"}else{"low"}
    $sentHtml = "$stTag<div class='corr-info'><span class='corr-score $corrClass'>$cs</span><span class='corr-label'>$cl</span></div>"
    $trendHtml = ""; $trendScore = 0
    foreach($tl in $item.TL){
        if($tl-eq"strong"){$tc="trend-strong";$tn="趋势增强";if($trendScore-lt3){$trendScore=3}}
        elseif($tl-eq"hold"){$tc="trend-hold";$tn="趋势维持";if($trendScore-lt2){$trendScore=2}}
        elseif($tl-eq"sudden"){$tc="trend-surge";$tn="突发量变";if($trendScore-lt1){$trendScore=1}}
        if($tc){$trendHtml+="<span class='trend-tag $tc'>$tn</span>"}
    }
    if(-not$trendHtml){$trendHtml="<span class='trend-na'>-</span>"}
    $fcHtml = if($item.FH){"<a href='$($item.Url)' target='_blank' title='$($item.FT)' class='forecast-link $($item.FC)'>$($item.FD)</a>"}else{"-"}
    $emPrefix = if($item.Code-match'^(60|688)'){'sh'}else{'sz'}
    $emUrl = "http://qt.gtimg.cn/q=$emPrefix$($item.Code)"
    # Build sub-items data (pipe-separated "title|url" entries, double-pipe between items)
    $subData = ""; $hasSubs = $false; $subCount = 0
    if ($item.Subs -and $item.Subs.Count -gt 0) {
        $hasSubs = $true; $subCount = $item.Subs.Count
        $subParts = @()
        foreach ($s in $item.Subs) {
            $tClean = $s.Title -replace '"','&quot;'
            $sPrefix = if($s.Code-match'^(60|688)'){'sh'}else{'sz'}
            $subParts += "$tClean|$($s.Url)"
        }
        $subData = $subParts -join "||"
    }
    $titleCell = if($hasSubs) {
        "<span class='title-main' data-subs='$subData'><a href='$($item.Url)' target='_blank' title='$se'>$($item.Title)</a><span class='sub-badge'>+$subCount</span></span><div class='sub-popup' style='display:none'></div>"
    } else {
        "<a href='$($item.Url)' target='_blank' title='$se'>$($item.Title)</a>"
    }
    $itemsHtml += @"
    <tr class="$cc" data-change="$chv" data-corr="$($item.CS)" data-trend="$trendScore"><td class="rank">$i</td><td class="code"><a href="$emUrl" target="_blank">$($item.Code)</a></td><td class="name">$($item.Name)</td><td class="board">$($boardMap[$item.Board])</td><td class="title-col">$titleCell</td><td class="cat"><span class="cat-tag $cc">$($catLabel[[int]$item.Cat])</span></td><td class="score">$($item.Score)</td><td class="mcap">$ms</td><td class="change-cell">$ch</td><td class="corr-cell">$sentHtml</td><td class="trend-cell">$trendHtml</td><td class="forecast-cell">$fcHtml</td><td class="time">$($item.Time)</td></tr>
"@
    $i++
}
$total = $sorted.Count; $gt = Get-Date -Format 'HH:mm'

$html = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>A股公告热门排行 | $Date</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;background:#f0f2f5;color:#333}
.header{background:linear-gradient(135deg,#1a1a2e,#16213e,#0f3460);color:#fff;padding:24px;text-align:center}
.header h1{font-size:24px;font-weight:700}
.header .stats{font-size:13px;opacity:.9;margin-top:6px}
.container{max-width:1400px;margin:16px auto;padding:0 16px}
.controls{display:flex;gap:12px;margin-bottom:12px;flex-wrap:wrap;align-items:center}
.search-box{padding:8px 14px;border:1px solid #d9d9d9;border-radius:6px;width:220px}
.table-wrapper{background:#fff;border-radius:10px;box-shadow:0 1px 6px rgba(0,0,0,.08);overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:13px}
thead{background:#fafafa;border-bottom:2px solid #e8e8e8}
th{padding:12px 14px;text-align:left;font-weight:600;color:#555;font-size:12px;white-space:nowrap;cursor:pointer}
th.sortable::after{content:' \2195';opacity:.3}
td{padding:10px 14px;border-bottom:1px solid #f0f0f0;vertical-align:middle}
tr:hover{background:#f7f9fc}
.rank{font-weight:700;color:#888;width:40px;text-align:center}
tr.high .rank{color:#e74c3c}tr.medium .rank{color:#e67e22}
.code{font-family:monospace;font-weight:500}
.code a{color:#555;text-decoration:none}
.code a:hover{color:#0f3460}
.title-col{max-width:400px}
.title-col a{color:#333;text-decoration:none;display:-webkit-box;-webkit-line-clamp:1;-webkit-box-orient:vertical;overflow:hidden}
.title-col a:hover{color:#0f3460;text-decoration:underline}
.cat-tag{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px}
.cat-tag.high{background:#fde8e8;color:#c0392b}
.cat-tag.medium{background:#fef3e2;color:#d35400}
.cat-tag.normal{background:#f0f0f0;color:#666}
.score{font-weight:700;font-family:monospace;font-size:14px}
tr.high .score{color:#e74c3c}tr.medium .score{color:#e67e22}
.change{font-family:monospace;font-size:12px}
.change.up{color:#e74c3c}.change.down{color:#27ae60}
.sentiment{display:inline-block;padding:1px 7px;border-radius:3px;font-size:11px;font-weight:600}
.sentiment.positive{background:#e8f5e9;color:#2e7d32}
.sentiment.negative{background:#fde8e8;color:#c62828}
.sentiment.neutral{background:#f5f5f5;color:#999}
.corr-info{display:flex;align-items:center;justify-content:center;gap:4px;margin-top:3px}
.corr-score{font-family:monospace;font-size:12px;font-weight:700}
.trend-tag{display:inline-block;padding:1px 6px;border-radius:3px;font-size:10px;font-weight:600;margin:1px 0}
.trend-tag.trend-strong{background:#e8f5e9;color:#1b5e20;border:1px solid #a5d6a7}
.trend-tag.trend-hold{background:#e3f2fd;color:#1565c0;border:1px solid #90caf9}
.trend-tag.trend-surge{background:#fff3e0;color:#e65100;border:1px solid #ffcc80}
.forecast-cell{text-align:center;min-width:80px}
.forecast-link{text-decoration:none;font-weight:600;padding:2px 8px;border-radius:4px;display:inline-block}
.forecast-link:hover{text-decoration:underline}
.sub-badge{display:inline-block;margin-left:4px;padding:1px 6px;border-radius:8px;background:#0f3460;color:#fff;font-size:10px;font-weight:700;line-height:1.4;vertical-align:middle;cursor:help}
.title-main{position:relative;cursor:pointer}
.title-main:hover .sub-popup,.sub-popup:hover{display:block!important}
.sub-popup{position:fixed;z-index:9999;background:#fff;border:1px solid #d9d9d9;border-radius:8px;box-shadow:0 4px 20px rgba(0,0,0,.15);padding:8px 0;max-height:300px;overflow-y:auto;min-width:320px;max-width:500px}
.sub-popup .sub-item{padding:6px 14px;font-size:12px;color:#333;cursor:pointer;display:block;text-decoration:none;border-bottom:1px solid #f0f0f0}
.sub-popup .sub-item:last-child{border-bottom:none}
.sub-popup .sub-item:hover{background:#f0f4ff;color:#0f3460}
.sub-popup .sub-item .sub-url{color:#999;font-size:11px;text-decoration:none}
.sub-popup .sub-item:hover .sub-url{color:#0f3460}
.forecast-link.up{color:#e74c3c;background:#fde8e8}
.forecast-link.down{color:#27ae60;background:#e8f5e9}
.forecast-link.neutral{color:#0f3460;background:#e3f2fd}
.time{font-family:monospace;color:#999;font-size:12px}
.footer{text-align:center;padding:20px;color:#bbb;font-size:12px}
</style></head>
<body>
<div class="header"><h1>A股公告热门排行</h1><div class="subtitle">$Date | 数据源:通达信+腾讯行情+本地K线</div><div class="stats">共 $total 条公告 更新 $gt</div></div>
<div class="container">
<div class="controls">
<label>搜索:</label><input type="text" class="search-box" id="searchBox" placeholder="代码/名称/标题..." oninput="filterTable()">
</div>
<div class="table-wrapper"><table><thead><tr><th style="width:40px">#</th><th class="sortable" onclick="sortTable(1)">代码</th><th class="sortable" onclick="sortTable(2)">名称</th><th>板块</th><th class="sortable" onclick="sortTable(4)">公告标题</th><th>分类</th><th class="sortable asc" onclick="sortTable(6)">热度</th><th>市值</th><th class="sortable" onclick="sortTable(8)">涨跌幅</th><th>关联分析</th><th>趋势位置</th><th>业绩预告</th><th>时间</th></tr></thead>
<tbody id="tableBody">$itemsHtml</tbody>
</table></div>
<div class="footer">数据来源:CNINFO(巨潮资讯网) 行情:qt.gtimg.cn K线:TDX本地.day | TDX安装:$TDXDir</div>
</div>
<script>
function filterTable(){var q=document.getElementById('searchBox').value.toLowerCase(),rows=document.querySelectorAll('#tableBody tr');rows.forEach(function(r){var m=false;for(var i=1;i<=4;i++){if(r.cells[i]?.textContent.toLowerCase().includes(q)){m=true;break}}r.style.display=m||!q?'':'none'})}
function sortTable(c){var t=document.getElementById('tableBody'),r=Array.from(t.querySelectorAll('tr'));var d=t.getAttribute('d')==='a'?'d':'a';t.setAttribute('d',d);r.sort(function(a,b){var v1=a.cells[c]?.textContent||'',v2=b.cells[c]?.textContent||'';var n1=parseFloat(v1),n2=parseFloat(v2);if(!isNaN(n1)&&!isNaN(n2)){return d==='a'?n1-n2:n2-n1}return d==='a'?v1.localeCompare(v2,'zh-CN'):v2.localeCompare(v1,'zh-CN')});r.forEach(function(x,i){x.cells[0].textContent=i+1;t.appendChild(x)})}
document.addEventListener('mouseover',function(e){var m=e.target.closest('.title-main');var pops=document.querySelectorAll('.sub-popup');if(!m){pops.forEach(function(p){p.style.display='none'});return}var popup=m.querySelector('.sub-popup');if(!popup)return;var subs=m.getAttribute('data-subs');if(!subs){popup.style.display='none';return}if(popup.dataset.loaded!=='1'){var html='';subs.split('||').forEach(function(s){var sep=s.indexOf('|');if(sep<0)return;var t=s.substring(0,sep),u=s.substring(sep+1);html+="<a class='sub-item' href='"+u+"' target='_blank'>"+t+"</a>"});popup.innerHTML=html;popup.dataset.loaded='1'}popup.style.display='block';var r=m.getBoundingClientRect();popup.style.left=Math.min(r.left,window.innerWidth-popup.offsetWidth-10)+'px';popup.style.top=(r.bottom+4)+'px'})
</script>
</body>
</html>
"@

$html | Out-File -FilePath $OutputFile -Encoding utf8
Write-Output "Generated: $OutputFile"

# Save cache
try {
    $saveObj = @{}
    foreach ($k in $stockQuotes.Keys) { if ($stockQuotes[$k].Change -ne $null -and $stockQuotes[$k].Change -ne 0) { $saveObj[$k] = $stockQuotes[$k].Change } }
    if ($saveObj.Count -gt 10) {
        $saveJson = $saveObj | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($CacheFile, $saveJson, [System.Text.UTF8Encoding]::new($false))
    }
} catch { }

Write-Output "Done!"
