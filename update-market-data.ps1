<#
  update-market-data.ps1
  Fetches verified market data from public APIs and writes market-cache.js
  next to the dashboard, so the trading journal shows a daily snapshot even
  when opened offline (and so indices, which browsers block via CORS, work).

  Run by Windows Task Scheduler each morning. Sources are server-side here,
  so there is no CORS restriction.
#>

$ErrorActionPreference = 'Stop'
$dir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$cachePath = Join-Path $dir 'market-cache.js'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Try-Step($name, $block) {
  try { & $block }
  catch { Write-Host ("[skip] {0}: {1}" -f $name, $_.Exception.Message); $null }
}

# ===== Macro Desk regime engine (computed from real OHLC — Yahoo Finance) =====
$YH = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
function YFetch($sym, $interval, $range) {
  $u = "https://query1.finance.yahoo.com/v8/finance/chart/$([uri]::EscapeDataString($sym))?interval=$interval&range=$range"
  $res = (Invoke-RestMethod $u -Headers $YH -TimeoutSec 25).chart.result[0]
  $q = $res.indicators.quote[0]; $bars = @()
  for ($i = 0; $i -lt $res.timestamp.Count; $i++) {
    if ($null -ne $q.close[$i] -and $null -ne $q.open[$i]) {
      $bars += [pscustomobject]@{ o=[double]$q.open[$i]; h=[double]$q.high[$i]; l=[double]$q.low[$i]; c=[double]$q.close[$i]; v=[double]$(if ($q.volume) { $q.volume[$i] } else { 0 }) }
    }
  }
  ,$bars
}
function Agg($bars, $g) {
  $out = @()
  for ($i = 0; $i -lt $bars.Count; $i += $g) {
    $end = [math]::Min($i + $g - 1, $bars.Count - 1); $sl = @($bars[$i..$end])
    $out += [pscustomobject]@{ o=$sl[0].o; h=($sl.h | Measure-Object -Maximum).Maximum; l=($sl.l | Measure-Object -Minimum).Minimum; c=$sl[-1].c; v=($sl.v | Measure-Object -Sum).Sum }
  }
  ,$out
}
function EmaLast($vals, $p) { $k = 2/($p+1); $e = $vals[0]; foreach ($v in $vals) { $e = $v*$k + $e*(1-$k) }; $e }
function EffRatio($c, $k) {
  if ($c.Count -le $k) { $k = $c.Count - 1 }; if ($k -le 0) { return 0 }
  $chg = [math]::Abs($c[-1] - $c[-1-$k]); $vol = 0.0
  for ($i = $c.Count - $k; $i -lt $c.Count; $i++) { $vol += [math]::Abs($c[$i] - $c[$i-1]) }
  if ($vol -eq 0) { 0 } else { $chg / $vol }
}
function TFRegime($bars) {
  if ($bars.Count -lt 12) { return $null }
  $c = @($bars | ForEach-Object { $_.c }); $last = $c[-1]
  $e20 = EmaLast $c ([math]::Min(20, $c.Count-1)); $e50 = EmaLast $c ([math]::Min(50, $c.Count-1))
  $er = EffRatio $c ([math]::Min(20, $c.Count-1)); $dir = 0
  if ($last -gt $e20 -and $e20 -ge $e50) { $dir = 1 }
  elseif ($last -lt $e20 -and $e20 -le $e50) { $dir = -1 }
  else { $dir = [math]::Sign($c[-1] - $c[[math]::Max(0, $c.Count-5)]) }
  $bear = if ($dir -gt 0) { 'UP' } elseif ($dir -lt 0) { 'DOWN' } else { 'FLAT' }
  $qual = if ($er -ge 0.5) { 'CLEAN' } elseif ($er -ge 0.3) { 'DEVELOPING' } else { 'CHOPPY' }
  [ordered]@{ dir=$dir; bearing=$bear; er=[math]::Round($er,2); label="$qual $bear"; tradable=($er -ge 0.35) }
}
function FlowState($bars) {
  $useVol = (@($bars | Where-Object { $_.v -gt 0 }).Count) -gt ($bars.Count/2)
  $vals = if ($useVol) { @($bars | ForEach-Object { $_.v }) } else { @($bars | ForEach-Object { $_.h - $_.l }) }
  if ($vals.Count -lt 8) { return [ordered]@{ state='HEALTHY'; ratio=1; metric='n/a' } }
  $recent = ($vals[($vals.Count-6)..($vals.Count-1)] | Measure-Object -Average).Average
  $avg = ($vals | Measure-Object -Average).Average
  $ratio = if ($avg -eq 0) { 1 } else { $recent / $avg }
  $state = if ($ratio -lt 0.7) { 'THIN' } elseif ($ratio -le 1.5) { 'HEALTHY' } else { 'CROWDED' }
  [ordered]@{ state=$state; ratio=[math]::Round($ratio,2); metric=$(if ($useVol) { 'volume' } else { 'range' }) }
}

$cache = [ordered]@{ updated = (Get-Date).ToString('o') }

# ---- Crypto prices (CoinGecko) ----
$cache.prices = Try-Step 'prices' {
  Invoke-RestMethod 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,solana,binancecoin&vs_currencies=usd&include_24hr_change=true'
}

# ---- Global crypto market (CoinGecko) ----
$cache.global = Try-Step 'global' {
  $g = (Invoke-RestMethod 'https://api.coingecko.com/api/v3/global').data
  [ordered]@{
    mc   = [double]$g.total_market_cap.usd
    ch   = [double]$g.market_cap_change_percentage_24h_usd
    btcD = [double]$g.market_cap_percentage.btc
    ethD = [double]$g.market_cap_percentage.eth
  }
}

# ---- Fear & Greed (Alternative.me) ----
$cache.feargreed = Try-Step 'feargreed' {
  $f = (Invoke-RestMethod 'https://api.alternative.me/fng/?limit=1').data[0]
  [ordered]@{ value = $f.value; cls = $f.value_classification }
}

# ---- Retail vs Fund positioning (OKX rubik) ----
# retail = all-account long/short ratio; fund = top-trader long/short ratio by position size.
$cache.longshort = Try-Step 'longshort' {
  function Get-Positioning($ccy, $inst) {
    $acc = Invoke-RestMethod "https://www.okx.com/api/v5/rubik/stat/contracts/long-short-account-ratio?ccy=$ccy&period=1H"
    $top = Invoke-RestMethod "https://www.okx.com/api/v5/rubik/stat/contracts/long-short-position-ratio-contract-top-trader?instId=$inst&period=1H"
    $ra = [double]$acc.data[0][1]; $tp = [double]$top.data[0][1]   # ratio = long/short
    $rl = $ra/(1+$ra)*100;        $tl = $tp/(1+$tp)*100
    [ordered]@{
      retail = [ordered]@{ long = [math]::Round($rl,1); short = [math]::Round(100-$rl,1) }
      top    = [ordered]@{ long = [math]::Round($tl,1); short = [math]::Round(100-$tl,1) }
    }
  }
  [ordered]@{ BTCUSDT = (Get-Positioning 'BTC' 'BTC-USDT-SWAP'); ETHUSDT = (Get-Positioning 'ETH' 'ETH-USDT-SWAP') }
}

# ---- Long/short positioning heatmap across top coins (OKX) ----
$cache.lsheatmap = Try-Step 'lsheatmap' {
  $coins = @(
    @{c='BTC';i='BTC-USDT-SWAP'},@{c='ETH';i='ETH-USDT-SWAP'},@{c='SOL';i='SOL-USDT-SWAP'},@{c='XRP';i='XRP-USDT-SWAP'},
    @{c='DOGE';i='DOGE-USDT-SWAP'},@{c='BNB';i='BNB-USDT-SWAP'},@{c='ADA';i='ADA-USDT-SWAP'},@{c='AVAX';i='AVAX-USDT-SWAP'}
  )
  $out = @()
  foreach ($x in $coins) {
    for ($try=0; $try -lt 2; $try++) {
      try {
        $acc = Invoke-RestMethod "https://www.okx.com/api/v5/rubik/stat/contracts/long-short-account-ratio?ccy=$($x.c)&period=1H"
        Start-Sleep -Milliseconds 250
        $top = Invoke-RestMethod "https://www.okx.com/api/v5/rubik/stat/contracts/long-short-position-ratio-contract-top-trader?instId=$($x.i)&period=1H"
        $ra = [double]$acc.data[0][1]; $tp = [double]$top.data[0][1]
        $out += [ordered]@{ coin=$x.c; retail=[math]::Round($ra/(1+$ra)*100,1); top=[math]::Round($tp/(1+$tp)*100,1) }
        break
      } catch { Start-Sleep -Milliseconds 600 }
    }
    Start-Sleep -Milliseconds 250
  }
  $out
}

# ---- Forex (Frankfurter / ECB): latest vs previous business day ----
$cache.forex = Try-Step 'forex' {
  $lat  = Invoke-RestMethod 'https://api.frankfurter.app/latest?from=USD&to=EUR,GBP,JPY,AUD,CAD'
  $pday = ([datetime]::Parse($lat.date)).AddDays(-1).ToString('yyyy-MM-dd')
  $prv  = Invoke-RestMethod "https://api.frankfurter.app/$pday`?from=USD&to=EUR,GBP,JPY,AUD,CAD"
  $last = $lat.rates; $prev = $prv.rates
  function PairInv($c, $name, $dec) { $rate=1/$last.$c; $ch=($rate/(1/$prev.$c)-1)*100; [ordered]@{ pair=$name; rate=("{0:N$dec}" -f $rate); change=[math]::Round($ch,2) } }
  function PairDir($c, $name, $dec) { $rate=$last.$c;   $ch=($rate/$prev.$c-1)*100;     [ordered]@{ pair=$name; rate=("{0:N$dec}" -f $rate); change=[math]::Round($ch,2) } }
  @( (PairInv 'EUR' 'EUR/USD' 4), (PairInv 'GBP' 'GBP/USD' 4), (PairDir 'JPY' 'USD/JPY' 2),
     (PairInv 'AUD' 'AUD/USD' 4), (PairDir 'CAD' 'USD/CAD' 4) )
}

# ---- Indices & commodities (Stooq daily history -> prev-close change) ----
$cache.indices = Try-Step 'indices' {
  $syms = @(
    @{ s='^spx';   n='S&P 500' },
    @{ s='^ndx';   n='Nasdaq 100' },
    @{ s='^dji';   n='Dow Jones' },
    @{ s='xauusd'; n='Gold (XAU)' },
    @{ s='cl.f';   n='WTI Crude' }
  )
  $d1 = (Get-Date).AddDays(-12).ToString('yyyyMMdd')
  $d2 = (Get-Date).ToString('yyyyMMdd')
  $out = @()
  foreach ($x in $syms) {
    try {
      $csv = (Invoke-WebRequest "https://stooq.com/q/d/l/?s=$($x.s)&i=d&d1=$d1&d2=$d2" -UseBasicParsing).Content
      $rows = $csv.Trim() -split "`n" | Select-Object -Skip 1
      if ($rows.Count -ge 2) {
        $last = ($rows[-1] -split ',')[4] -as [double]
        $prev = ($rows[-2] -split ',')[4] -as [double]
        $ch = if ($prev) { [math]::Round(($last-$prev)/$prev*100,2) } else { $null }
        $out += [ordered]@{ name=$x.n; price=$last; change=$ch }
      }
    } catch { }
  }
  $out
}

# ---- Crypto news (RSS, no API key required) ----
$cache.news = Try-Step 'news' {
  $items = @()
  foreach ($feed in @('https://cointelegraph.com/rss','https://decrypt.co/feed','https://bitcoinmagazine.com/feed')) {
    try {
      $xml = [xml](Invoke-WebRequest $feed -UseBasicParsing).Content
      $src = ([string]$xml.rss.channel.title) -replace '\s*\|.*$',''
      foreach ($it in ($xml.rss.channel.item | Select-Object -First 4)) {
        $ts = try { [DateTimeOffset]::Parse([string]$it.pubDate).ToUnixTimeSeconds() } catch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        $title = if ($it.title.'#cdata-section') { [string]$it.title.'#cdata-section' } else { [string]$it.title }
        $items += [ordered]@{ title=$title; url=[string]$it.link; source=$src; published_on=$ts }
      }
    } catch { }
  }
  $items | Sort-Object { $_.published_on } -Descending | Select-Object -First 8
}

# ---- MACRO DESK: multi-timeframe regime, bearing & flow computed from price action ----
$cache.macrodesk = Try-Step 'macrodesk' {
  $assets = @(
    @{ n='XAU/USD'; y='GC=F' }, @{ n='DXY'; y='DX-Y.NYB' }, @{ n='BTC/USD'; y='BTC-USD' },
    @{ n='ETH/USD'; y='ETH-USD' }, @{ n='SPX 500'; y='^GSPC' }, @{ n='EUR/USD'; y='EURUSD=X' }
  )
  $out = @()
  foreach ($a in $assets) {
    try {
      $m15 = YFetch $a.y '15m' '5d'; Start-Sleep -Milliseconds 200
      $d1  = YFetch $a.y '1d'  '6mo'
      if ($m15.Count -lt 40 -or $d1.Count -lt 30) { continue }
      $b30 = Agg $m15 2; $b1h = Agg $m15 4; $b4h = Agg $m15 16
      $rd = TFRegime $d1
      $tfs = @()
      foreach ($p in @(@('4H',$b4h), @('1H',$b1h), @('30m',$b30), @('15m',$m15))) {
        $rr = TFRegime $p[1]; if ($null -eq $rr) { continue }
        $tfs += [ordered]@{ tf=$p[0]; label=$rr.label; aligned=($rr.dir -ne 0 -and $rr.dir -eq $rd.dir); state=$(if ($rr.tradable) { 'tradable' } else { 'quiet' }) }
      }
      # days the daily regime has held (consecutive days same side of daily EMA20)
      $dc = @($d1 | ForEach-Object { $_.c }); $k = 2/21; $e = $dc[0]; $ema = @($e)
      for ($i=1; $i -lt $dc.Count; $i++) { $e = $dc[$i]*$k + $e*(1-$k); $ema += $e }
      $side = [math]::Sign($dc[-1] - $ema[-1]); $days = 0
      for ($i = $dc.Count-1; $i -ge 0; $i--) { if ($side -ne 0 -and [math]::Sign($dc[$i]-$ema[$i]) -eq $side) { $days++ } else { break } }
      $out += [ordered]@{
        sym=$a.n; price=[math]::Round($dc[-1], $(if ($dc[-1] -lt 10) { 4 } else { 2 }))
        chg=[math]::Round(($dc[-1]/$dc[-2]-1)*100, 2); daily=$rd.label; bearing=$rd.bearing
        er=$rd.er; days=$days; tfs=$tfs; flow=(FlowState $b1h)
      }
    } catch { }
    Start-Sleep -Milliseconds 250
  }
  $out
}

# ---- INSTITUTIONAL FEED: free macro/research aggregation (RSS, source-linked) ----
$cache.institutional = Try-Step 'institutional' {
  $feeds = @(
    @{ s='ForexLive'; u='https://www.forexlive.com/feed/' },
    @{ s='FXStreet';  u='https://www.fxstreet.com/rss/news' },
    @{ s='Investing.com'; u='https://www.investing.com/rss/news_1.rss' }
  )
  $kws = @('Gold','Silver','Bitcoin','Crypto','Ethereum','Dollar','USD','Inflation','CPI','Fed','FOMC','Rate','Rates','Oil','Yield','Yields','Bonds','Treasury','ECB','Powell','Jobs','Payrolls','Stocks','Equities','Recession','PCE')
  $items = @()
  foreach ($f in $feeds) {
    try {
      $xml = [xml](Invoke-WebRequest $f.u -UseBasicParsing -Headers $YH -TimeoutSec 20).Content
      foreach ($it in ($xml.rss.channel.item | Select-Object -First 6)) {
        $title = if ($it.title.'#cdata-section') { [string]$it.title.'#cdata-section' } else { [string]$it.title }
        $desc  = if ($it.description.'#cdata-section') { [string]$it.description.'#cdata-section' } else { [string]$it.description }
        $desc  = (($desc -replace '<[^>]+>','') -replace '\s+',' ').Trim()
        if ($desc.Length -gt 260) { $desc = $desc.Substring(0,260) + '...' }
        $ts = try { [DateTimeOffset]::Parse([string]$it.pubDate).ToUnixTimeSeconds() } catch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        $tags = @(); $blob = "$title $desc"
        foreach ($kw in $kws) { if ($blob -match "(?i)\b$kw\b") { $tags += $kw } }
        $items += [ordered]@{ source=$f.s; title=$title; desc=$desc; url=[string]$it.link; published_on=$ts; tags=@($tags | Select-Object -Unique | Select-Object -First 4) }
      }
    } catch { }
  }
  $items | Sort-Object { $_.published_on } -Descending | Select-Object -First 12
}

# ---- Write cache file ----
$json = $cache | ConvertTo-Json -Depth 8 -Compress
"window.__MARKET_CACHE__ = $json;" | Out-File -FilePath $cachePath -Encoding utf8
Write-Host ("Wrote {0} ({1} bytes) at {2}" -f $cachePath, (Get-Item $cachePath).Length, (Get-Date))
