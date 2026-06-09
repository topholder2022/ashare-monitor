<#
  A-share Announcement Hot Ranking Generator
  Fetches A-share listed company announcements, ranks by popularity, generates HTML
#>

param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [int]$MaxPages = 100,
    [string]$OutputDir = "$PSScriptRoot\output"
)

# Configuration
$OutputDate = $Date -replace '-', ''
$OutputFile = Join-Path $OutputDir "$Date.html"
$TempDir = Join-Path $env:TEMP "ashare_$OutputDate"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

Write-Output "=== A-Share Monitor ==="
Write-Output "Date: $Date"

# ============ 1. Fetch from CNINFO ============
function Get-Announcements {
    param([string]$Plate)
    $all = [System.Collections.ArrayList]::new()
    $pageNum = 1
    $seDate = "$Date~$Date"
    while ($pageNum -le $MaxPages) {
        $body = @{stock=''; pageNum=$pageNum; pageSize=30; tabName='fulltext'; plate=$Plate; seDate=$seDate; sortName='announcementTime'; sortType='desc'}
        try {
            $r = Invoke-RestMethod -Uri 'http://www.cninfo.com.cn/new/hisAnnouncement/query' -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15
            if ($r.announcements -and $r.announcements.Count -gt 0) {
                $all.AddRange($r.announcements)
                $pageNum++
                if ($all.Count -ge $r.totalAnnouncement) { break }
            } else { break }
        } catch {
            Write-Warning "CNINFO error (plate=$Plate page=$pageNum): $($_.Exception.Message)"
            break
        }
    }
    return $all
}

Write-Output "Fetching announcements..."
$szAnn = Get-Announcements -Plate 'sz'
$shAnn = Get-Announcements -Plate 'sh'
$allAnn = $szAnn + $shAnn
Write-Output "Total: $($allAnn.Count) (SZ: $($szAnn.Count), SH: $($shAnn.Count))"

# ============ 2. Fetch Stock Popularity ============
Write-Output "Fetching popularity data..."
function Get-StockPopularity {
    $popMap = @{}
    $allStocks = [System.Collections.ArrayList]::new()
    $page = 1; $pageSize = 200
    do {
        $url = "http://push2.eastmoney.com/api/qt/clist/get?cb=&pn=$page&pz=$pageSize&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f20&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23&fields=f12,f20,f3"
        try {
            $r = Invoke-RestMethod -Uri $url -TimeoutSec 15
            if ($r.data -and $r.data.diff -and $r.data.diff.Count -gt 0) {
                $allStocks.AddRange($r.data.diff)
                $page++
                if ($page -gt 10) { break }
            } else { break }
        } catch { Write-Warning "EastMoney error: $($_.Exception.Message)"; break }
    } while ($true)
    foreach ($s in $allStocks) {
        $code = $s.f12; $mcap = if ($s.f20) {[double]$s.f20}else{0}
        $change = if ($s.f3) {[double]$s.f3}else{0}
        $mcapScore = [Math]::Min(100, [Math]::Log($mcap/1e9+1,2)*10)
        $volScore = [Math]::Min(100, [Math]::Abs($change)*5+50)
        $popMap[$code] = @{Score=[Math]::Round($mcapScore*0.6+$volScore*0.4,1); Mcap=$mcap; ChangePct=$change}
    }
    return $popMap
}
$stockPop = Get-StockPopularity
Write-Output "Popularity data: $($stockPop.Count) stocks"

# Tencent API fallback if EastMoney returned no data
if ($stockPop.Count -eq 0 -and $allAnn.Count -gt 0) {
    Write-Output "EastMoney returned no data, trying Tencent API fallback..."
    $uniqueCodes = @{}
    foreach ($ann in $allAnn) {
        $code = $ann.secCode
        if ($code -match '^\d{6}$') {
            $prefix = if ($code -match '^(60|688)') {'sh'} else {'sz'}
            $uniqueCodes["$prefix$code"] = $code
        }
    }
    $codesList = @($uniqueCodes.Keys); $batchSize = 50
    for ($i = 0; $i -lt $codesList.Count; $i += $batchSize) {
        $end = [Math]::Min($i+$batchSize-1, $codesList.Count-1)
        $batch = $codesList[$i..$end] -join ','
        try {
            $resp = Invoke-RestMethod -Uri "http://qt.gtimg.cn/q=$batch" -TimeoutSec 15
            $resp -split '\n' | ForEach-Object {
                if ($_ -match 'v_\w+="(.+)"') {
                    $parts = $matches[1] -split '~'
                    if ($parts.Count -ge 32) {
                        $sc = $parts[2]; $cp = [double]($parts[3]); $pc = [double]($parts[4])
                        $chg = if ($pc -ne 0) { [Math]::Round(($cp - $pc) / $pc * 100, 2) } else { 0 }
                        if ($sc -and -not $stockPop.ContainsKey($sc) -and $sc -match '^\d{6}$') {
                            $stockPop[$sc] = @{Score=0; Mcap=0; ChangePct=$chg}
                        }
                    }
                }
            }
        } catch { Write-Warning "Tencent API batch error: $($_.Exception.Message)" }
    }
    Write-Output "Tencent fallback: $($stockPop.Count) stocks"
}

# ============ 2.5 Load/Save Cache for Previous Trading Day ============
$CacheFile = Join-Path $PSScriptRoot "cache_prev_change.json"
$prevChangeMap = @{}
if (Test-Path $CacheFile) {
    try {
        $json = Get-Content $CacheFile -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($k in $json.PSObject.Properties) {
            $prevChangeMap[$k.Name] = [double]$k.Value
        }
        Write-Output "Loaded cached changes: $($prevChangeMap.Count) stocks"
    } catch { Write-Warning "Cache load failed: $($_.Exception.Message)" }
}
# Save today's data as cache for next run (only if we have meaningful data, skip at 9 AM pre-market)
try {
    $saveObj = @{}
    foreach ($k in $stockPop.Keys) {
        if ($stockPop[$k].ChangePct -ne $null) { $saveObj[$k] = $stockPop[$k].ChangePct }
    }
    $saveHour = (Get-Date).Hour; $saveMin = (Get-Date).Minute
    $tooEarly = ($saveHour -eq 9 -and $saveMin -lt 30) -or ($saveHour -lt 9)
    $hasNonZero = ($saveObj.Values | Where-Object { $_ -ne 0 }).Count -gt 2
    if ($saveObj.Count -gt 0 -and $hasNonZero -and -not $tooEarly) {
        $saveJson = $saveObj | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($CacheFile, $saveJson, [System.Text.UTF8Encoding]::new($false))
        Write-Output "Saved cache: $($saveObj.Count) stocks"
    } elseif ($saveObj.Count -gt 0) {
        Write-Output "Skipped cache save (pre-market or no meaningful data)"
    }
} catch { Write-Warning "Cache save failed: $($_.Exception.Message)" }

# ============ 3. Categorize ============
function Get-Category {
    param([string]$T)
    if ([string]::IsNullOrWhiteSpace($T)) { return @{P=10; L=([char]0x5176+[char]0x4ed6); S=""} }
    $patterns = @(
        @{P=100; R='业绩预告|业绩快报|业绩修正|盈利预告'}, @{P=95; R='分红|送转|利润分配|派息|股息'},
        @{P=90; R='收购|并购|重组|借壳|重大资产'}, @{P=85; R='年报|年度报告|半年度报告|季度报告|一季度|三季度|中报'},
        @{P=80; R='增持|减持|回购|增发|定增|配股'}, @{P=75; R='重大合同|中标|战略合作|框架协议|重大事项'},
        @{P=70; R='担保|质押|解押|授信|借款'}, @{P=65; R='关联交易|关联方'},
        @{P=60; R='可转债|债券|债务|兑付|信用评级'}, @{P=55; R='股东大会|董事会|监事会|决议|通知'},
        @{P=50; R='澄清|更正|补充|说明|致歉'}, @{P=45; R='停牌|复牌|ST|退市|风险提示'},
        @{P=40; R='股权激励|员工持股|期权'}, @{P=35; R='解禁|限售'},
        @{P=30; R='审计|会计|评估|报告'}, @{P=20; R='独立董事|提名|述职|意见'}
    )
    foreach ($cat in $patterns) {
        if ($T -match $cat.R) {
            $s = $T -replace '\s+',' ' -replace '公告$',''
            if ($s.Length -gt 80) { $s = $s.Substring(0,77) + '...' }
            return @{P=$cat.P; L=""; S=$s}
        }
    }
    $cl = $T -replace '\s+',' ' -replace '公告$',''
    if ($cl.Length -gt 80) { $cl = $cl.Substring(0,77) + '...' }
    return @{P=10; L=([char]0x5176+[char]0x4ed6); S=$cl}
}

$global:catLabels = @{100="业绩预告";95="分红送转";90="并购重组";85="定期报告";80="股东变动";75="重大事项";70="担保质押";65="关联交易";60="债券相关";55="公司治理";50="补充更正";45="停复牌风险";40="股权激励";35="限售解禁";30="审计评估";20="独立董事";10="其他"}

function Get-CategoryLabel {
    param([int]$P)
    if ($global:catLabels.ContainsKey($P)) { return $global:catLabels[$P] } else { return "其他" }
}

# ============ 3.5 Sentiment Analysis ============
function Get-Sentiment {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return 0 }
    # 利好 keywords
    $positive = @('业绩预增','业绩大增','大幅上升','扭亏为盈','盈利','利润大涨','大幅增长','中标','重大合同','战略合作','框架协议','增持','回购','分红','送转','利润分配','派息','股息','收购','并购','重组','借壳','资产注入','获批','核准','豁免','摘帽')
    # 利空 keywords
    $negative = @('业绩预亏','业绩亏损','大幅下降','预亏','亏损','利润下滑','营收下降','减持','质押','担保','诉讼','仲裁','风险提示','退市','ST','跌停','债务违约','被调查','处罚','处分','警示','整改','延期','取消','终止','失败','立案','冻结')
    foreach ($kw in $positive) { if ($Title -match $kw) { return 1 } }
    foreach ($kw in $negative) { if ($Title -match $kw) { return -1 } }
    return 0
}

# ============ 3.7 Trend Position Analysis ============
function Get-KlineData {
    param([string[]]$StockCodes)
    $klineMap = @{}; $total = $StockCodes.Count
    Write-Host "Fetching K-line data for $total stocks..."
    for ($i = 0; $i -lt $total; $i++) {
        $code = $StockCodes[$i]
        $prefix = if ($code -match '^(60|688)') {'sh'} else {'sz'}
        try {
            $raw = Invoke-WebRequest -Uri "http://web.ifzq.gtimg.cn/appstock/app/fqkline/get?_var=kline_dayqfq&param=${prefix}${code},day,2026-01-01,,260,qfq" -TimeoutSec 10 -UseBasicParsing
            $jsonText = $raw.Content
            if ($jsonText -match 'kline_dayqfq=(.*)') {
                $parsed = $matches[1] | ConvertFrom-Json
                $dayData = $parsed.data."${prefix}${code}".qfqday
                if ($dayData -and $dayData.Count -gt 10) { $klineMap[$code] = $dayData }
            }
        } catch { }
        if ($i % 10 -eq 9) { Start-Sleep -Milliseconds 200 }
    }
    Write-Host "K-line data: $($klineMap.Count) stocks"
    return $klineMap
}

function Get-TrendPosition {
    param([array]$Kline)
    $labels = @()
    if (-not $Kline -or $Kline.Count -lt 15) { return $labels }
    # Data format: [date, open, close, high, low, volume] — oldest first
    # Convert all fields upfront
    $highs = foreach ($e in $Kline) { [double]$e[3] }
    $lows  = foreach ($e in $Kline) { [double]$e[4] }
    $vols  = foreach ($e in $Kline) { [long]($e[5] -replace '\..*') }
    $opens = foreach ($e in $Kline) { [double]$e[1] }
    $closes= foreach ($e in $Kline) { [double]$e[2] }
    $n = $Kline.Count
    # 突发量变 (criterion 3): last 10 days vol == last 230 days vol AND 阳线
    $i10 = [Math]::Max(0, $n-10)
    $i230 = [Math]::Max(0, $n-230)
    $d10Vol  = ($vols[$i10..($n-1)] | Measure-Object -Maximum).Maximum
    $d230Vol = ($vols[$i230..($n-1)] | Measure-Object -Maximum).Maximum
    if ($d10Vol -eq $d230Vol -and $closes[-1] -gt $opens[-1]) { $labels += "突发量变" }
    # Last 15 / 75 days for precondition and trend evaluation
    $i15 = [Math]::Max(0, $n-15)
    $i75 = [Math]::Max(0, $n-75)
    $d75High = ($highs[$i75..($n-1)] | Measure-Object -Maximum).Maximum
    $d15High = ($highs[$i15..($n-1)] | Measure-Object -Maximum).Maximum
    $atPeak = ($d75High -gt 0 -and [Math]::Abs($d75High - $d15High) / $d75High -lt 0.001)
    # 趋势增强: precondition + d2Avg within 10% of 75-day highest
    $i2 = [Math]::Max(0, $n-2)
    $d2High = ($highs[$i2..($n-1)] | Measure-Object -Maximum).Maximum
    $d2Low  = ($lows[$i2..($n-1)] | Measure-Object -Minimum).Minimum
    $d2Avg = ($d2High + $d2Low) / 2
    if ($atPeak -and $d2Avg -ge $d75High * 0.9) { $labels += "趋势增强" }
    # 趋势维持: precondition + d2Avg > 15-day avg
    $d15Low  = ($lows[$i15..($n-1)] | Measure-Object -Minimum).Minimum
    $d15Avg = ($d15High + $d15Low) / 2
    if ($atPeak -and $d2Avg -gt $d15Avg) { $labels += "趋势维持" }
    return $labels
}

# Fetch K-line for unique stock codes
$uniqueCodes = @()
foreach ($ann in $allAnn) {
    $c = $ann.secCode
    if ($c -match '^\d{6}$' -and $uniqueCodes -notcontains $c) { $uniqueCodes += $c }
}
Write-Output "Unique stock codes: $($uniqueCodes.Count)"
$klineMap = Get-KlineData -StockCodes $uniqueCodes
# Supplement cache with K-line data (for tomorrow's PrevChangePct) — DON'T modify prevChangeMap used for display
try {
    $supObj = @{}
    foreach ($code in $klineMap.Keys) {
        if (-not $prevChangeMap.ContainsKey($code) -and $klineMap[$code].Count -ge 2) {
            $kl = $klineMap[$code]
            $chg = if ([double]$kl[-1][2] -ne 0) { [Math]::Round(([double]$kl[-1][2] - [double]$kl[-2][2]) / [double]$kl[-2][2] * 100, 2) } else { $null }
            if ($chg -ne $null) { $supObj[$code] = $chg }
        }
    }
    if ($supObj.Count -gt 0) {
        # Merge with existing cache, save to file only
        $merged = @{}
        foreach ($k in $prevChangeMap.Keys) { $merged[$k] = $prevChangeMap[$k] }
        foreach ($k in $supObj.Keys) { $merged[$k] = $supObj[$k] }
        $saveJson = $merged | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($CacheFile, $saveJson, [System.Text.UTF8Encoding]::new($false))
        Write-Output "Supplemented cache: $($supObj.Count) stocks from K-line"
    }
} catch { Write-Warning "Cache supplement failed: $($_.Exception.Message)" }

# ============ 4. Process ============
Write-Output "Processing announcements..."
$processed = [System.Collections.ArrayList]::new()
$seen = @{}
foreach ($ann in $allAnn) {
    $code = $ann.secCode; $title = $ann.announcementTitle; $name = $ann.secName
    $timeMs = $ann.announcementTime; $aid = $ann.announcementId
    if ($seen.ContainsKey($aid)) { continue }; $seen[$aid] = $true
    if ($code -notmatch '^\d{6}$') { continue }
    $dtStr = if ($timeMs) { (Get-Date "1970-01-01 00:00:00").AddMilliseconds([long]$timeMs).ToString('HH:mm:ss') } else {'--'}
    $pi = $stockPop[$code]
    $ps = if ($pi) {$pi.Score}else{10}; $mcap = if ($pi){$pi.Mcap}else{0}
    # Get ChangePct from stockPop first, then K-line as fallback
    $cp = if ($pi) { $pi.ChangePct } else { $null }
    if ($cp -eq $null -and $klineMap.ContainsKey($code) -and $klineMap[$code].Count -ge 2) {
        $kl = $klineMap[$code]
        $c1 = [double]$kl[-1][2]; $c0 = [double]$kl[-2][2]
        if ($c0 -ne 0) { $cp = [Math]::Round(($c1 - $c0) / $c0 * 100, 2) }
    }
    $prevCp = $null
    if ($prevChangeMap.ContainsKey($code)) { $prevCp = $prevChangeMap[$code] }
    elseif ($klineMap.ContainsKey($code) -and $klineMap[$code].Count -ge 3) {
        $kl = $klineMap[$code]
        $pc = [double]$kl[-2][2]
        $ppc = [double]$kl[-3][2]
        if ($ppc -ne 0) { $prevCp = [Math]::Round(($pc - $ppc) / $ppc * 100, 2) }
    }
    $cat = Get-Category -T $title
    $catScore = $cat.P; $summary = $cat.S; $catLabel = Get-CategoryLabel -P $catScore
    $totalScore = [Math]::Round($ps*0.4 + $catScore*0.6, 0)
    $board = if ($code -match '^60') {"沪市主板"} elseif ($code -match '^00' -or $code -match '^001') {"深市主板"} elseif ($code -match '^002' -or $code -match '^003') {"中小板"} elseif ($code -match '^300' -or $code -match '^301') {"创业板"} elseif ($code -match '^688') {"科创板"} else {"其他"}
    # Sentiment & correlation analysis
    $sentimentVal = Get-Sentiment -Title $title
    $sentimentLabel = if ($sentimentVal -eq 1) {"利好"} elseif ($sentimentVal -eq -1) {"利空"} else {"中性"}
    $corrScore = $null; $corrLabel = "-"
    if ($prevCp -ne $null -and $prevCp -ne 0) {
        $absChg = [Math]::Abs($prevCp)
        if ($sentimentVal -eq 1 -and $prevCp -gt 0) { $corrScore = [Math]::Min(100, [Math]::Round(80 + $absChg * 2)); $corrLabel = "利好兑现" }
        elseif ($sentimentVal -eq -1 -and $prevCp -lt 0) { $corrScore = [Math]::Min(100, [Math]::Round(80 + $absChg * 2)); $corrLabel = "利空释放" }
        elseif ($sentimentVal -eq 1 -and $prevCp -lt 0) { $corrScore = [Math]::Max(10, [Math]::Round(50 - $absChg * 3)); $corrLabel = "走势背离" }
        elseif ($sentimentVal -eq -1 -and $prevCp -gt 0) { $corrScore = [Math]::Max(10, [Math]::Round(50 - $absChg * 3)); $corrLabel = "走势背离" }
        else { $corrScore = 50; $corrLabel = "中性" }
    }
    $trendLbls = if ($klineMap.ContainsKey($code)) { Get-TrendPosition -Kline $klineMap[$code] } else { @() }
    $null = $processed.Add([PSCustomObject]@{Score=$totalScore; Code=$code; Name=$name; Title=$title; Category=$catLabel; Time=$dtStr; Board=$board; Mcap=$mcap; ChangePct=$cp; PrevChangePct=$prevCp; Summary=$summary; Sentiment=$sentimentLabel; CorrScore=$corrScore; CorrLabel=$corrLabel; TrendLabels=$trendLbls; Url="http://www.cninfo.com.cn/new/disclosure/detail?announcementId=$aid"})
}
$sorted = $processed | Sort-Object Score -Descending
$totalBefore = $sorted.Count
# Filter: only show stocks that meet at least one trend position criterion
$sorted = $sorted | Where-Object { $_.TrendLabels -and $_.TrendLabels.Count -gt 0 }
Write-Output "Processed: $($sorted.Count) announcements (filtered from $totalBefore)"

# ============ 5. Generate HTML ============
Write-Output "Generating HTML..."
$itemsHtml = ""; $i=1
foreach ($item in $sorted) {
    $cc = if ($item.Score -ge 80){'high'}elseif($item.Score -ge 60){'medium'}else{'normal'}
    $chv = 999
    $cpNow = $item.ChangePct
    $ch = if ($cpNow -ne $null){$c='';$chv=[Math]::Round($cpNow,1);if($cpNow-gt0){$c='up'}elseif($cpNow-lt0){$c='down'};"<span class='change $c'>$chv%</span>"}else{''}
    $ms = if($item.Mcap-gt0){"{0:N0}" -f [Math]::Round($item.Mcap/1e8)+"亿"}else{''}
    $se = $item.Summary -replace '"','&quot;'
    # Correlation cell HTML
    $st = $item.Sentiment
    if ($st -eq "利好") { $stTag = "<span class='sentiment positive'>利好</span>" }
    elseif ($st -eq "利空") { $stTag = "<span class='sentiment negative'>利空</span>" }
    else { $stTag = "<span class='sentiment neutral'>中性</span>" }
    if ($item.CorrScore -ne $null) {
        $cs = $item.CorrScore; $cl = $item.CorrLabel
        $corrClass = if ($cs -ge 70) {"high"} elseif ($cs -ge 45) {"medium"} else {"low"}
        $sentimentHtml = "$stTag<div class='corr-info'><span class='corr-score $corrClass'>$cs</span><span class='corr-label'>$cl</span></div>"
    } else {
        $sentimentHtml = "$stTag<div class='corr-info'><span class='corr-na'>-</span></div>"
    }
    $dcorr = if ($item.CorrScore -ne $null) { $item.CorrScore } else { 0 }
    # Trend position cell
    $trendHtml = ""
    $trendScore = 0
    if ($item.TrendLabels -and $item.TrendLabels.Count -gt 0) {
        foreach ($tl in $item.TrendLabels) {
            if ($tl -eq "趋势增强") { $tc = "trend-strong"; $tn = "趋势增强"; if ($trendScore -lt 3) { $trendScore = 3 } }
            elseif ($tl -eq "趋势维持") { $tc = "trend-hold"; $tn = "趋势维持"; if ($trendScore -lt 2) { $trendScore = 2 } }
            elseif ($tl -eq "突发量变") { $tc = "trend-surge"; $tn = "突发量变"; if ($trendScore -lt 1) { $trendScore = 1 } }
            else { $tc = ""; $tn = $tl }
            if ($tc) { $trendHtml += "<span class='trend-tag $tc'>$tn</span>" }
        }
    }
    if (-not $trendHtml) { $trendHtml = "<span class='trend-na'>-</span>" }
    # K-line OHLC data for mini K-line chart (last 20 days)
    $klineData = if ($klineMap.ContainsKey($item.Code) -and $klineMap[$item.Code].Count -ge 20) { ($klineMap[$item.Code][-20..-1] | ForEach-Object { $o=[Math]::Round([double]$_[1],2); $h=[Math]::Round([double]$_[3],2); $l=[Math]::Round([double]$_[4],2); $c=[Math]::Round([double]$_[2],2); "$o,$h,$l,$c" }) -join '|' } else { '' }
    # EastMoney URL for stock code link
    $emPrefix = if ($item.Code -match '^(60|688)') {'sh'} else {'sz'}
    $emUrl = "https://quote.eastmoney.com/$emPrefix$($item.Code).html#fullScreenChart"
    $itemsHtml += @"
    <tr class="$cc" data-change="$chv" data-corr="$dcorr" data-trend="$trendScore" data-kline="$klineData"><td class="rank">$i</td><td class="code"><a href="$emUrl" target="_blank" title="点击查看K线图">$($item.Code)</a></td><td class="name" data-code="$($item.Code)">$($item.Name)</td><td class="board">$($item.Board)</td><td class="title-col" title="$se"><a href="$($item.Url)" target="_blank" title="$se">$($item.Title)</a></td><td class="cat"><span class="cat-tag $cc">$($item.Category)</span></td><td class="score">$($item.Score)</td><td class="mcap">$ms</td><td class="change-cell">$ch</td><td class="corr-cell">$sentimentHtml</td><td class="trend-cell">$trendHtml</td><td class="time">$($item.Time)</td></tr>
"@
    $i++
}

$total1 = $sorted.Count; $gt = Get-Date -Format 'HH:mm'
$html = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>A股公告热门排行 | $Date</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;background:#f0f2f5;color:#333;min-height:100vh}
.header{background:linear-gradient(135deg,#1a1a2e,#16213e 50%,#0f3460);color:#fff;padding:24px 32px;text-align:center;box-shadow:0 2px 12px rgba(0,0,0,.15)}
.header h1{font-size:24px;font-weight:700;letter-spacing:2px}
.header .subtitle{font-size:13px;opacity:.8;margin-top:6px}
.header .stats{margin-top:10px;font-size:13px;opacity:.9}
.container{max-width:1400px;margin:16px auto;padding:0 16px}
.controls{display:flex;align-items:center;gap:12px;margin-bottom:12px;flex-wrap:wrap}
.controls label{font-size:13px;color:#666}
.search-box{padding:8px 14px;border:1px solid #d9d9d9;border-radius:6px;font-size:13px;width:220px;outline:none}
.search-box:focus{border-color:#0f3460;box-shadow:0 0 0 2px rgba(15,52,96,.12)}
.filter-select{padding:8px 14px;border:1px solid #d9d9d9;border-radius:6px;font-size:13px;outline:none;cursor:pointer}
.btn-sort{padding:6px 14px;background:#fff;border:1px solid #0f3460;border-radius:6px;font-size:13px;color:#0f3460;cursor:pointer;transition:all .2s;white-space:nowrap}
.btn-sort:hover{background:#0f3460;color:#fff}
.btn-sort.active{background:#0f3460;color:#fff}
.table-wrapper{background:#fff;border-radius:10px;box-shadow:0 1px 6px rgba(0,0,0,.08);overflow:hidden}
table{width:100%;border-collapse:collapse;font-size:13px}
thead{background:#fafafa;border-bottom:2px solid #e8e8e8}
th{padding:12px 14px;text-align:left;font-weight:600;color:#555;font-size:12px;letter-spacing:.5px;white-space:nowrap;user-select:none}
th.sortable{cursor:pointer}
th.sortable:hover{color:#0f3460}
th.sortable::after{content:' \2195';opacity:.3;font-size:11px}
th.sortable.asc::after{content:' \2191';opacity:1;color:#0f3460}
th.sortable.desc::after{content:' \2193';opacity:1;color:#0f3460}
td{padding:10px 14px;border-bottom:1px solid #f0f0f0;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover{background:#f7f9fc}
.rank{font-weight:700;color:#888;width:40px;text-align:center}
tr.high .rank{color:#e74c3c}
tr.medium .rank{color:#e67e22}
.code{font-family:'SF Mono','Consolas',monospace;color:#555;font-weight:500}
.code a{color:#555;text-decoration:none;cursor:pointer}
.code a:hover{color:#0f3460;text-decoration:underline}
.name{font-weight:600;cursor:pointer;position:relative}
.name:hover{color:#0f3460}
.kline-tip{position:fixed;z-index:9999;background:#fff;border:1px solid #d9d9d9;border-radius:6px;box-shadow:0 4px 16px rgba(0,0,0,.12);padding:10px 14px 8px;pointer-events:none;display:none;min-width:220px}
.kline-tip .tip-title{font-size:11px;color:#999;margin-bottom:4px;text-align:center}
.kline-tip svg{display:block}
.kline-tip .tip-stats{display:flex;justify-content:space-between;font-size:10px;color:#999;margin-top:4px}
.board{font-size:12px;color:#999}
.title-col{max-width:420px}
.title-col a{color:#333;text-decoration:none;display:-webkit-box;-webkit-line-clamp:1;-webkit-box-orient:vertical;overflow:hidden}
.title-col a:hover{color:#0f3460;text-decoration:underline}
.cat-tag{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:500;white-space:nowrap}
.cat-tag.high{background:#fde8e8;color:#c0392b}
.cat-tag.medium{background:#fef3e2;color:#d35400}
.cat-tag.normal{background:#f0f0f0;color:#666}
.score{font-weight:700;font-family:'SF Mono','Consolas',monospace;font-size:14px}
tr.high .score{color:#e74c3c}
tr.medium .score{color:#e67e22}
tr.normal .score{color:#999}
.mcap{font-family:'SF Mono','Consolas',monospace;color:#666;font-size:12px}
.change{font-weight:500;font-family:'SF Mono','Consolas',monospace;font-size:12px}
.change.up{color:#e74c3c}
.change.down{color:#27ae60}
.time{font-family:'SF Mono','Consolas',monospace;color:#999;font-size:12px}
.corr-cell{text-align:center;min-width:72px}
.sentiment{display:inline-block;padding:1px 7px;border-radius:3px;font-size:11px;font-weight:600;letter-spacing:.5px}
.sentiment.positive{background:#e8f5e9;color:#2e7d32}
.sentiment.negative{background:#fde8e8;color:#c62828}
.sentiment.neutral{background:#f5f5f5;color:#999}
.corr-info{margin-top:3px;display:flex;align-items:center;justify-content:center;gap:4px}
.corr-score{font-family:'SF Mono','Consolas',monospace;font-size:12px;font-weight:700}
.corr-score.high{color:#2e7d32}
.corr-score.medium{color:#f57f17}
.corr-score.low{color:#c62828}
.corr-label{font-size:10px;color:#999;white-space:nowrap}
.corr-na{color:#ccc;font-size:11px}
.trend-cell{text-align:center;min-width:80px}
.trend-tag{display:inline-block;padding:1px 6px;border-radius:3px;font-size:10px;font-weight:600;margin:1px 0}
.trend-tag.trend-strong{background:#e8f5e9;color:#1b5e20;border:1px solid #a5d6a7}
.trend-tag.trend-hold{background:#e3f2fd;color:#1565c0;border:1px solid #90caf9}
.trend-tag.trend-surge{background:#fff3e0;color:#e65100;border:1px solid #ffcc80}
.trend-na{color:#ccc;font-size:11px}
.footer{text-align:center;padding:20px;color:#bbb;font-size:12px}
@media(max-width:768px){.container{padding:0 8px}th,td{padding:8px 6px;font-size:12px}.header h1{font-size:18px}.board,.mcap,.change-cell{display:none}.title-col{max-width:200px}}
</style>
</head>
<body>
<div class="header"><h1>A股公告热门排行（趋势精选）</h1><div class="subtitle">$Date | 仅显示符合趋势位置评估标准的股票公告</div><div class="stats">共 $total1 条公告 更新时间 $gt | 涨跌幅数据为最新交易日</div></div>
<div class="container">
<div class="controls">
<label>搜索:</label><input type="text" class="search-box" id="searchBox" placeholder="股票代码/名称/标题..." oninput="filterTable()">
<label>分类:</label><select class="filter-select" id="catFilter" onchange="filterTable()"><option value="">全部分类</option><option>业绩预告</option><option>分红送转</option><option>并购重组</option><option>定期报告</option><option>股东变动</option><option>重大事项</option><option>公司治理</option><option>其他</option></select>
<label>板块:</label><select class="filter-select" id="boardFilter" onchange="filterTable()"><option value="">全部板块</option><option>沪市主板</option><option>深市主板</option><option>中小板</option><option>创业板</option><option>科创板</option></select>
<button class="btn-sort" onclick="sortTable('change')" id="sortChangeBtn">按最新涨跌幅排序</button>
<button class="btn-sort" onclick="exportTxt()" id="exportBtn">导出列表</button>
<button class="btn-sort" onclick="refreshPage()" id="refreshBtn" style="display:none">⟳ 手动刷新</button>
</div>
<div class="table-wrapper"><table><thead><tr><th style="width:40px">#</th><th class="sortable" data-col="code" onclick="sortTable('code')">代码</th><th class="sortable" data-col="name" onclick="sortTable('name')">名称</th><th class="sortable" data-col="board" onclick="sortTable('board')">板块</th><th class="sortable" data-col="title" onclick="sortTable('title')">公告标题</th><th class="sortable" data-col="cat" onclick="sortTable('cat')">分类</th><th class="sortable asc" data-col="score" onclick="sortTable('score')">热度</th><th>市值</th><th class="sortable" data-col="change" onclick="sortTable('change')">最新涨跌幅</th><th class="sortable" data-col="corr" onclick="sortTable('corr')">关联分析</th><th class="sortable" data-col="trend" onclick="sortTable('trend')">趋势位置</th><th class="sortable" data-col="time" onclick="sortTable('time')">时间</th></tr></thead>
<tbody id="tableBody">$itemsHtml</tbody>
</table></div>
<div class="footer">数据来源：巨潮资讯网(CNINFO) 每个工作日9:00更新 | 悬停名称看K线简图，点击代码看详细K线</div>
</div>
<div id="klineTip" class="kline-tip"><div class="tip-title">最近20日K线</div><svg id="klineSvg" width="200" height="60"></svg><div class="tip-stats"><span id="tipHigh">-</span><span id="tipLow">-</span></div></div>
<script>
function filterTable(){var q=document.getElementById('searchBox').value.toLowerCase(),cf=document.getElementById('catFilter').value,bf=document.getElementById('boardFilter').value,rows=document.querySelectorAll('#tableBody tr');rows.forEach(function(r){var c=r.cells[1]?.textContent.toLowerCase()||'',n=r.cells[2]?.textContent.toLowerCase()||'',t=r.cells[4]?.textContent.toLowerCase()||'',ct=r.cells[5]?.textContent.trim()||'',b=r.cells[3]?.textContent||'';r.style.display=(!q||c.includes(q)||n.includes(q)||t.includes(q))&&(!cf||ct===cf)&&(!bf||b===bf)?'':'none'})}
var sortState={col:'score',dir:'desc'};
function sortTable(col){var ths=document.querySelectorAll('th.sortable');ths.forEach(function(t){t.classList.remove('asc','desc')});var th=document.querySelector('th[data-col="'+col+'"]');if(sortState.col===col){sortState.dir=sortState.dir==='asc'?'desc':'asc'}else{sortState.col=col;sortState.dir='desc'}th.classList.add(sortState.dir);var tbody=document.getElementById('tableBody'),rows=Array.from(tbody.querySelectorAll('tr'));rows.sort(function(a,b){var va,vb;if(col==='score'||col==='rank'){va=parseInt(a.cells[0]?.textContent)||0;vb=parseInt(b.cells[0]?.textContent)||0;if(col==='score'){va=parseInt(a.cells[6]?.textContent)||0;vb=parseInt(b.cells[6]?.textContent)||0}return sortState.dir==='asc'?va-vb:vb-va}if(col==='change'){va=parseFloat(a.getAttribute('data-change'))||0;vb=parseFloat(b.getAttribute('data-change'))||0;return sortState.dir==='asc'?va-vb:vb-va}if(col==='corr'){va=parseFloat(a.getAttribute('data-corr'))||0;vb=parseFloat(b.getAttribute('data-corr'))||0;return sortState.dir==='asc'?va-vb:vb-va}if(col==='trend'){va=parseInt(a.getAttribute('data-trend'))||0;vb=parseInt(b.getAttribute('data-trend'))||0;return sortState.dir==='asc'?vb-va:va-vb}if(col==='code'){va=a.cells[1]?.textContent||'';vb=b.cells[1]?.textContent||''}else if(col==='name'){va=a.cells[2]?.textContent||'';vb=b.cells[2]?.textContent||''}else if(col==='board'){va=a.cells[3]?.textContent||'';vb=b.cells[3]?.textContent||''}else if(col==='title'){va=a.cells[4]?.textContent||'';vb=b.cells[4]?.textContent||''}else if(col==='cat'){va=a.cells[5]?.textContent||'';vb=b.cells[5]?.textContent||''}else if(col==='time'){va=a.cells[11]?.textContent||'';vb=b.cells[11]?.textContent||''}va=String(va);vb=String(vb);var cmp=va.localeCompare(vb,'zh-CN');return sortState.dir==='asc'?cmp:-cmp});rows.forEach(function(row,idx){row.cells[0].textContent=idx+1;tbody.appendChild(row)})}
// K-line mini chart tooltip
var tip=document.getElementById('klineTip'),svg=document.getElementById('klineSvg');
document.getElementById('tableBody').addEventListener('mouseover',function(e){
  var td=e.target.closest('td.name');if(!td)return hideTip();
  var tr=td.closest('tr'),kd=tr.getAttribute('data-kline');if(!kd)return hideTip();
  var bars=kd.split('|').map(function(s){var p=s.split(',');return{o:+p[0],h:+p[1],l:+p[2],c:+p[3]}});
  if(bars.length<2)return hideTip();
  var allP=[],i;for(i=0;i<bars.length;i++){allP.push(bars[i].h,bars[i].l)}
  var min=Math.min.apply(null,allP),max=Math.max.apply(null,allP),range=max-min||1;
  var w=200,h=60,pt=4,pb=4,pl=2,pr=2,bw=(w-pl-pr)/bars.length,hw=Math.max(1,bw*0.6);
  var scaleY=function(v){return pt+(1-(v-min)/range)*(h-pt-pb)};
  var bodyW=Math.max(1,Math.min(hw-2,bw*0.8));
  var html='';
  for(i=0;i<bars.length;i++){
    var b=bars[i],x=pl+i*bw+ (bw-hw)/2, cx=x+hw/2;
    var yHigh=scaleY(b.h),yLow=scaleY(b.l),yOpen=scaleY(b.o),yClose=scaleY(b.c);
    var isUp=b.c>=b.o;
    html+='<line x1="'+cx+'" y1="'+yHigh+'" x2="'+cx+'" y2="'+yLow+'" stroke="#333" stroke-width="1"/>';
    var topY=Math.min(yOpen,yClose),botY=Math.max(yOpen,yClose);
    if(isUp){html+='<rect x="'+(cx-bodyW/2)+'" y="'+topY+'" width="'+bodyW+'" height="'+(botY-topY||1)+'" fill="#fff" stroke="#333" stroke-width="0.8"/>'}
    else{html+='<rect x="'+(cx-bodyW/2)+'" y="'+topY+'" width="'+bodyW+'" height="'+(botY-topY||1)+'" fill="#000"/>'}
  }
  svg.setAttribute('viewBox','0 0 '+w+' '+h);
  svg.innerHTML=html;
  document.getElementById('tipHigh').textContent='最高:'+max.toFixed(2);
  document.getElementById('tipLow').textContent='最低:'+min.toFixed(2)+' | 最近:'+bars[bars.length-1].c.toFixed(2);
  tip.style.display='block';tip.style.left=(e.clientX+12)+'px';tip.style.top=(e.clientY-30)+'px';
  if(parseInt(tip.style.left)+220>window.innerWidth)tip.style.left=(e.clientX-220)+'px';
});
function hideTip(){tip.style.display='none'}
document.getElementById('tableBody').addEventListener('mouseout',function(e){if(!e.target.closest('td.name'))hideTip()});
// Export visible stock codes to txt
function exportTxt(){var d=new Date(),ymd=d.getFullYear()*10000+(d.getMonth()+1)*100+d.getDate(),hh=('0'+d.getHours()).slice(-2),fn=ymd+hh+'.txt';var rows=document.querySelectorAll('#tableBody tr');if(!rows.length)return alert('无数据可导出');var codes=[];rows.forEach(function(r){if(r.style.display!=='none'){var c=r.cells[1]?.textContent;if(c)codes.push(c)}});if(!codes.length)return alert('无数据可导出');var blob=new Blob([codes.join('\r\n')],{type:'text/plain;charset=utf-8'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=fn;a.click();URL.revokeObjectURL(a.href)}
// Manual refresh — trigger GitHub Actions then reload
function refreshPage(){var btn=document.getElementById('refreshBtn');btn.textContent='⏳ 刷新中...';btn.disabled=true;window.open('https://github.com/topholder2022/ashare-monitor/actions/workflows/daily-deploy.yml','_blank');window.location.href=window.location.pathname+'?_='+Date.now()}
</script>
</body>
</html>
"@

$html | Out-File -FilePath $OutputFile -Encoding utf8
Write-Output "Generated: $OutputFile"
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
if ($Date -eq (Get-Date -Format 'yyyy-MM-dd')) { Start-Process $OutputFile }
Write-Output "Done!"
