$ErrorActionPreference = 'Stop'

$work = Join-Path $env:RUNNER_TEMP 'veloroute'
New-Item -ItemType Directory -Force -Path $work | Out-Null

python .github/scripts/extract_script.py app/lib/core/privileged_helper.dart _routeScript |
  Set-Content -LiteralPath (Join-Path $work 'velo-route.ps1') -Encoding UTF8

$script = Join-Path $work 'velo-route.ps1'
$requests = Join-Path $work 'route-request.json'
$result = "$requests.done"

function Fail([string]$why) {
  Write-Host "FAIL: $why"
  exit 1
}

function Invoke-Route([string]$action, [string[]]$addresses, [int]$seq) {
  if (Test-Path -LiteralPath $result) { Remove-Item -LiteralPath $result -Force }
  @{ seq = $seq; action = $action; addresses = $addresses } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $requests -Encoding ASCII
  & $script -Requests $requests
  if (-not (Test-Path -LiteralPath $result)) { Fail "$action wrote no result" }
  $answer = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
  if ($answer.seq -ne $seq) { Fail "$action answered the wrong sequence" }
  return $answer
}

Write-Host '--- the physical default route is visible ---'
Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
  Select-Object ifIndex, NextHop, RouteMetric | Format-Table | Out-String | Write-Host

Write-Host '--- pin adds real routes ---'
$a = '192.0.2.10'
$b = '192.0.2.11'
$answer = Invoke-Route 'pin' @($a, $b) 1
if ($answer.status -ne 'ok') { Fail "pin reported $($answer.status)" }
if ($answer.count -lt 2) { Fail "pin claimed only $($answer.count) routes" }

foreach ($address in @($a, $b)) {
  $route = Get-NetRoute -DestinationPrefix "$address/32" -ErrorAction SilentlyContinue
  if (-not $route) { Fail "$address is not in the route table" }
}
Write-Host 'both routes present in the real table'

$pins = Get-Content -LiteralPath (Join-Path $work 'pins.json') -Raw | ConvertFrom-Json
if (@($pins.routes).Count -ne 2) { Fail 'pins.json did not record both routes' }

Write-Host '--- pinning the same address twice does not double up ---'
$answer = Invoke-Route 'pin' @($a) 2
if ($answer.count -ne 0) { Fail 'a duplicate address was pinned again' }

Write-Host '--- unpin removes exactly those routes ---'
$answer = Invoke-Route 'unpin' @() 3
if ($answer.status -ne 'ok') { Fail "unpin reported $($answer.status)" }
foreach ($address in @($a, $b)) {
  $route = Get-NetRoute -DestinationPrefix "$address/32" -ErrorAction SilentlyContinue
  if ($route) { Fail "$address survived unpin" }
}
if (Test-Path -LiteralPath (Join-Path $work 'pins.json')) {
  Fail 'pins.json survived unpin'
}
Write-Host 'routes gone and state cleared'

Write-Host '--- a tunnel-held address is left alone ---'
$held = '192.0.2.50'
@{ pid = 0; routes = @("$held/32") } | ConvertTo-Json |
  Set-Content -LiteralPath (Join-Path $work 'state.json') -Encoding ASCII
$answer = Invoke-Route 'pin' @($held, $a) 4
$pins = Get-Content -LiteralPath (Join-Path $work 'pins.json') -Raw | ConvertFrom-Json
if (@($pins.routes) -contains "$held/32") { Fail 'a tunnel-held address was pinned' }
if (-not (@($pins.routes) -contains "$a/32")) { Fail 'the good address was not pinned' }
Write-Host 'tunnel route protected'

Write-Host '--- repin drops test pins and keeps the tunnel route ---'
$answer = Invoke-Route 'repin' @() 5
if ($answer.status -ne 'ok') { Fail "repin reported $($answer.status)" }
if (Test-Path -LiteralPath (Join-Path $work 'pins.json')) {
  Fail 'test pins survived repin'
}
$state = Get-Content -LiteralPath (Join-Path $work 'state.json') -Raw | ConvertFrom-Json
if (-not (@($state.routes) -contains "$held/32")) {
  Fail 'the tunnel route was dropped by repin'
}
Write-Host 'test pins dropped, tunnel route kept'

Write-Host '--- cleanup with no live tunnel ---'
$answer = Invoke-Route 'cleanup' @() 6
if ($answer.status -ne 'ok') { Fail "cleanup reported $($answer.status)" }

Get-NetRoute -DestinationPrefix "$held/32" -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -DestinationPrefix "$a/32" -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

Write-Host 'ALL WINDOWS ROUTE CHECKS PASSED'
