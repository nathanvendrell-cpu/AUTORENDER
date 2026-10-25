$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$r=([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REQUEST__'))|ConvertFrom-Json)
Add-Type -TypeDefinition @'
using System;using System.IO;using System.Runtime.InteropServices;using System.Security.Cryptography;using Microsoft.Win32.SafeHandles;
public static class ARLibraryFile {
 [StructLayout(LayoutKind.Sequential)] struct Info { public uint Attr;public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;public uint Volume,SizeHi,SizeLo,Links,IndexHi,IndexLo; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct RenameInfo { [MarshalAs(UnmanagedType.U1)] public bool Replace;public IntPtr Root;public uint Length;public char Name; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string p,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int c,IntPtr b,uint n);
 public static FileStream Open(string path,bool rename) {var h=CreateFile(path,0x80000000u|(rename?0x10000u:0u),1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);if(h.IsInvalid)throw new IOException("exclusive-read-handle");Info i;if(!GetFileInformationByHandle(h,out i)||(i.Attr&0x410)!=0){h.Dispose();throw new IOException("non-regular-file");}return new FileStream(h,FileAccess.Read);}
 public static string Identity(FileStream f){Info i;if(!GetFileInformationByHandle(f.SafeFileHandle,out i))throw new IOException("file-info");return i.Volume+":"+i.IndexHi+":"+i.IndexLo+":"+i.SizeHi+":"+i.SizeLo+":"+i.Written.dwHighDateTime+":"+i.Written.dwLowDateTime;}
 public static string Hash(FileStream f){f.Position=0;using(var s=SHA256.Create()){return BitConverter.ToString(s.ComputeHash(f)).Replace("-","").ToLowerInvariant();}}
 public static void Rename(FileStream f,string path){byte[] name=System.Text.Encoding.Unicode.GetBytes(path);int start=(int)Marshal.OffsetOf(typeof(RenameInfo),"Name");int length=start+name.Length;IntPtr b=Marshal.AllocHGlobal(length);try{for(int j=0;j<length;j++)Marshal.WriteByte(b,j,0);Marshal.WriteInt32(b,(int)Marshal.OffsetOf(typeof(RenameInfo),"Length"),name.Length);Marshal.Copy(name,0,IntPtr.Add(b,start),name.Length);if(!SetFileInformationByHandle(f.SafeFileHandle,3,b,(uint)length))throw new IOException("exclusive-rename-"+Marshal.GetLastWin32Error());}finally{Marshal.FreeHGlobal(b);}}
}
'@
function Safe-Path([string]$p){
 if($p -notmatch '^[A-Za-z]:[\\/]' -or $p.Length -gt 390 -or $p -match '[\x00-\x1f\x7f]' -or ($p -split '[\\/]') -contains '..'){throw 'invalid-path'}
 $full=[IO.Path]::GetFullPath($p);$d=$full
 while($d){if(Test-Path -LiteralPath $d){$x=Get-Item -LiteralPath $d -Force;if($x.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse-path'}};$parent=[IO.Path]::GetDirectoryName($d);if($parent -eq $d){break};$d=$parent};return $full
}
function Durable-JSON([string]$p,$data){
 $b=[Text.Encoding]::UTF8.GetBytes(($data|ConvertTo-Json -Depth 8 -Compress));$f=[IO.FileStream]::new($p,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($b,0,$b.Length);$f.Flush($true)}finally{$f.Dispose()}
}
if($r.operation -eq 'policy'){
 if($r.policy.schemaVersion -ne 1 -or $r.policy.enabled -isnot [bool] -or $r.policy.exportInMemory -isnot [bool] -or [DateTimeOffset]::Parse($r.policy.activatedAt) -gt [DateTimeOffset]::UtcNow){throw 'invalid-policy'}
 if($r.policy.enabled -and ([DateTimeOffset]::Parse($r.policy.expiresAt) -lt [DateTimeOffset]::UtcNow -or [DateTimeOffset]::Parse($r.policy.expiresAt) -gt [DateTimeOffset]::UtcNow.AddSeconds(130))){throw 'invalid-policy-lease'}
 $dir=Safe-Path (Join-Path $env:LOCALAPPDATA 'AUTORENDER');[IO.Directory]::CreateDirectory($dir)|Out-Null;$dest=Safe-Path (Join-Path $dir 'LibraryPolicy.json')
 if(Test-Path -LiteralPath $dest){$old=Get-Content -LiteralPath $dest -Raw|ConvertFrom-Json;if($old.schemaVersion -ne 1){throw 'foreign-policy'}}
 $tmp=Join-Path $dir ('.policy-'+[Guid]::NewGuid().ToString('N')+'.tmp');try{Durable-JSON $tmp $r.policy;if(Test-Path -LiteralPath $dest){[IO.File]::Replace($tmp,$dest,$null)}else{[IO.File]::Move($tmp,$dest)}}finally{if(Test-Path -LiteralPath $tmp){[IO.File]::Delete($tmp)}}
 [pscustomobject]@{ok=$true;configured=$true}|ConvertTo-Json -Compress;exit
}
function Hash-Bytes([byte[]]$bytes){$s=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($s.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose()}}
function Read-JSON([string]$path,[int]$maximum){$path=Safe-Path $path;$f=Get-Item -LiteralPath $path -Force;if($f.PSIsContainer -or $f.Length -gt $maximum){throw 'manifest-bound'};return [IO.File]::ReadAllBytes($path)}
function Verify-Scripts {
 $s=$a.scriptProof
 foreach($pair in @(@($s.launcherPath,$s.launcherSHA256),@($s.scriptPath,$s.scriptSHA256),@($s.postScriptPath,$s.postScriptSHA256))){$p=Safe-Path $pair[0];if($pair[1] -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pair[1]){throw 'script-contract-changed'}}
 if(@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {$_.Name -match '^(blender|ffmpeg)\.exe$'}).Count -ne 0){throw 'script-producer-present'}
}
function Manifest-Descriptor {
 $base=Safe-Path (Join-Path $env:LOCALAPPDATA ('AUTORENDER\Manifests\'+$a.invocationToken));$index=Safe-Path (Join-Path $base 'index.json')
 if($a.scriptProof -and !(Test-Path -LiteralPath $index)){
  Verify-Scripts;$s=$a.scriptProof;$raw=Safe-Path $s.rawRoot;$post=Safe-Path $s.postRoot;$items=@();$names=@{};$pages=@()
  foreach($prop in @($s.plans.psobject.Properties|Sort-Object Name)){
   $plan=$prop.Name;$range=@($prop.Value);if($plan -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,15}$' -or $range.Count -ne 2 -or $range[0] -lt 0 -or $range[1] -lt $range[0] -or $range[1]-$range[0] -ge 20000){throw 'script-plan'}
   for($n=[int]$range[0];$n -le [int]$range[1];$n++){
    $name=$plan+'_'+$n.ToString('0000')+'.png';if($names.ContainsKey($name) -or $names.Count -ge 20000){throw 'script-frame-bound'};$names[$name]=$true
    foreach($root in @($raw,$post)){$f=Get-Item -LiteralPath (Safe-Path (Join-Path $root $name)) -Force;if($f.PSIsContainer -or $f.Length -le 0 -or $f.LastWriteTimeUtc -lt [DateTimeOffset]::Parse($a.startedAt).UtcDateTime){throw 'old-or-incomplete-script-output'}}
    $path=Safe-Path (Join-Path $post $name);$aid=Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($a.invocationToken+'|'+$path.Replace('\','/').ToLowerInvariant()));$items+=@([pscustomobject]@{id=$aid;path=$path;frame=$n;bytes=(Get-Item -LiteralPath $path).Length;modifiedNanoseconds=([long]((Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks-621355968000000000)*100)})
   }
  }
  if($items.Count -eq 0){throw 'empty-script-output'};[IO.Directory]::CreateDirectory($base)|Out-Null
  for($offset=0;$offset -lt $items.Count;$offset+=32){$last=[Math]::Min($offset+31,$items.Count-1);$pageName='page-'+([int]($offset/32)).ToString('000000')+'.json';$page=Join-Path $base $pageName;$obj=[pscustomobject]@{schemaVersion=1;id=$a.invocationToken;artifacts=@($items[$offset..$last])}
   if(!(Test-Path -LiteralPath $page)){Durable-JSON $page $obj}
   $b=Read-JSON $page 524288;$decoded=[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json
   if($decoded.id -ne $a.invocationToken -or @($decoded.artifacts).Count -ne $last-$offset+1){throw 'partial-manifest-collision'}
   for($j=0;$j -lt @($decoded.artifacts).Count;$j++){if($decoded.artifacts[$j].id -ne $items[$offset+$j].id -or $decoded.artifacts[$j].path -ine $items[$offset+$j].path){throw 'partial-manifest-changed'}}
   $pages+=@([pscustomobject]@{name=$pageName;sha256=(Hash-Bytes $b);count=($last-$offset+1)})
  }
  Verify-Scripts;Durable-JSON $index ([pscustomobject]@{schemaVersion=1;id=$a.invocationToken;startedAt=$a.startedAt;completedAt=$a.completedAt;expectedCount=$items.Count;complete=$true;scriptProof=$s;pages=$pages})
 }
 $bytes=Read-JSON $index 524288;$sha=Hash-Bytes $bytes;$m=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
 if($m.schemaVersion -ne 1 -or $m.id -ne $a.invocationToken -or $m.startedAt -ne $a.startedAt -or $m.complete -ne $true -or $m.expectedCount -le 0 -or $m.expectedCount -gt 50000 -or @($m.pages).Count -gt 1563){throw 'incomplete-manifest'}
 if($a.manifest -and ($sha -ne $a.manifest.sha256 -or $index -ine $a.manifest.indexPath -or $m.expectedCount -ne $a.manifest.expectedCount)){throw 'manifest-changed'}
 if($a.scriptProof -and $m.scriptProof.runID -ne $a.scriptProof.runID){throw 'script-manifest-scope'}
 return [pscustomobject]@{id=$m.id;indexPath=$index;sha256=$sha;expectedCount=[int]$m.expectedCount;complete=$true}
}
function Check-Membership {
 $d=Manifest-Descriptor;$indexBytes=Read-JSON $d.indexPath 524288;$m=[Text.Encoding]::UTF8.GetString($indexBytes)|ConvertFrom-Json
 $pagePath=Safe-Path $a.manifestPagePath;$name=[IO.Path]::GetFileName($pagePath);$page=@($m.pages|Where-Object {$_.name -eq $name})
 if($page.Count -ne 1 -or $pagePath -ine (Join-Path ([IO.Path]::GetDirectoryName($d.indexPath)) $name) -or $page[0].sha256 -ne $a.manifestPageSHA256){throw 'unattested-manifest-page'}
 $b=Read-JSON $pagePath 524288;if((Hash-Bytes $b) -ne $page[0].sha256){throw 'manifest-page-changed'};$p=[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json
 $entry=@($p.artifacts|Where-Object {$_.path.Replace('/','\') -ieq $path.Replace('/','\')})
 if($entry.Count -ne 1){throw 'unattested-artifact'}
 if($r.operation -ne 'restore' -and (Test-Path -LiteralPath $path)){
  $f=Get-Item -LiteralPath $path -Force;$ns=[long]($f.LastWriteTimeUtc.Ticks-621355968000000000)*100
  if($entry[0].bytes -ne $f.Length -or $entry[0].modifiedNanoseconds -ne $ns){throw 'artifact-changed-since-final-manifest'}
 }
}

$a=$r.artifact;$path=Safe-Path $a.path
if([IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp','.exr','.tif','.tiff','.mp4','.mov','.mkv','.wav','.flac','.mp3','.aif','.aiff')){throw 'media-type-only'}
if($a.invocationToken -notmatch '^[a-f0-9]{32}$' -or $a.birthToken -notmatch '^[0-9]{1,20}$' -or (!$a.scriptProof -and [int]$a.processID -le 0)){throw 'invalid-invocation'}
if([DateTimeOffset]::Parse($a.startedAt) -lt [DateTimeOffset]::Parse($r.activatedAt) -or [DateTimeOffset]::Parse($a.completedAt) -lt [DateTimeOffset]::Parse($a.startedAt)){throw 'activation-barrier'}
function Idle-Proof {
 if($a.scriptProof){Verify-Scripts;if($r.operation -ne 'manifest'){Check-Membership};return}
 $all=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object {$_.Name -match '^(blender|ffmpeg)\.exe$'})
 foreach($p in $all){if([int]$p.ProcessId -ne [int]$a.processID){throw 'other-producer-present'};if($p.Name -ine 'blender.exe'){throw 'producer-not-native-blender'};$native=Get-Process -Id $p.ProcessId -ErrorAction Stop;if($native.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ne $a.birthToken){throw 'pid-reused'}}
 $eventFile=Safe-Path (Join-Path $env:LOCALAPPDATA ('AUTORENDER\Blender\'+$a.processID+'.json'))
 $fi=Get-Item -LiteralPath $eventFile -Force;if($fi.Length -gt 8192){throw 'event-size'};$e=Get-Content -LiteralPath $eventFile -Raw|ConvertFrom-Json
 if($e.pid -ne $a.processID -or $e.birthToken -ne $a.birthToken -or ($all.Count -gt 0 -and ($e.jobRunning -ne $false -or $e.state -in @('active','unknown')))){throw 'native-not-idle'}
 if($all.Count -gt 0 -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($e.observedAt)).TotalSeconds -gt 30){throw 'stale-heartbeat'}
 $match=@(@($e)+@($e.recentInvocations)|Where-Object {$_.invocationToken -eq $a.invocationToken -and $_.state -eq 'complete' -and $_.startedAt -eq $a.startedAt -and $_.eventAt -eq $a.completedAt})
 if($match.Count -ne 1){throw 'unattested-final-invocation'}
 if($a.manifest){if($match[0].outputManifest.sha256 -ne $a.manifest.sha256 -or $match[0].outputManifest.id -ne $a.manifest.id){throw 'unattested-manifest'};if($r.operation -ne 'manifest'){Check-Membership}}
 elseif($match[0].writtenFrames -gt 1 -or $match[0].sourceContext.outputPath.Replace('/','\') -ine $path.Replace('/','\')){throw 'manifest-required'}
 if($match[0].writtenFrames -le 0 -and $match[0].exportArtifact.path -ine $path){throw 'in-memory-only'}
}
Idle-Proof
if($r.operation -eq 'manifest'){
 $d=Manifest-Descriptor;$b=Read-JSON $d.indexPath 524288;$m=[Text.Encoding]::UTF8.GetString($b)|ConvertFrom-Json;$cursor=[int]$r.cursor;$offset=0;$selected=$null
 foreach($page in @($m.pages)){if($offset -eq $cursor){$selected=$page;break};$offset+=[int]$page.count}
 if(!$selected -or $cursor -lt 0 -or $cursor -ge $d.expectedCount){throw 'manifest-cursor'}
 $pagePath=Safe-Path (Join-Path ([IO.Path]::GetDirectoryName($d.indexPath)) $selected.name);$bytes=Read-JSON $pagePath 524288
 if((Hash-Bytes $bytes) -ne $selected.sha256){throw 'manifest-page-hash'};$page=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
 if($page.id -ne $d.id -or @($page.artifacts).Count -ne $selected.count -or @($page.artifacts).Count -gt 32){throw 'manifest-page-count'}
 $next=$cursor+@($page.artifacts).Count;if($next -eq $d.expectedCount){$next=$null}
 [pscustomobject]@{ok=$true;descriptor=$d;artifacts=@($page.artifacts);nextCursor=$next;complete=$true;pagePath=$pagePath;pageSHA256=$selected.sha256}|ConvertTo-Json -Depth 8 -Compress;exit
}
if($r.operation -in @('inspect','read')){
 $f=[ARLibraryFile]::Open($path,$false);try{
 if($f.Length -le 0 -or $f.Length -gt 2147483648){throw 'transfer-size-bound'};$sha=[ARLibraryFile]::Hash($f);if($r.sha256 -and $sha -ne $r.sha256){throw 'changed-source'}
 if($r.operation -eq 'read'){$f.Position=0;$out=[Console]::OpenStandardOutput();$f.CopyTo($out,1048576);$out.Flush()}
 else{[pscustomobject]@{ok=$true;sha256=$sha;bytes=$f.Length;identity=[ARLibraryFile]::Identity($f);observedAt=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json -Compress}
 }finally{$f.Dispose()};exit
}
if($r.operation -notin @('retire','restore') -or $r.transactionID -notmatch '^[a-f0-9]{64}$' -or $r.sha256 -notmatch '^[a-f0-9]{64}$'){throw 'invalid-operation'}
$dir=Safe-Path (Join-Path ([IO.Path]::GetDirectoryName($path)) '.autoren-returns');$held=Safe-Path (Join-Path $dir ($r.transactionID+[IO.Path]::GetExtension($path).ToLowerInvariant()));$journal=Safe-Path (Join-Path $dir ($r.transactionID+'.json'))
if($r.operation -eq 'retire'){
 [IO.Directory]::CreateDirectory($dir)|Out-Null
 # Bound the whole return area. No eviction or permanent source deletion.
 $files=@(Get-ChildItem -LiteralPath $dir -File -Force);if(@($files|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count -gt 0){throw 'return-area-reparse'}
 if(Test-Path -LiteralPath $held){if(Test-Path -LiteralPath $path){throw 'source-and-return-collision'};$f=[ARLibraryFile]::Open($held,$false);try{if([ARLibraryFile]::Hash($f) -ne $r.sha256){throw 'return-changed'}}finally{$f.Dispose()}}
 else{
  $f=[ARLibraryFile]::Open($path,$true);try{
   if([ARLibraryFile]::Hash($f) -ne $r.sha256){throw 'changed-before-retirement'}
   if($files.Count -ge 128 -or (($files|Measure-Object Length -Sum).Sum+$f.Length) -gt 2147483648){throw 'return-area-full-source-kept'}
   if(!(Test-Path -LiteralPath $journal)){Durable-JSON $journal ([pscustomobject]@{schemaVersion=1;transactionID=$r.transactionID;source=$path;held=$held;sha256=$r.sha256;artifact=$a})}
   else{$j=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json;if($j.source -ine $path -or $j.sha256 -ne $r.sha256 -or $j.transactionID -ne $r.transactionID){throw 'journal-collision'}}
   Idle-Proof;[ARLibraryFile]::Rename($f,$held);if([ARLibraryFile]::Hash($f) -ne $r.sha256){throw 'post-rename-hash'}
  }finally{$f.Dispose()}
 }
 [pscustomobject]@{ok=$true;originalPath=$path;returnPath=$held;sha256=$r.sha256;transactionID=$r.transactionID;connectionScope=$a.connectionScope}|ConvertTo-Json -Compress
}else{
 if(Test-Path -LiteralPath $held){if(Test-Path -LiteralPath $path){throw 'restore-collision'};$f=[ARLibraryFile]::Open($held,$true);try{if([ARLibraryFile]::Hash($f) -ne $r.sha256){throw 'return-changed'};Idle-Proof;[ARLibraryFile]::Rename($f,$path)}finally{$f.Dispose()}}
 $f=[ARLibraryFile]::Open($path,$false);try{if([ARLibraryFile]::Hash($f) -ne $r.sha256){throw 'restore-not-verified'}}finally{$f.Dispose()}
 [pscustomobject]@{ok=$true;restored=$true;originalPath=$path;returnPath=$held;sha256=$r.sha256;transactionID=$r.transactionID;connectionScope=$a.connectionScope}|ConvertTo-Json -Compress
}
