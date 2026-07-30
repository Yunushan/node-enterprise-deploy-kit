function Get-AppPackagePolicyInteger {
    param(
        $Config,
        [string]$Name,
        [long]$Default,
        [long]$Minimum,
        [long]$Maximum
    )

    $value = $Default
    if ($Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name -and
        -not [string]::IsNullOrWhiteSpace([string]$Config.$Name)) {
        if (-not [long]::TryParse([string]$Config.$Name, [ref]$value)) {
            throw "$Name must be an integer between $Minimum and $Maximum."
        }
    }
    if ($value -lt $Minimum -or $value -gt $Maximum) {
        throw "$Name must be an integer between $Minimum and $Maximum."
    }
    return $value
}

function Convert-AppPackageMiBToBytes {
    param([long]$MiB, [string]$Name)

    $bytes = [decimal]$MiB * 1048576
    if ($bytes -gt [long]::MaxValue) {
        throw "$Name is too large to convert safely to bytes."
    }
    return [long]$bytes
}

function Get-AppPackageSafetyPolicy {
    param($Config)

    $maxArchiveSizeMiB = Get-AppPackagePolicyInteger $Config "PackageMaxArchiveSizeMB" 2048 1 8388608
    $maxExtractedSizeMiB = Get-AppPackagePolicyInteger $Config "PackageMaxExtractedSizeMB" 8192 1 8388608
    $maxEntryCount = Get-AppPackagePolicyInteger $Config "PackageMaxEntryCount" 200000 1 10000000
    $maxCompressionRatio = Get-AppPackagePolicyInteger $Config "PackageMaxCompressionRatio" 200 1 1000000
    $minimumFreeSpaceMiB = Get-AppPackagePolicyInteger $Config "PackageMinimumFreeSpaceMB" 1024 0 8388608

    return [pscustomobject]@{
        MaxArchiveSizeBytes = Convert-AppPackageMiBToBytes $maxArchiveSizeMiB "PackageMaxArchiveSizeMB"
        MaxExtractedSizeBytes = Convert-AppPackageMiBToBytes $maxExtractedSizeMiB "PackageMaxExtractedSizeMB"
        MaxEntryCount = $maxEntryCount
        MaxCompressionRatio = $maxCompressionRatio
        MinimumFreeSpaceBytes = Convert-AppPackageMiBToBytes $minimumFreeSpaceMiB "PackageMinimumFreeSpaceMB"
    }
}

function Test-AppPackageSafeArchiveEntryName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $normalized = $Name -replace "\\", "/"
    if ($normalized.StartsWith("/") -or $normalized -match '^[A-Za-z]:') { return $false }
    $parts = @($normalized.Split("/") | Where-Object { $_ -ne "" })
    if ($parts.Count -eq 0) { return $false }

    foreach ($part in $parts) {
        if ($part -eq "." -or $part -eq "..") { return $false }
        if ($part.EndsWith(" ") -or $part.EndsWith(".")) { return $false }
        if ($part.IndexOfAny([char[]]'<>:"|?*') -ge 0) { return $false }
        foreach ($character in $part.ToCharArray()) {
            if ([int]$character -lt 32) { return $false }
        }
        $deviceStem = ($part.Split(".")[0]).ToUpperInvariant()
        if ($deviceStem -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { return $false }
    }
    return $true
}

function Get-AppPackageUnsafeZipEntryType {
    param($Entry)

    $rawAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Entry.ExternalAttributes), 0)
    $unixFileType = (($rawAttributes -shr 16) -band 0xF000)
    if ($unixFileType -eq 0 -or $unixFileType -eq 0x4000 -or $unixFileType -eq 0x8000) {
        return ""
    }
    if ($unixFileType -eq 0xA000) { return "symlink" }
    return ("special Unix file type 0x{0:X4}" -f $unixFileType)
}

function Get-AppPackageZipSafetyInfo {
    param(
        [string]$Path,
        $Policy
    )

    $package = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([long]$package.Length -gt [long]$Policy.MaxArchiveSizeBytes) {
        throw "Application package exceeds PackageMaxArchiveSizeMB ($($Policy.MaxArchiveSizeBytes) bytes allowed)."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($package.FullName)
    $entryNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [long]$entryCount = 0
    [decimal]$totalExtractedBytes = 0
    [decimal]$totalCompressedBytes = 0

    try {
        foreach ($entry in $zip.Entries) {
            $entryCount++
            if ($entryCount -gt [long]$Policy.MaxEntryCount) {
                throw "Application package exceeds PackageMaxEntryCount ($($Policy.MaxEntryCount) entries allowed)."
            }
            if (-not (Test-AppPackageSafeArchiveEntryName $entry.FullName)) {
                throw "Unsafe archive entry path detected: $($entry.FullName)"
            }

            $normalizedName = (($entry.FullName -replace "\\", "/").TrimEnd("/"))
            if (-not $entryNames.Add($normalizedName)) {
                throw "Duplicate or case-colliding archive entry detected: $($entry.FullName)"
            }
            $unsafeType = Get-AppPackageUnsafeZipEntryType $entry
            if (-not [string]::IsNullOrWhiteSpace($unsafeType)) {
                throw "Unsafe archive entry type detected: $($entry.FullName) is $unsafeType. Symlinks and special files are intentionally unsupported in deployment archives."
            }

            $totalExtractedBytes += [decimal]$entry.Length
            $totalCompressedBytes += [decimal]$entry.CompressedLength
            if ($totalExtractedBytes -gt [decimal]$Policy.MaxExtractedSizeBytes) {
                throw "Application package exceeds PackageMaxExtractedSizeMB ($($Policy.MaxExtractedSizeBytes) bytes allowed)."
            }
            if ([long]$entry.Length -gt 0) {
                $compressedLength = if ([long]$entry.CompressedLength -gt 0) { [long]$entry.CompressedLength } else { 1L }
                if ([decimal]$entry.Length -gt ([decimal]$compressedLength * [decimal]$Policy.MaxCompressionRatio)) {
                    throw "Archive entry exceeds PackageMaxCompressionRatio: $($entry.FullName)"
                }
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    $packageRatioBase = if ([long]$package.Length -gt 0) { [long]$package.Length } else { 1L }
    if ($totalExtractedBytes -gt ([decimal]$packageRatioBase * [decimal]$Policy.MaxCompressionRatio)) {
        throw "Application package exceeds PackageMaxCompressionRatio ($($Policy.MaxCompressionRatio):1 allowed)."
    }

    return [pscustomobject]@{
        PackageSizeBytes = [long]$package.Length
        ExtractedSizeBytes = [long]$totalExtractedBytes
        CompressedEntryBytes = [long]$totalCompressedBytes
        EntryCount = $entryCount
    }
}

function Assert-AppPackageExtractedTreeSafe {
    param(
        [string]$RootPath,
        $Policy
    )

    [long]$entryCount = 0
    [decimal]$totalBytes = 0
    foreach ($item in Get-ChildItem -LiteralPath $RootPath -Force -Recurse -ErrorAction Stop) {
        $entryCount++
        if ($entryCount -gt [long]$Policy.MaxEntryCount) {
            throw "Extracted package exceeds PackageMaxEntryCount ($($Policy.MaxEntryCount) entries allowed)."
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe extracted reparse point detected: $($item.FullName). Symlinks and junctions are intentionally unsupported in deployment archives."
        }
        if (-not $item.PSIsContainer) {
            $totalBytes += [decimal]$item.Length
            if ($totalBytes -gt [decimal]$Policy.MaxExtractedSizeBytes) {
                throw "Extracted package exceeds PackageMaxExtractedSizeMB ($($Policy.MaxExtractedSizeBytes) bytes allowed)."
            }
        }
    }

    return [pscustomobject]@{
        ExtractedSizeBytes = [long]$totalBytes
        EntryCount = $entryCount
    }
}

function Get-AppPackageTreeSizeBytes {
    param([string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath)) { return 0L }
    [decimal]$totalBytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $RootPath -Force -Recurse -File -ErrorAction Stop) {
        $totalBytes += [decimal]$file.Length
        if ($totalBytes -gt [long]::MaxValue) {
            throw "Existing AppDirectory is too large to measure safely."
        }
    }
    return [long]$totalBytes
}

function Get-AppPackageVolumeInfo {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Could not determine the filesystem root for package capacity check: $Path"
    }
    try {
        $drive = [System.IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) { throw "Filesystem is not ready." }
        return [pscustomobject]@{
            Root = $root
            AvailableFreeSpace = [long]$drive.AvailableFreeSpace
        }
    }
    catch {
        throw "Could not determine available disk space for '$Path'. $($_.Exception.Message)"
    }
}

function Assert-AppPackageVolumeCapacity {
    param(
        $Volume,
        [decimal]$WorkloadBytes,
        [long]$MinimumFreeSpaceBytes,
        [string]$Context
    )

    $requiredBytes = $WorkloadBytes + [decimal]$MinimumFreeSpaceBytes
    if ($requiredBytes -gt [long]::MaxValue) {
        throw "Required disk capacity is too large to represent safely for $Context."
    }
    if ([decimal]$Volume.AvailableFreeSpace -lt $requiredBytes) {
        throw "Insufficient free disk space for $Context on '$($Volume.Root)': $([long]$requiredBytes) bytes required, $($Volume.AvailableFreeSpace) bytes available."
    }
}

function Assert-AppPackageDeploymentCapacity {
    param(
        $ArchiveInfo,
        $Policy,
        [string]$WorkPath,
        [string]$AppDirectory,
        [string]$BackupDirectory,
        [switch]$PackageAlreadyStaged
    )

    $workVolume = Get-AppPackageVolumeInfo $WorkPath
    $appVolume = Get-AppPackageVolumeInfo $AppDirectory
    $backupVolume = Get-AppPackageVolumeInfo $BackupDirectory

    [decimal]$workWorkload = [long]$ArchiveInfo.ExtractedSizeBytes
    if (-not $PackageAlreadyStaged) {
        $workWorkload += [long]$ArchiveInfo.PackageSizeBytes
    }
    [decimal]$appWorkload = [long]$ArchiveInfo.ExtractedSizeBytes
    [decimal]$backupWorkload = 0
    if (-not $backupVolume.Root.Equals($appVolume.Root, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $AppDirectory)) {
        $backupWorkload = Get-AppPackageTreeSizeBytes $AppDirectory
    }

    if ($appVolume.Root.Equals($workVolume.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $workWorkload += $appWorkload
        $appWorkload = 0
    }
    if ($backupWorkload -gt 0) {
        if ($backupVolume.Root.Equals($workVolume.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $workWorkload += $backupWorkload
            $backupWorkload = 0
        } elseif ($backupVolume.Root.Equals($appVolume.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $appWorkload += $backupWorkload
            $backupWorkload = 0
        }
    }

    Assert-AppPackageVolumeCapacity $workVolume $workWorkload $Policy.MinimumFreeSpaceBytes "package staging and extraction"
    if ($appWorkload -gt 0) {
        Assert-AppPackageVolumeCapacity $appVolume $appWorkload $Policy.MinimumFreeSpaceBytes "application installation"
    }
    if ($backupWorkload -gt 0) {
        Assert-AppPackageVolumeCapacity $backupVolume $backupWorkload $Policy.MinimumFreeSpaceBytes "application backup"
    }
}
