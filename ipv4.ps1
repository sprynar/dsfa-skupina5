<#
    dsfa_lab.ps1  —  nastavi / obnovi sit pro DSFA lab (jeden soubor)

    Spustit jako Administrator:
        .\dsfa_lab.ps1                    # LAB:    staticka IP + firewall OFF
        .\dsfa_lab.ps1 -LabIP 10.0.0.60   # -||- pro druhy stroj
        .\dsfa_lab.ps1 -Restore           # NORMAL: zpet na DHCP + firewall ON

    Pozn.: -Restore vraci rozhrani na DHCP (predpoklad: stroj byl puvodne na DHCP).
#>
param(
    [switch]$Restore,
    [string]$Iface = "Ethernet",          # nazev adapteru (netsh interface show interface)
    [string]$LabIP = "10.0.0.50",
    [string]$Mask  = "255.255.255.0"
)

# admin check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Spust PowerShell jako Administrator." -ForegroundColor Red; exit 1
}

# vypise velky zarameceny banner s vycentrovanym textem
function Show-Banner([string[]]$lines, [string]$color) {
    $w = 60
    $border = ('#' * ($w + 4))
    Write-Host ""
    Write-Host $border -ForegroundColor $color
    Write-Host ("#" + (" " * ($w + 2)) + "#") -ForegroundColor $color
    foreach ($l in $lines) {
        $pad = [math]::Max(0, $w - $l.Length)
        $left = [math]::Floor($pad / 2)
        Write-Host ("# " + (" " * $left) + $l + (" " * ($pad - $left)) + " #") -ForegroundColor $color
    }
    Write-Host ("#" + (" " * ($w + 2)) + "#") -ForegroundColor $color
    Write-Host $border -ForegroundColor $color
    Write-Host ""
}

# --- POTVRZENI pred jakoukoli zmenou ---
if ($Restore) {
    Show-Banner @("!!!   P O Z O R   !!!","","PREPOJIL/A JSI KABELY ZPATKY DO PUVODNI SITE?") "Yellow"
} else {
    Show-Banner @("!!!   P O Z O R   !!!","","PREPOJIL/A JSI KABELY NA LABORATORNI","SIT BEZ INTERNETU?") "Yellow"
}
$ans = Read-Host "Napis  ano / ne"
if ($ans -notmatch '^(ano|a|yes|y)$') {
    Write-Host "Zruseno - nic jsem nemenil." -ForegroundColor Red
    exit
}

# --- vlastni akce ---
if ($Restore) {
    netsh interface ipv4 set address    "name=$Iface" dhcp
    netsh interface ipv4 set dnsservers "name=$Iface" dhcp
    netsh advfirewall set allprofiles state on
    Write-Host "OBNOVENO: DHCP + firewall zapnut." -ForegroundColor Green
}
else {
    netsh interface ipv4 set address "name=$Iface" static $LabIP $Mask
    netsh advfirewall set allprofiles state off
    Write-Host "LAB: IP $LabIP / $Mask, firewall vypnut." -ForegroundColor Green
}

ipconfig | Select-String "IPv4"
