param(
    [ValidateSet('status','on','off','toggle','set')][string]$Action = 'status',
    [int]$Strength = 50
)

$ErrorActionPreference = 'Stop'
$statePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate'
$settingsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.settings\windows.data.bluelightreduction.settings'

function Find-Bytes([byte[]]$Data, [byte[]]$Needle, [int]$Start = 0) {
    for ($i=$Start; $i -le $Data.Length-$Needle.Length; $i++) {
        $ok=$true
        for ($j=0; $j -lt $Needle.Length; $j++) { if ($Data[$i+$j] -ne $Needle[$j]) {$ok=$false; break} }
        if ($ok) { return $i }
    }
    return -1
}

function Encode-VarUInt64([UInt64]$Value) {
    $a = New-Object System.Collections.Generic.List[byte]
    do {
        $b = [byte]($Value -band 0x7f)
        $Value = $Value -shr 7
        if ($Value -ne 0) { $b = $b -bor 0x80 }
        $a.Add($b)
    } while ($Value -ne 0)
    return $a.ToArray()
}

function Replace-Range([byte[]]$Data, [int]$At, [int]$Count, [byte[]]$NewBytes) {
    $list = New-Object System.Collections.Generic.List[byte]
    if ($At -gt 0) { $list.AddRange([byte[]]$Data[0..($At-1)]) }
    $list.AddRange($NewBytes)
    $tail=$At+$Count
    if ($tail -lt $Data.Length) { $list.AddRange([byte[]]$Data[$tail..($Data.Length-1)]) }
    return $list.ToArray()
}

function Read-Var([byte[]]$Data,[int]$At) {
    [UInt64]$v=0; $shift=0; $n=0
    do { $b=$Data[$At+$n]; $v=$v -bor ([UInt64]($b -band 0x7f) -shl $shift); $shift+=7; $n++ } while (($b -band 0x80) -ne 0)
    return @($v,$n)
}

function Touch-CloudTimestamp([byte[]]$Data) {
    $p=Find-Bytes $Data ([byte[]](0x2A,0x06))
    if ($p -lt 0) { return $Data }
    $old=Read-Var $Data ($p+2)
    $now=[UInt64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return Replace-Range $Data ($p+2) ([int]$old[1]) (Encode-VarUInt64 $now)
}

function Get-StateBytes { return [byte[]](Get-ItemPropertyValue -Path $statePath -Name Data) }
function Get-SettingsBytes { return [byte[]](Get-ItemPropertyValue -Path $settingsPath -Name Data) }

function Get-IsEnabled([byte[]]$Data) {
    $first=Find-Bytes $Data ([byte[]](0x43,0x42,0x01,0x00))
    $inner=Find-Bytes $Data ([byte[]](0x43,0x42,0x01,0x00)) ($first+4)
    if ($inner -lt 0) { throw 'Unsupported Night Light state format.' }
    return ($Data[$inner+4] -eq 0x10 -and $Data[$inner+5] -eq 0x00)
}

function Set-NightState([bool]$Enable) {
    [byte[]]$d=Get-StateBytes
    $first=Find-Bytes $d ([byte[]](0x43,0x42,0x01,0x00))
    $inner=Find-Bytes $d ([byte[]](0x43,0x42,0x01,0x00)) ($first+4)
    if ($inner -lt 0) { throw 'Unsupported Night Light state format.' }
    $enabled=Get-IsEnabled $d
    if ($Enable -and -not $enabled) { $d=Replace-Range $d ($inner+4) 0 ([byte[]](0x10,0x00)) }
    elseif (-not $Enable -and $enabled) { $d=Replace-Range $d ($inner+4) 2 ([byte[]]@()) }
    else { return }
    # The byte immediately before the inner header is the small payload length for normal Windows 11 blobs.
    $d[$inner-1]=[byte]($d[$inner-1] + $(if($Enable){2}else{-2}))
    $d=Touch-CloudTimestamp $d
    Set-ItemProperty -Path $statePath -Name Data -Value $d -Type Binary
}

function Get-Strength {
    [byte[]]$d=Get-SettingsBytes
    $p=Find-Bytes $d ([byte[]](0xCF,0x28))
    if ($p -lt 0) { return 50 }
    $r=Read-Var $d ($p+2)
    $kelvin=[int]([UInt64]$r[0] -shr 1)
    return [math]::Max(0,[math]::Min(100,[math]::Round((6500-$kelvin)/53.0)))
}

function Set-Strength([int]$Percent) {
    $Percent=[math]::Max(0,[math]::Min(100,$Percent))
    $kelvin=6500-[math]::Round(53*$Percent)
    [UInt64]$zig=[UInt64]($kelvin*2)
    [byte[]]$d=Get-SettingsBytes
    $p=Find-Bytes $d ([byte[]](0xCF,0x28))
    if ($p -lt 0) { throw 'Unsupported Night Light settings format.' }
    $old=Read-Var $d ($p+2)
    $d=Replace-Range $d ($p+2) ([int]$old[1]) (Encode-VarUInt64 $zig)
    $d=Touch-CloudTimestamp $d
    Set-ItemProperty -Path $settingsPath -Name Data -Value $d -Type Binary
}

try {
    switch ($Action) {
        'status' { Write-Output (Get-Strength) }
        'on' { Set-NightState $true }
        'off' { Set-NightState $false }
        'toggle' { $d=Get-StateBytes; Set-NightState (-not (Get-IsEnabled $d)) }
        'set' { Set-Strength $Strength; Write-Output $Strength }
    }
} catch {
    $log=Join-Path $PSScriptRoot 'NightLightError.txt'
    "$(Get-Date -Format s) $($_.Exception.Message)" | Add-Content -Path $log -Encoding UTF8
    if ($Action -eq 'status') { Write-Output 50 }
    exit 1
}

