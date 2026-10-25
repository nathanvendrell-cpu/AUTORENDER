# One bounded, read-only observation. No renderer invocation or persistent agent.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$decodedSources = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIG__')) | ConvertFrom-Json
$sources = @($decodedSources | ForEach-Object { if ($null -ne $_) { $_ } })
$clock = [Diagnostics.Stopwatch]::StartNew()
$processPartial = $false
$processes = @()
$autoLaunchers = @()
$sourceErrors = @()
$progressBytes = 0
$producerBytes = 0
$relayBytes = 0
$currentSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Read-SmallText([string]$path, [int]$limit, [bool]$tail) {
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'not-regular-file' }
    if (-not $tail -and $item.Length -gt $limit) { throw 'source-limit' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $offset = if ($tail) { [Math]::Max(0, $stream.Length - $limit) } else { 0 }
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int][Math]::Min($limit, $stream.Length))
        $count = $stream.Read($buffer, 0, $buffer.Length)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $count)
        if ($offset -gt 0) { $text = ($text -split "`n", 2)[-1] }
        $after = Get-Item -LiteralPath $path
        if ($after.Length -ne $item.Length -or $after.LastWriteTimeUtc -ne $item.LastWriteTimeUtc) { throw 'source-changed' }
        $result = @{path=$path; text=$text; modified=$item.LastWriteTimeUtc.ToString('o'); bytes=$item.Length}
        if (-not $tail) {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $result.sha256 = ([BitConverter]::ToString($sha.ComputeHash($buffer, 0, $count))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
        }
        return $result
    } finally { $stream.Dispose() }
}

# Renderer candidates get the budget before optional launcher/helper candidates.
$candidates = @(Get-Process -Name 'blender','ffmpeg','powershell','pwsh','python','python3' -ErrorAction SilentlyContinue |
    Where-Object Id -ne $PID |
    Sort-Object @{Expression={if ($_.ProcessName -in @('blender','ffmpeg')) {0} elseif ($_.ProcessName -in @('powershell','pwsh')) {1} else {2}}}, Id)
if ($candidates.Count -gt 64) { $processPartial = $true }
$filter = "Name='blender.exe' OR Name='ffmpeg.exe' OR Name='powershell.exe' OR Name='pwsh.exe' OR Name='python.exe' OR Name='python3.exe'"
$initial = @{}
try { foreach ($c in @(Get-CimInstance Win32_Process -Filter $filter -OperationTimeoutSec 1)) { $initial[[int]$c.ProcessId] = $c } }
catch { $processPartial = $true }

foreach ($p in @($candidates | Select-Object -First 64)) {
    if ($clock.ElapsedMilliseconds -gt 4000) { $processPartial = $true; break }
    try {
        $c = $initial[[int]$p.Id]
        if (-not $c) { $processPartial = $true; continue }
        $owner = Invoke-CimMethod -InputObject $c -MethodName GetOwnerSid -OperationTimeoutSec 1
        if ($owner.ReturnValue -ne 0) { $processPartial = $true; continue }
        if ($owner.Sid -ne $currentSID) { continue }
        $argv = [string]$c.CommandLine
        if ([Text.Encoding]::UTF8.GetByteCount($argv) -gt 4096) { $processPartial = $true; continue }
        $birth = $c.CreationDate.ToUniversalTime()
        $executable = [string]$c.ExecutablePath
        if (-not $executable -or $executable -ine [string]$p.Path) { $processPartial = $true; continue }
        $row = @{pid=$p.Id; parentPid=[int]$c.ParentProcessId; birth=$birth.ToString('o'); name=$p.ProcessName; executable=$executable; ownerVerified=$true; argv=$argv; revalidated=$false}
        if ($p.ProcessName -eq 'blender') {
            $row.birthToken = $p.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
            $relayPath = Join-Path $env:LOCALAPPDATA ('AUTORENDER\Blender\' + $p.Id + '.json')
            if ($relayBytes -lt 524288) {
                try {
                    $relay = Read-SmallText $relayPath 8192 $false
                    $row.blenderRelay = $relay
                    $relayBytes += [Text.Encoding]::UTF8.GetByteCount($relay.text)
                } catch { }
            } else { $processPartial = $true }
        }
        if ($p.ProcessName -eq 'ffmpeg' -and $argv -match '(?i)(?:^|\s)-progress\s+(?:"([^"\r\n]+)"|([^\s"\r\n]+))') {
            $path = if ($Matches[1]) {$Matches[1]} else {$Matches[2]}
            if ($path -match '^[A-Za-z]:[\\/]' -and $progressBytes -lt 98304) {
                try {
                    $sample = Read-SmallText $path 8192 $true
                    if ([DateTime]$sample.modified -ge $birth) { $row.progressFile=$sample; $progressBytes += [Text.Encoding]::UTF8.GetByteCount($sample.text) }
                } catch { } # Progress unavailable does not hide a qualified task.
            }
        }
        if ($p.ProcessName -eq 'blender' -and $argv -match '(?i)(?:^|\s)(?:-P|--python)\s+(?:"([^"\r\n]+)"|([^\s"\r\n]+))') {
            $path = if ($Matches[1]) {$Matches[1]} else {$Matches[2]}
            if ($path -match '^[A-Za-z]:[\\/]' -and $producerBytes -lt 98304) {
                try {
                    $producer = Read-SmallText $path 32768 $false
                    if ([DateTime]$producer.modified -le $birth) { $row.producerSource=$producer; $producerBytes += [Text.Encoding]::UTF8.GetByteCount($producer.text) }
                } catch { }
            }
        }
        if ($p.ProcessName -in @('powershell','pwsh') -and $argv -match '(?i)-File\s+"?([^"\r\n]+?\.ps1)(?:"|\s|$)' -and $autoLaunchers.Count -lt 8) {
            try {
                $launcher = Read-SmallText $Matches[1] 32768 $false
                $autoLaunchers += @{path=$launcher.path;sha256=$launcher.sha256;content=$launcher.text}
            } catch { }
        }
        $processes += $row
    } catch { $processPartial = $true }
}
# A second batched query binds every admitted row to the same process after file IO.
$final = @{}
try { foreach ($c in @(Get-CimInstance Win32_Process -Filter $filter -OperationTimeoutSec 1)) { $final[[int]$c.ProcessId] = $c } }
catch { $processPartial = $true }
$verified = @()
foreach ($row in $processes) {
    $after = $final[[int]$row.pid]
    if (-not $after -or $after.CreationDate.ToUniversalTime().ToString('o') -ne $row.birth -or [string]$after.ExecutablePath -ine $row.executable) {
        $processPartial = $true; continue
    }
    $row.revalidated = $true
    $verified += $row
}
$processes = $verified

function Read-LegacySource($s) {
    $hashes = @()
    foreach ($path in @($s.scriptPath,$s.postScriptPath)) {
        $item = Get-Item -LiteralPath $path
        if ($item.Length -gt 262144 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'source-type-limit'}
        $hashes += @{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    }
    $launcher = Read-SmallText $s.launcherPath 32768 $false
    $stages = @{}
    foreach ($role in @('raw','post')) {
        $path = if ($role -eq 'raw') {$s.rawRoot} else {$s.postRoot}
        $folder = Get-Item -LiteralPath $path
        if (-not $folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'stage-type'}
        $files = @(Get-ChildItem -LiteralPath $path -File -Filter '*.png' | Select-Object -First 20001 | ForEach-Object {
            @{name=$_.Name;bytes=$_.Length;modified=$_.LastWriteTimeUtc.ToString('o');reparse=[bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}
        })
        if ($files.Count -gt 20000) {throw 'frame-limit'}
        $stages[$role] = @{root=$path;files=$files}
    }
    $root = Get-Item -LiteralPath $s.outputRoot
    $logs = @{}; $logTimes = @{}
    $paths = @('journal.txt') + @($s.plans.PSObject.Properties.Name | ForEach-Object {$_.ToString()+'.log';$_.ToString()+'.log.err'})
    foreach ($name in $paths) {
        $path = Join-Path $s.outputRoot $name
        try {
            $sample = Read-SmallText $path 8192 $true
            $logs[$name] = @($sample.text -split '\r?\n' | Select-Object -Last 32)
            $logTimes[$name] = $sample.modified
        } catch { $logs[$name] = @() }
    }
    return @{sourceID=$s.id;observedAt=[DateTime]::UtcNow.ToString('o');outputBirth=$root.CreationTimeUtc.ToString('o');launcher=@{path=$launcher.path;sha256=$launcher.sha256;content=$launcher.text};sources=$hashes;stages=$stages;logs=$logs;logTimes=$logTimes}
}

$runs = @(); $legacyBytes = 0
foreach ($source in $sources) {
    if ($clock.ElapsedMilliseconds -gt 9000) { $sourceErrors += @{sourceID=$source.id;code='source-budget'}; continue }
    try {
        $row = Read-LegacySource $source
        $size = [Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 9 -Compress))
        if ($legacyBytes + $size -gt 400000) {throw 'legacy-packet-budget'}
        $legacyBytes += $size
        $runs += $row
    } catch { $sourceErrors += @{sourceID=$source.id;code='source-unavailable'} }
}
$packet = @{ok=$true;processSchema=1;observedAt=[DateTime]::UtcNow.ToString('o');processPartial=$processPartial;partial=($processPartial -or $sourceErrors.Count -gt 0);processes=$processes;autoLaunchers=$autoLaunchers;runs=$runs;sourceErrors=$sourceErrors}
$json = $packet | ConvertTo-Json -Depth 10 -Compress
# Historical terminal events yield to current process evidence under packet pressure.
if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 950000) {
    foreach ($row in $processes) {
        if ($row.blenderRelay) {
            try {
                $relayPacket = $row.blenderRelay.text | ConvertFrom-Json
                if ($relayPacket.PSObject.Properties.Name -contains 'recentInvocations') {
                    $relayPacket.recentInvocations = @()
                    $row.blenderRelay.text = $relayPacket | ConvertTo-Json -Depth 8 -Compress
                    [void]$row.blenderRelay.Remove('sha256')
                }
            } catch { }
        }
    }
    $json = $packet | ConvertTo-Json -Depth 10 -Compress
}
# Optional file payloads are shed next; process identity and positive attribution survive.
if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 950000) {
    foreach ($row in $processes) { [void]$row.Remove('progressFile'); [void]$row.Remove('producerSource') }
    $packet.autoLaunchers = @()
    $json = $packet | ConvertTo-Json -Depth 10 -Compress
}
while ([Text.Encoding]::UTF8.GetByteCount($json) -gt 950000 -and $packet.runs.Count -gt 0) {
    $removed = $packet.runs[-1]
    $packet.sourceErrors += @{sourceID=$removed.sourceID;code='packet-budget'}
    $packet.runs = @($packet.runs | Select-Object -First ($packet.runs.Count - 1))
    $packet.partial = $true
    $json = $packet | ConvertTo-Json -Depth 10 -Compress
}
while ([Text.Encoding]::UTF8.GetByteCount($json) -gt 950000 -and $packet.processes.Count -gt 0) {
    $packet.processes = @($packet.processes | Select-Object -First ($packet.processes.Count - 1))
    $packet.processPartial = $true; $packet.partial = $true
    $json = $packet | ConvertTo-Json -Depth 10 -Compress
}
$json
