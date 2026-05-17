# powershell-folder-archiver

[![PowerShell 5.0+](https://img.shields.io/badge/PowerShell-5.0%2B-blue?logo=powershell)](https://microsoft.com/powershell)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-lightgrey?logo=windows)](https://microsoft.com)

A PowerShell toolkit to encode an entire folder into portable `.txt` files and restore it identically on the other end — with optional AES-256 encryption and integrity verification.

**Typical use cases:**
- Transferring folders by email when attachments are filtered (scripts, binaries, `.zip` files)
- Importing large folders onto restricted environments (VDI, air-gapped machines)
- Securely sending config or source files to a client with no shared file storage

---

## Contents

```
FolderArchiver/
├── ConvertTo-FolderArchive.ps1     # Encoding
├── ConvertFrom-FolderArchive.ps1   # Decoding
├── .archiveignore.template         # Exclusion patterns template
└── README.md
```

---

## Requirements

- Windows PowerShell 5.0 or later
- No external dependencies

---

## Usage

### Encoding

```powershell
.\ConvertTo-FolderArchive.ps1
```

The script opens the following dialogs in sequence:

1. **Folder picker** — select the folder to archive
2. **Output file picker** — choose the name and location of the generated `.txt` file
3. **Password dialog** — optional, leave empty to skip encryption
4. **Exclusion window** — check files and folders to exclude from the archive (auto pre-checked if a `.archiveignore` file is present at the root of the source folder)

Large folders are automatically split into multiple parts named `name_part1.txt`, `name_part2.txt`, etc. (default max size: 20 MB per part).

A timestamped log file is automatically created alongside the archive:
```
name_archive_20250731_143200.log
```

Parameters can also be passed directly:

```powershell
.\ConvertTo-FolderArchive.ps1 -SourceFolder "C:\MyFolder" -OutputFile "C:\archive.txt" -MaxSizeMB 10
```

### Decoding

```powershell
.\ConvertFrom-FolderArchive.ps1
```

The script opens the following dialogs in sequence:

1. **File picker** — select the first part of the archive (or the only file if single-part)
2. **Folder picker** — choose the restore destination
3. **Password dialog** — only if the archive is encrypted

Other parts (`_part2.txt`, `_part3.txt`...) are detected and processed automatically — just select `_part1.txt`.

A timestamped log file is automatically created alongside the archive.

```powershell
.\ConvertFrom-FolderArchive.ps1 -InputFile "C:\archive_part1.txt" -OutputFolder "C:\Restored"
```

### Verify-only mode

Validates the integrity of a received archive **without writing any file to disk**. All SHA256 hashes are verified and the result is written to a log.

```powershell
.\ConvertFrom-FolderArchive.ps1 -InputFile "C:\archive_part1.txt" -VerifyOnly
```

Useful to check that an archive has not been corrupted or altered (by an antivirus, mail client, etc.) before restoring it.

---

## Exclusion file `.archiveignore`

Place a `.archiveignore` file at the root of the folder to encode. It lists items to systematically exclude, following the same logic as `.gitignore`.

```gitignore
# Version control
.git

# Build outputs
bin
obj

# Specific deep subfolder
MyProject\Build\Output

# Wildcard on filename
*.log

# Wildcard on path
Tools\Results\*
```

Listed items are **automatically pre-checked** in the exclusion window and can be unchecked manually before encoding.

A ready-to-use template is available in `.archiveignore.template`.

> To create a dot-prefixed file on Windows:
> ```powershell
> Rename-Item .archiveignore.template .archiveignore
> ```

---

## Security

When a password is provided, each archive part is encrypted with:

| Component | Details |
|-----------|---------|
| Encryption | AES-256-CBC |
| Authentication | HMAC-SHA256 (Encrypt-then-MAC) |
| Key derivation | PBKDF2-SHA256, 600,000 iterations, 32-byte random salt |

Two separate keys are derived from the password: one for encryption, one for authentication. The password is never stored and is wiped from memory immediately after use.

The HMAC is verified **before** decryption. An incorrect password or corrupted file is detected immediately, without exposing the decryption oracle.

---

## Archive format

The archive is a plain text file (when not encrypted) structured as follows:

```
###ARCHIVE_HEADER###
VERSION=3
ENCRYPTED=false
SOURCE=MyFolder
DATE=2025-07-31 14:32:00
FILES=42
###END_HEADER###
###FILE###relative\path\to\file.txt
HASH=a3f2c1...
<base64-encoded content>
###END###
...
```

Each file includes a SHA256 hash verified on restore.

---

## Limitations

- **Locked files** — files held open exclusively by another process are skipped and reported in the log
- **Large files** — each file is loaded entirely into memory before encoding; files over ~1 GB may cause memory pressure
- **Long paths** — Windows MAX_PATH (260 chars) applies unless long path support is enabled via GPO
- **Mail transit** — some antivirus or mail clients may alter `.txt` attachments; use verify-only mode after receiving an archive to confirm integrity before restoring

---

## Contributing

Contributions are welcome. Please open an issue before submitting a pull request for significant changes.
