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

# ---- Write cache file ----
$json = $cache | ConvertTo-Json -Depth 8 -Compress
"window.__MARKET_CACHE__ = $json;" | Out-File -FilePath $cachePath -Encoding utf8
Write-Host ("Wrote {0} ({1} bytes) at {2}" -f $cachePath, (Get-Item $cachePath).Length, (Get-Date))
