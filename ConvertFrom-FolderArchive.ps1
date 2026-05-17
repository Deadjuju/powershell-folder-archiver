#Requires -Version 5.0
<#
.SYNOPSIS
    Decode une archive .txt creee par ConvertTo-FolderArchive.ps1.
.DESCRIPTION
    Restaure les fichiers d'une archive base64 avec verification d'integrite SHA256.
    Affiche le detail de toutes les erreurs en fin de traitement.
.PARAMETER InputFile
    Premier fichier de l'archive (ou le seul si archive simple).
.PARAMETER OutputFolder
    Dossier de destination.
.EXAMPLE
    .\ConvertFrom-FolderArchive.ps1
    .\ConvertFrom-FolderArchive.ps1 -InputFile "archive_part1.txt" -OutputFolder "C:\Restaure"
#>

param(
    [string]$InputFile    = "",
    [string]$OutputFolder = "",
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

# -----------------------------------------------
# Fonctions GUI
# -----------------------------------------------

function Show-FilePicker {
    param([string]$Title)
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title       = $Title
    $d.Filter      = "Fichiers texte (*.txt)|*.txt|Tous les fichiers (*.*)|*.*"
    $d.Multiselect = $false
    if ($d.ShowDialog() -eq "OK") { return $d.FileName }
    return $null
}

function Show-FolderPicker {
    param([string]$Description, [string]$InitialPath = "")
    try {
        $app = New-Object -ComObject Shell.Application
        $folder = $app.BrowseForFolder(0, $Description, 0, $InitialPath)
        if ($folder) { return $folder.Self.Path }
        return $null
    } catch {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description         = $Description
        $d.ShowNewFolderButton = $true
        if ($InitialPath -and (Test-Path $InitialPath)) { $d.SelectedPath = $InitialPath }
        if ($d.ShowDialog() -eq "OK") { return $d.SelectedPath }
        return $null
    }
}

# -----------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

function Show-PasswordDialog {
    param([string]$Title = "Mot de passe requis")

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $Title
    $form.Size            = New-Object System.Drawing.Size(420, 190)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Cette archive est chiffree. Entrez le mot de passe :"
    $lbl.Location = New-Object System.Drawing.Point(20, 20)
    $lbl.Size     = New-Object System.Drawing.Size(370, 20)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location              = New-Object System.Drawing.Point(20, 50)
    $txt.Size                  = New-Object System.Drawing.Size(370, 25)
    $txt.UseSystemPasswordChar = $true

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text         = "OK"
    $btn.Location     = New-Object System.Drawing.Point(155, 110)
    $btn.Size         = New-Object System.Drawing.Size(100, 30)
    $btn.DialogResult = "OK"
    $form.AcceptButton = $btn
    $form.Controls.AddRange(@($lbl, $txt, $btn))

    $r = $form.ShowDialog()
    if ($r -eq "OK") { return $txt.Text }
    return $null
}

function Get-ContentHash {
    param([byte[]]$Data)
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash($Data)).Replace("-", "").ToLower()
    $sha.Dispose()
    return $hash
}

function Get-DerivedKeys {
    param([string]$Password, [byte[]]$Salt)
    $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $Password, $Salt, 600000,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $keyMaterial = $pbkdf2.GetBytes(64)
    $pbkdf2.Dispose()
    return [PSCustomObject]@{
        AesKey  = $keyMaterial[0..31]
        HmacKey = $keyMaterial[32..63]
    }
}

function Unprotect-Data {
    param([byte[]]$Data, [string]$Password)
    try {
        # Format : VERSION(1) + SEL(32) + IV(16) + MAC(32) + CIPHERTEXT
        if ($Data.Length -lt 81) { return $null }

        $version    = $Data[0]
        $salt       = $Data[1..32]
        $iv         = $Data[33..48]
        $mac        = $Data[49..80]
        $cipherText = $Data[81..($Data.Length - 1)]

        # Deriver les cles
        $keys = Get-DerivedKeys -Password $Password -Salt $salt

        # Verifier HMAC avant de dechiffrer (Encrypt-then-MAC)
        $hmacInput   = [byte[]]@($version) + $salt + $iv + $cipherText
        $hmac        = [System.Security.Cryptography.HMACSHA256]::new()
        $hmac.Key    = $keys.HmacKey
        $expectedMac = $hmac.ComputeHash($hmacInput)
        $hmac.Dispose()

        # Comparaison en temps constant pour eviter les timing attacks
        $diff = 0
        for ($k = 0; $k -lt 32; $k++) { $diff = $diff -bor ($mac[$k] -bxor $expectedMac[$k]) }
        if ($diff -ne 0) { return $null }

        # Dechiffrement AES-256-CBC
        $aes           = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize   = 256
        $aes.BlockSize = 128
        $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key       = $keys.AesKey
        $aes.IV        = $iv

        $ms = New-Object System.IO.MemoryStream($cipherText, 0, $cipherText.Length)
        $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $aes.CreateDecryptor(), "Read")
        $out = New-Object System.IO.MemoryStream
        $cs.CopyTo($out)
        $aes.Dispose()
        return $out.ToArray()
    } catch {
        return $null
    }
}

function Get-ArchiveParts {
    param([string]$FirstFile)
    $dir      = [System.IO.Path]::GetDirectoryName($FirstFile)
    $nameBase = [System.IO.Path]::GetFileNameWithoutExtension($FirstFile)
    $ext      = [System.IO.Path]::GetExtension($FirstFile)

    if ($nameBase -notmatch '_part\d+$') {
        return @($FirstFile)
    }
    $baseName = $nameBase -replace '_part\d+$', ''
    $parts    = Get-ChildItem -Path $dir -Filter ($baseName + "_part*" + $ext) |
                Sort-Object { [int]($_.BaseName -replace '.*_part', '') }
    return @($parts | ForEach-Object { $_.FullName })
}

function ConvertFrom-ArchiveLines {
    param(
        [string[]]$Lines,
        [string]$OutputFolder,
        [ref]$FileCount,
        [ref]$ErrorList,
        [ref]$TotalBytes,
        [bool]$VerifyMode = $false
    )

    $i = 0
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i].TrimEnd("`r")

        if ($line -eq "###ARCHIVE_HEADER###") {
            while ($i -lt $Lines.Count -and $Lines[$i].TrimEnd("`r") -ne "###END_HEADER###") { $i++ }
            $i++
            continue
        }

        if ($line.StartsWith("###FILE###")) {
            $relativePath = $line.Substring(10)
            $i++

            $expectedHash = $null
            if ($i -lt $Lines.Count -and $Lines[$i].TrimEnd("`r").StartsWith("HASH=")) {
                $expectedHash = $Lines[$i].TrimEnd("`r").Substring(5)
                $i++
            }

            $encodedLines = [System.Collections.Generic.List[string]]::new()
            while ($i -lt $Lines.Count -and $Lines[$i].TrimEnd("`r") -ne "###END###") {
                $encodedLines.Add($Lines[$i].TrimEnd("`r"))
                $i++
            }
            $i++

            $fullPath  = Join-Path $OutputFolder $relativePath
            if (-not $VerifyMode) {
                $parentDir = Split-Path $fullPath -Parent
                if (-not (Test-Path $parentDir)) {
                    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                }
            }

            try {
                $bytes = [Convert]::FromBase64String($encodedLines -join "")

                if ($expectedHash) {
                    $actualHash = Get-ContentHash -Data $bytes
                    if ($actualHash -ne $expectedHash) {
                        $msg = "HASH KO : $relativePath"
                        Write-Host ("  [HASH KO] {0}" -f $relativePath) -ForegroundColor Red
                        Write-Log "HASH KO : $relativePath" "ERREUR"
                        $ErrorList.Value.Add($msg)
                        continue
                    }
                }

                if (-not $VerifyMode) {
                    [System.IO.File]::WriteAllBytes($fullPath, $bytes)
                }
                $TotalBytes.Value += $bytes.Length
                $FileCount.Value++
                $okLabel = if ($VerifyMode) { "[OK - hash valide]" } else { "[OK]" }
                Write-Host ("  $okLabel {0}" -f $relativePath)
                Write-Log "OK : $relativePath"
            } catch {
                $msg = "ERREUR : $relativePath  -  $_"
                Write-Host ("  [ERREUR] {0} : {1}" -f $relativePath, $_) -ForegroundColor Red
                Write-Log "ERREUR : $relativePath - $_" "ERREUR"
                $ErrorList.Value.Add($msg)
            }
        } else {
            $i++
        }
    }
}

# -----------------------------------------------
# Saisie des parametres
# -----------------------------------------------

if (-not $InputFile -or -not (Test-Path $InputFile)) {
    $InputFile = Show-FilePicker -Title "Selectionner le fichier archive (premiere partie si multi-parties)"
    if (-not $InputFile) { Write-Host "Annule."; exit 0 }
}

if ($VerifyOnly) {
    $OutputFolder = "VERIFY_ONLY_NO_OUTPUT"
    Write-Host "Mode verification seule (aucun fichier ne sera ecrit)" -ForegroundColor Yellow
} elseif (-not $OutputFolder) {
    $OutputFolder = Show-FolderPicker -Description "Selectionner le dossier de destination"
    if (-not $OutputFolder) { Write-Host "Annule."; exit 0 }
}

# -----------------------------------------------
# Detection des parties
# -----------------------------------------------

$partFiles = @(Get-ArchiveParts -FirstFile $InputFile)

# Initialisation du log (meme dossier que l'archive)
$logDir         = [System.IO.Path]::GetDirectoryName($InputFile)
$logBaseName    = [System.IO.Path]::GetFileNameWithoutExtension($InputFile) -replace '_part\d+$', ''
$script:LogFile = Join-Path $logDir ($logBaseName + "_decode_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
$modeLabel      = if ($VerifyOnly) { "VERIFICATION" } else { "DECODAGE" }
Write-Log "=== ConvertFrom-FolderArchive - $modeLabel ==="
Write-Log "Archive : $InputFile"
Write-Log "Parties : $($partFiles.Count)"

Write-Host ""
Write-Host "Archive : $InputFile"
Write-Host "Parties : $($partFiles.Count)"
Write-Host "Sortie  : $OutputFolder"
Write-Host ""

# -----------------------------------------------
# Confirmation si dossier de sortie non vide
# -----------------------------------------------

if (-not $VerifyOnly -and (Test-Path $OutputFolder) -and @(Get-ChildItem $OutputFolder -Force).Count -gt 0) {
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Le dossier de destination n'est pas vide :`n$OutputFolder`n`nContinuer et potentiellement ecraser des fichiers ?",
        "Confirmation", "YesNo", "Warning")
    if ($confirm -ne "Yes") { Write-Host "Annule."; exit 0 }
}

if (-not $VerifyOnly -and -not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

# -----------------------------------------------
# Decodage
# -----------------------------------------------

# Detection chiffrement sur la premiere partie
$firstLines   = @(Get-Content -Path ([string]$partFiles[0]) -Encoding UTF8 -TotalCount 10)
$isEncrypted  = @($firstLines | Where-Object { $_ -match "^ENCRYPTED=true$" }).Count -gt 0
if (@($firstLines | Where-Object { $_ -eq "###ARCHIVE_HEADER###" }).Count -eq 0) {
    $isEncrypted = $true
}

$versionLine = @($firstLines | Where-Object { $_ -match "^VERSION=" }) | Select-Object -First 1
$version     = if ($versionLine) { $versionLine -replace "VERSION=", "" } else { "?" }

Write-Host "Version archive : $version"
Write-Host "Chiffrement     : $(if ($isEncrypted) { "Oui" } else { "Non" })"
Write-Host ""
Write-Log "Version archive : $version"
Write-Log "Chiffrement     : $(if ($isEncrypted) { "Oui" } else { "Non" })"
if ($VerifyOnly) { Write-Log "Mode            : Verification seule" }

$Password = $null
if ($isEncrypted) {
    $Password = Show-PasswordDialog
    if (-not $Password) { Write-Host "Annule."; exit 0 }
}

$totalFiles = 0
$errorList  = [System.Collections.Generic.List[string]]::new()
$totalBytes = 0
$startTime  = Get-Date

foreach ($partFile in $partFiles) {
    Write-Host "Traitement : $(Split-Path $partFile -Leaf)"

    if ($isEncrypted) {
        $rawB64    = [System.IO.File]::ReadAllText([string]$partFile).Trim()
        $encrypted = [Convert]::FromBase64String($rawB64)
        $decrypted = Unprotect-Data -Data $encrypted -Password $Password
        if (-not $decrypted) {
            [System.Windows.Forms.MessageBox]::Show(
                "Mot de passe incorrect ou fichier corrompu.`n`n$partFile",
                "Erreur de dechiffrement", "OK", "Error")
            exit 1
        }
        $lines = @([System.Text.Encoding]::UTF8.GetString($decrypted) -split "`r?`n")
    } else {
        $lines = @(Get-Content -Path ([string]$partFile) -Encoding UTF8)
    }

    $fc = [ref]$totalFiles
    $el = [ref]$errorList
    $bc = [ref]$totalBytes
    ConvertFrom-ArchiveLines -Lines ([string[]]$lines) -OutputFolder $OutputFolder -FileCount $fc -ErrorList $el -TotalBytes $bc -VerifyMode $VerifyOnly.IsPresent
    $totalFiles = $fc.Value
    $errorList  = $el.Value
    $totalBytes = $bc.Value
}

# Effacement du mot de passe en memoire
$Password = $null

# -----------------------------------------------
# Resume
# -----------------------------------------------

$elapsed    = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$restoredMB = [math]::Round($totalBytes / 1MB, 2)
$totalErrors = $errorList.Count
$status     = if ($totalErrors -eq 0) { "Succes complet" } else { "$totalErrors erreur(s)" }

Write-Log "=== Termine : $totalFiles fichier(s) OK, $totalErrors erreur(s), ${elapsed}s ==="

$actionLabel = if ($VerifyOnly) { "Verification terminee" } else { "Restauration terminee" }
$summary  = "$actionLabel - $status`n`n"
$summary += "Parties traitees  : $($partFiles.Count)`n"
if ($VerifyOnly) {
    $summary += "Fichiers verifies : $totalFiles`n"
} else {
    $summary += "Fichiers restaures: $totalFiles`n"
    $summary += "Donnees restaurees: $restoredMB Mo`n"
}
$summary += "Erreurs           : $totalErrors`n"
$summary += "Duree             : ${elapsed}s`n"
if (-not $VerifyOnly) { $summary += "`nDossier : $OutputFolder`n" }
$summary += "Log     : $(Split-Path $script:LogFile -Leaf)"

if ($totalErrors -gt 0) {
    $summary += "`n`n--- Fichiers en erreur ---`n"
    foreach ($err in $errorList) { $summary += "$err`n" }
}

Write-Host ""
Write-Host $summary

$icon = if ($totalErrors -eq 0) { "Information" } else { "Warning" }
[System.Windows.Forms.MessageBox]::Show($summary, "Decodage termine", "OK", $icon)
