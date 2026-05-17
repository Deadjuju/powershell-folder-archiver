#Requires -Version 5.0
<#
.SYNOPSIS
    Encode un dossier en archive .txt base64.
.DESCRIPTION
    Encode tous les fichiers d'un dossier en base64, les regroupe dans un ou plusieurs
    fichiers .txt avec verification d'integrite SHA256.
    Permet d'exclure des fichiers et dossiers via une interface graphique.
.PARAMETER SourceFolder
    Dossier source a encoder.
.PARAMETER OutputFile
    Fichier de sortie (sera suffixe _partN si decoupage).
.PARAMETER MaxSizeMB
    Taille max par partie en Mo (defaut : 20).
.EXAMPLE
    .\ConvertTo-FolderArchive.ps1
    .\ConvertTo-FolderArchive.ps1 -SourceFolder "C:\MonDossier" -OutputFile "C:\archive.txt" -MaxSizeMB 10
#>

param(
    [string]$SourceFolder = "",
    [string]$OutputFile   = "",
    [int]$MaxSizeMB       = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------------------------
# Fonctions GUI
# -----------------------------------------------

function Show-FolderPicker {
    param([string]$Description)
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description         = $Description
    $d.ShowNewFolderButton = $false
    if ($d.ShowDialog() -eq "OK") { return $d.SelectedPath }
    return $null
}

function Show-SaveFilePicker {
    param([string]$DefaultName = "archive.txt")
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter   = "Fichiers texte (*.txt)|*.txt|Tous les fichiers (*.*)|*.*"
    $d.FileName = $DefaultName
    $d.Title    = "Choisir l'emplacement du fichier de sortie"
    if ($d.ShowDialog() -eq "OK") { return $d.FileName }
    return $null
}


function Show-PasswordDialog {
    param([string]$Title = "Chiffrement (optionnel)")

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = $Title
    $form.Size            = New-Object System.Drawing.Size(420, 260)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $lbl1 = New-Object System.Windows.Forms.Label
    $lbl1.Text     = "Mot de passe (laisser vide = pas de chiffrement) :"
    $lbl1.Location = New-Object System.Drawing.Point(20, 20)
    $lbl1.Size     = New-Object System.Drawing.Size(370, 20)

    $txt1 = New-Object System.Windows.Forms.TextBox
    $txt1.Location              = New-Object System.Drawing.Point(20, 48)
    $txt1.Size                  = New-Object System.Drawing.Size(370, 25)
    $txt1.UseSystemPasswordChar = $true

    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text     = "Confirmer le mot de passe :"
    $lbl2.Location = New-Object System.Drawing.Point(20, 90)
    $lbl2.Size     = New-Object System.Drawing.Size(370, 20)

    $txt2 = New-Object System.Windows.Forms.TextBox
    $txt2.Location              = New-Object System.Drawing.Point(20, 114)
    $txt2.Size                  = New-Object System.Drawing.Size(370, 25)
    $txt2.UseSystemPasswordChar = $true

    $lblErr = New-Object System.Windows.Forms.Label
    $lblErr.ForeColor = [System.Drawing.Color]::Red
    $lblErr.Location  = New-Object System.Drawing.Point(20, 148)
    $lblErr.Size      = New-Object System.Drawing.Size(370, 20)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text     = "OK"
    $btn.Location = New-Object System.Drawing.Point(155, 180)
    $btn.Size     = New-Object System.Drawing.Size(100, 30)
    $btn.Add_Click({
        if ($txt1.Text -ne $txt2.Text) {
            $lblErr.Text = "Les mots de passe ne correspondent pas."
        } else {
            $form.DialogResult = "OK"
            $form.Close()
        }
    })
    $form.AcceptButton = $btn
    $form.Controls.AddRange(@($lbl1, $txt1, $lbl2, $txt2, $lblErr, $btn))

    $r = $form.ShowDialog()
    if ($r -eq "OK") { return $txt1.Text }
    return $null
}

function Add-TreeNodes {
    param(
        [System.Windows.Forms.TreeNodeCollection]$Nodes,
        [string]$Path,
        [bool]$Recursive = $false
    )
    $dirs  = @(Get-ChildItem -Path $Path -Directory | Sort-Object Name)
    $files = @(Get-ChildItem -Path $Path -File      | Sort-Object Name)

    foreach ($d in $dirs) {
        $node = New-Object System.Windows.Forms.TreeNode
        $node.Text = $d.Name
        $node.Tag  = $d.FullName
        $node.ImageIndex         = 0
        $node.SelectedImageIndex = 0
        if ($Recursive) {
            Add-TreeNodes -Nodes $node.Nodes -Path $d.FullName -Recursive $true
        } else {
            # Noeud fantome pour afficher le "+" sans tout charger
            $hasChildren = @(Get-ChildItem -Path $d.FullName).Count -gt 0
            if ($hasChildren) {
                $phantom = New-Object System.Windows.Forms.TreeNode
                $phantom.Text = "..."
                $phantom.Tag  = $null
                $node.Nodes.Add($phantom) | Out-Null
            }
        }
        $Nodes.Add($node) | Out-Null
    }
    foreach ($f in $files) {
        $node = New-Object System.Windows.Forms.TreeNode
        $node.Text = $f.Name
        $node.Tag  = $f.FullName
        $node.ImageIndex         = 1
        $node.SelectedImageIndex = 1
        $Nodes.Add($node) | Out-Null
    }
}

function Expand-TreeNode {
    param([System.Windows.Forms.TreeNode]$Node)
    if ($Node.Nodes.Count -eq 1 -and $null -eq $Node.Nodes[0].Tag) {
        $Node.Nodes.Clear()
        Add-TreeNodes -Nodes $Node.Nodes -Path ([string]$Node.Tag) -Recursive $false
    }
}

function Set-NodeChecked {
    param([System.Windows.Forms.TreeNode]$Node, [bool]$Checked)
    $Node.Checked = $Checked
    foreach ($child in $Node.Nodes) {
        Set-NodeChecked -Node $child -Checked $Checked
    }
}

function Get-CheckedPaths {
    param([System.Windows.Forms.TreeNodeCollection]$Nodes)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($node in $Nodes) {
        if ($node.Checked) {
            $result.Add([string]$node.Tag)
        } else {
            foreach ($p in (Get-CheckedPaths -Nodes $node.Nodes)) {
                $result.Add($p)
            }
        }
    }
    return $result
}

function Read-ArchiveIgnore {
    param([string]$RootFolder)
    $ignorePath = Join-Path $RootFolder ".archiveignore"
    if (-not (Test-Path $ignorePath)) { return @() }

    $patterns = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-Content $ignorePath -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith("#")) {
            $patterns.Add($trimmed)
        }
    }
    return @($patterns)
}

function Test-MatchesIgnorePattern {
    param([string]$RelativePath, [string[]]$Patterns)
    $normalized = $RelativePath -replace '\\', '/'
    foreach ($pattern in $Patterns) {
        $p = $pattern -replace '\\', '/'
        $p = $p.TrimEnd('/')
        # Correspondance exacte ou prefixe de dossier
        if ($normalized -eq $p -or $normalized.StartsWith($p + '/')) { return $true }
        # Wildcard simple sur le nom de fichier (ex: *.log, Runtime)
        if ($p -notmatch '[/]') {
            $fileName = Split-Path $normalized -Leaf
            $dirName  = ($normalized -split '/')[0]
            if ($fileName -like $p -or $dirName -like $p) { return $true }
        }
        # Wildcard avec chemin (ex: **/obj, Tools/*)
        $regexPattern = '^' + ([regex]::Escape($p) -replace '\\\*\\\*','.*' -replace '\\\*','[^/]*') + '(/.*)?$'
        if ($normalized -match $regexPattern) { return $true }
    }
    return $false
}

function Show-ExclusionDialog {
    param([string]$RootFolder, [string[]]$IgnorePatterns = @())

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "Exclure des elements"
    $form.Size            = New-Object System.Drawing.Size(560, 620)
    $form.StartPosition   = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.MinimumSize     = New-Object System.Drawing.Size(400, 400)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = "Cochez les fichiers et dossiers a EXCLURE de l'archive :"
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size     = New-Object System.Drawing.Size(520, 20)

    $lblRoot = New-Object System.Windows.Forms.Label
    $lblRoot.Text      = $RootFolder
    $lblRoot.Location  = New-Object System.Drawing.Point(12, 34)
    $lblRoot.Size      = New-Object System.Drawing.Size(520, 18)
    $lblRoot.ForeColor = [System.Drawing.Color]::Gray
    $lblRoot.Font      = New-Object System.Drawing.Font("Segoe UI", 8)

    $ignoreFile = Join-Path $RootFolder ".archiveignore"
    $lblIgnore = New-Object System.Windows.Forms.Label
    if (Test-Path $ignoreFile) {
        $lblIgnore.Text      = ".archiveignore detecte - elements pre-coches"
        $lblIgnore.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $lblIgnore.Text      = "Aucun .archiveignore trouve dans ce dossier"
        $lblIgnore.ForeColor = [System.Drawing.Color]::Gray
    }
    $lblIgnore.Location = New-Object System.Drawing.Point(12, 52)
    $lblIgnore.Size     = New-Object System.Drawing.Size(520, 18)
    $lblIgnore.Font     = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)

    $tv = New-Object System.Windows.Forms.TreeView
    $tv.Location         = New-Object System.Drawing.Point(12, 74)
    $tv.Size             = New-Object System.Drawing.Size(518, 460)
    $tv.CheckBoxes       = $true
    $tv.ShowLines        = $true
    $tv.ShowPlusMinus    = $true
    $tv.ShowRootLines    = $true
    $tv.Scrollable       = $true
    $tv.Anchor           = [System.Windows.Forms.AnchorStyles]::Top -bor `
                           [System.Windows.Forms.AnchorStyles]::Bottom -bor `
                           [System.Windows.Forms.AnchorStyles]::Left -bor `
                           [System.Windows.Forms.AnchorStyles]::Right

    Write-Host "Chargement de l'arborescence..." -ForegroundColor Cyan
    # Chargement initial : premier niveau seulement (lazy)
    Add-TreeNodes -Nodes $tv.Nodes -Path $RootFolder -Recursive $false

    # Pre-cocher les elements .archiveignore :
    # on charge recursivement tout l'arbre une seule fois pour le matching
    if ($IgnorePatterns.Count -gt 0) {
        Write-Host "Application des exclusions .archiveignore..." -ForegroundColor Cyan
        $script:isUpdating = $true
        # Charger l'arbre complet pour le pre-cochage
        Add-TreeNodes -Nodes $tv.Nodes -Path $RootFolder -Recursive $true
        $tv.Nodes.Clear()
        Add-TreeNodes -Nodes $tv.Nodes -Path $RootFolder -Recursive $true

        $allNodes = [System.Collections.Generic.Queue[System.Windows.Forms.TreeNode]]::new()
        foreach ($n in $tv.Nodes) { $allNodes.Enqueue($n) }
        while ($allNodes.Count -gt 0) {
            $node = $allNodes.Dequeue()
            $fullPath = [string]$node.Tag
            $rel = $fullPath.Substring($RootFolder.Length).TrimStart([char]92)
            if (Test-MatchesIgnorePattern -RelativePath $rel -Patterns $IgnorePatterns) {
                Set-NodeChecked -Node $node -Checked $true
            } else {
                foreach ($child in $node.Nodes) { $allNodes.Enqueue($child) }
            }
        }
        $script:isUpdating = $false
    }

    # Lazy loading au depliage pour les noeuds non encore charges
    $tv.Add_BeforeExpand({
        param($s, $e)
        Expand-TreeNode -Node $e.Node
    })

    # Propagation du coche vers les enfants
    $script:isUpdating = $false
    $tv.Add_AfterCheck({
        param($s, $e)
        if (-not $script:isUpdating) {
            $script:isUpdating = $true
            Set-NodeChecked -Node $e.Node -Checked $e.Node.Checked
            $script:isUpdating = $false
        }
    })

    $pnlBtn = New-Object System.Windows.Forms.Panel
    $pnlBtn.Height = 44
    $pnlBtn.Dock   = [System.Windows.Forms.DockStyle]::Bottom

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text     = "Tout cocher"
    $btnAll.Location = New-Object System.Drawing.Point(12, 8)
    $btnAll.Size     = New-Object System.Drawing.Size(110, 28)
    $btnAll.Add_Click({
        $script:isUpdating = $true
        foreach ($node in $tv.Nodes) { Set-NodeChecked -Node $node -Checked $true }
        $script:isUpdating = $false
    })

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text     = "Tout decocher"
    $btnNone.Location = New-Object System.Drawing.Point(128, 8)
    $btnNone.Size     = New-Object System.Drawing.Size(110, 28)
    $btnNone.Add_Click({
        $script:isUpdating = $true
        foreach ($node in $tv.Nodes) { Set-NodeChecked -Node $node -Checked $false }
        $script:isUpdating = $false
    })

    $btnExpand = New-Object System.Windows.Forms.Button
    $btnExpand.Text     = "Tout developper"
    $btnExpand.Location = New-Object System.Drawing.Point(244, 8)
    $btnExpand.Size     = New-Object System.Drawing.Size(120, 28)
    $btnExpand.Add_Click({
        $script:isUpdating = $true
        $queue = [System.Collections.Generic.Queue[System.Windows.Forms.TreeNode]]::new()
        foreach ($n in $tv.Nodes) { $queue.Enqueue($n) }
        while ($queue.Count -gt 0) {
            $n = $queue.Dequeue()
            Expand-TreeNode -Node $n
            foreach ($child in $n.Nodes) { $queue.Enqueue($child) }
        }
        $script:isUpdating = $false
        $tv.ExpandAll()
    })

    $btnCollapse = New-Object System.Windows.Forms.Button
    $btnCollapse.Text     = "Tout replier"
    $btnCollapse.Location = New-Object System.Drawing.Point(370, 8)
    $btnCollapse.Size     = New-Object System.Drawing.Size(100, 28)
    $btnCollapse.Add_Click({ $tv.CollapseAll() })

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text         = "Continuer"
    $btnOK.Size         = New-Object System.Drawing.Size(100, 28)
    $btnOK.DialogResult = "OK"
    $btnOK.Anchor       = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $form.AcceptButton  = $btnOK

    $pnlBtn.Controls.AddRange(@($btnAll, $btnNone, $btnExpand, $btnCollapse, $btnOK))

    $form.Add_Shown({ $btnOK.Location = New-Object System.Drawing.Point(($pnlBtn.Width - 112), 8) })
    $form.Add_Resize({ $btnOK.Location = New-Object System.Drawing.Point(($pnlBtn.Width - 112), 8) })

    $form.Controls.AddRange(@($lbl, $lblRoot, $lblIgnore, $tv, $pnlBtn))
    $r = $form.ShowDialog()

    if ($r -ne "OK") { return $null }

    return @(Get-CheckedPaths -Nodes $tv.Nodes)
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

function Get-ContentHash {
    param([string]$Path)
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    $hash   = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "").ToLower()
    $stream.Close()
    $sha.Dispose()
    return $hash
}


function Get-DerivedKeys {
    param([string]$Password, [byte[]]$Salt)
    # PBKDF2-SHA256, 600 000 iterations, sortie 64 bytes
    # 32 bytes cle AES + 32 bytes cle HMAC
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

function Protect-Data {
    param([byte[]]$Data, [string]$Password)

    # Generer sel et IV aleatoires
    $rng  = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $salt = New-Object byte[] 32
    $iv   = New-Object byte[] 16
    $rng.GetBytes($salt)
    $rng.GetBytes($iv)
    $rng.Dispose()

    # Deriver les cles
    $keys = Get-DerivedKeys -Password $Password -Salt $salt

    # Chiffrement AES-256-CBC
    $aes           = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize   = 256
    $aes.BlockSize = 128
    $aes.Mode      = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding   = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key       = $keys.AesKey
    $aes.IV        = $iv

    $ms = New-Object System.IO.MemoryStream
    $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $aes.CreateEncryptor(), "Write")
    $cs.Write($Data, 0, $Data.Length)
    $cs.FlushFinalBlock()
    $cipherText = $ms.ToArray()
    $aes.Dispose()

    # VERSION (1 byte) = 0x01
    $version = [byte]0x01

    # HMAC-SHA256 sur VERSION + SEL + IV + CIPHERTEXT (Encrypt-then-MAC)
    $hmacInput = [byte[]]@($version) + $salt + $iv + $cipherText
    $hmac      = [System.Security.Cryptography.HMACSHA256]::new()
    $hmac.Key  = $keys.HmacKey
    $mac       = $hmac.ComputeHash($hmacInput)
    $hmac.Dispose()

    # Format final : VERSION(1) + SEL(32) + IV(16) + MAC(32) + CIPHERTEXT
    return [byte[]]@($version) + $salt + $iv + $mac + $cipherText
}

function Export-Part {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$BasePath,
        [int]$Index,
        [string]$Password = ""
    )
    $dir      = [System.IO.Path]::GetDirectoryName($BasePath)
    $nameBase = [System.IO.Path]::GetFileNameWithoutExtension($BasePath)
    $ext      = [System.IO.Path]::GetExtension($BasePath)
    $partPath = Join-Path $dir ($nameBase + "_part" + $Index + $ext)

    if ($Password.Length -gt 0) {
        $rawBytes  = [System.Text.Encoding]::UTF8.GetBytes($Lines -join "`n")
        $encrypted = Protect-Data -Data $rawBytes -Password $Password
        $b64       = [Convert]::ToBase64String($encrypted)
        [System.IO.File]::WriteAllText($partPath, $b64, [System.Text.Encoding]::UTF8)
    } else {
        Set-Content -Path $partPath -Value $Lines -Encoding UTF8
    }
    return $partPath
}

function Export-ArchiveParts {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$BasePath,
        [long]$MaxBytes,
        [string]$Password = ""
    )
    $partIndex    = 1
    $currentLines = [System.Collections.Generic.List[string]]::new()
    $currentSize  = 0
    $partFiles    = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $Lines) {
        $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($line + "`n")
        if ($currentSize + $lineBytes -gt $MaxBytes -and $currentLines.Count -gt 0) {
            $partFiles.Add((Export-Part -Lines $currentLines -BasePath $BasePath -Index $partIndex -Password $Password))
            $partIndex++
            $currentLines = [System.Collections.Generic.List[string]]::new()
            $currentSize  = 0
        }
        $currentLines.Add($line)
        $currentSize += $lineBytes
    }
    if ($currentLines.Count -gt 0) {
        $partFiles.Add((Export-Part -Lines $currentLines -BasePath $BasePath -Index $partIndex -Password $Password))
    }
    return [PSCustomObject]@{ Files = $partFiles; Total = $partIndex }
}

function Test-IsExcluded {
    param([string]$FullPath, [string[]]$ExcludedPaths)
    foreach ($ex in $ExcludedPaths) {
        if ($FullPath -eq $ex -or $FullPath.StartsWith($ex + "\")) {
            return $true
        }
    }
    return $false
}

# -----------------------------------------------
# Saisie des parametres
# -----------------------------------------------

if (-not $SourceFolder -or -not (Test-Path $SourceFolder)) {
    $SourceFolder = Show-FolderPicker -Description "Selectionner le dossier a archiver"
    if (-not $SourceFolder) { Write-Host "Annule."; exit 0 }
}

if (-not $OutputFile) {
    $suggested  = (Split-Path $SourceFolder -Leaf) + "_archive.txt"
    $OutputFile = Show-SaveFilePicker -DefaultName $suggested
    if (-not $OutputFile) { Write-Host "Annule."; exit 0 }
}

# -----------------------------------------------
# Scan du dossier
# -----------------------------------------------

$MaxBytes       = [long]$MaxSizeMB * 1MB
$resolvedSource = (Resolve-Path $SourceFolder).Path

# Initialisation du fichier de log (meme dossier que l'archive)
$logDir        = [System.IO.Path]::GetDirectoryName($OutputFile)
$logBaseName   = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
$script:LogFile = Join-Path $logDir ($logBaseName + "_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
Write-Log "=== ConvertTo-FolderArchive ==="
Write-Log "Source  : $SourceFolder"
Write-Log "Sortie  : $OutputFile"
Write-Log "MaxSize : $MaxSizeMB Mo"

$Password  = Show-PasswordDialog
if ($null -eq $Password) { Write-Host "Annule."; exit 0 }
$Encrypted = ($Password.Length -gt 0)

$ignorePatterns = @(Read-ArchiveIgnore -RootFolder $resolvedSource)
if ($ignorePatterns.Count -gt 0) {
    Write-Host "  .archiveignore : $($ignorePatterns.Count) pattern(s) charges"
}
$excluded = Show-ExclusionDialog -RootFolder $resolvedSource -IgnorePatterns $ignorePatterns
if ($null -eq $excluded) { Write-Host "Annule."; exit 0 }

$excludedPaths = [string[]]$excluded

if ($excludedPaths.Count -gt 0) {
    Write-Host ""
    Write-Host "Elements exclus :"
    foreach ($ex in $excludedPaths) {
        Write-Host "  - $ex"
        Write-Log "Exclu : $ex" "EXCLU"
    }
}
$allFiles       = @(Get-ChildItem -Path $resolvedSource -Recurse -File)
$files          = @($allFiles | Where-Object { -not (Test-IsExcluded -FullPath $_.FullName -ExcludedPaths $excludedPaths) })

if ($files.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "Aucun fichier a encoder apres exclusions.",
        "Dossier vide", "OK", "Warning")
    exit 1
}

$totalSize   = [long](($files | Measure-Object -Property Length -Sum).Sum)
$totalSizeMB = [math]::Round($totalSize / 1MB, 2)
$excluded_count = $allFiles.Count - $files.Count
$encLabel = if ($Encrypted) { "Oui (AES-256-CBC + HMAC-SHA256)" } else { "Non" }

Write-Host ""
Write-Host "Dossier     : $resolvedSource"
Write-Host "Fichiers    : $($files.Count) ($totalSizeMB Mo)"
if ($excluded_count -gt 0) { Write-Host "Exclus      : $excluded_count fichier(s)" }
Write-Host "Chiffrement : $encLabel"
Write-Host "Sortie      : $OutputFile"
Write-Host ""

Write-Log "Fichiers a encoder : $($files.Count) ($totalSizeMB Mo)"
Write-Log "Fichiers exclus    : $excluded_count"
Write-Log "Chiffrement        : $encLabel"

# -----------------------------------------------
# Construction de l'archive
# -----------------------------------------------

$allLines = [System.Collections.Generic.List[string]]::new()
$encryptedFlag = if ($Encrypted) { "true" } else { "false" }
$allLines.Add("###ARCHIVE_HEADER###")
$allLines.Add("VERSION=3")
$allLines.Add("ENCRYPTED=$encryptedFlag")
$allLines.Add("SOURCE=$(Split-Path $resolvedSource -Leaf)")
$allLines.Add("DATE=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$allLines.Add("FILES=$($files.Count)")
$allLines.Add("###END_HEADER###")

$done       = 0
$encErrors  = 0

foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($resolvedSource.Length + 1)
    try {
        $bytes   = [System.IO.File]::ReadAllBytes($file.FullName)
        $encoded = [Convert]::ToBase64String($bytes)
        $hash    = Get-ContentHash -Path $file.FullName

        $allLines.Add("###FILE###$relativePath")
        $allLines.Add("HASH=$hash")
        $allLines.Add($encoded)
        $allLines.Add("###END###")

        $done++
        $pct = [int](($done / $files.Count) * 100)
        Write-Progress -Activity "Encodage en cours" -Status "$done/$($files.Count) : $relativePath" -PercentComplete $pct
        Write-Host ("  [{0,3}%] {1}" -f $pct, $relativePath)
        Write-Log "OK : $relativePath"
    } catch {
        $encErrors++
        Write-Host ("  [ERREUR] {0} : {1}" -f $relativePath, $_) -ForegroundColor Red
        Write-Log "ERREUR : $relativePath - $_" "ERREUR"
    }
}
Write-Progress -Activity "Encodage en cours" -Completed

# -----------------------------------------------
# Ecriture des parties
# -----------------------------------------------

Write-Host ""
Write-Host "Ecriture des fichiers..."
$result     = Export-ArchiveParts -Lines $allLines -BasePath $OutputFile -MaxBytes $MaxBytes -Password $Password
$partFiles  = $result.Files
$totalParts = $result.Total

# -----------------------------------------------
# Resume
# -----------------------------------------------

foreach ($f in $partFiles) { Write-Log "Partie creee : $(Split-Path $f -Leaf)" }
Write-Log "=== Termine : $done fichier(s) encode(s), $encErrors erreur(s), $totalParts partie(s) ==="

$summary  = "Archive creee avec succes !`n`n"
$summary += "Source          : $(Split-Path $resolvedSource -Leaf)`n"
$summary += "Fichiers encodes: $done / $($files.Count) ($totalSizeMB Mo)`n"
$summary += "Chiffrement     : $encLabel`n"
if ($excluded_count -gt 0) { $summary += "Exclus          : $excluded_count fichier(s)`n" }
if ($encErrors -gt 0)      { $summary += "Erreurs encode  : $encErrors`n" }
$summary += "Parties generees: $totalParts`n`n"
$summary += "Fichiers crees :`n"
foreach ($f in $partFiles) { $summary += "  - $(Split-Path $f -Leaf)`n" }

$summary += "`nLog : $(Split-Path $script:LogFile -Leaf)"
Write-Host ""
Write-Host $summary
# Effacement du mot de passe en memoire
$Password = $null

$icon = if ($encErrors -eq 0) { "Information" } else { "Warning" }
[System.Windows.Forms.MessageBox]::Show($summary, "Encodage termine", "OK", $icon)
