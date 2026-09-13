<#
.SYNOPSIS
  Push a large diff to a remote as a series of size-bounded commits, dodging
  GitHub's ~2 GiB compressed-pack-per-push limit.

.DESCRIPTION
  GitHub rejects any single push whose compressed pack exceeds 2 GiB
  ("remote: fatal: pack exceeds maximum allowed size (2.00 GiB)"). For a repo
  like this one, tracking the full game install, a normal update can easily
  blow past that in one commit.

  What it does:
    1. Diffs -Base (default: <Remote>/<Branch>, after a fetch) against
       <Branch>'s current tip.
    2. Splits the changed files into chunks of at most -ChunkGB of *raw*
       (uncompressed) content each.
    3. Builds one new commit per chunk - entirely via plumbing (update-index,
       write-tree, commit-tree). No checkout, no worktree: your working
       directory is never touched.
    4. Pushes each chunk commit to <Branch> as it's built, so a failure
       partway through leaves real progress on the remote.
    5. Verifies the final chunk's tree matches the original tip's tree
       exactly, then points the local branch ref at it.
    6. Commit messages are "<Title>" if it all fits in one chunk, or
       "<Title> [part i/N]" otherwise.

  Resuming after a failure: just run the same command again. -Base defaults
  to <Remote>/<Branch>, which only advances as chunks land, so a rerun
  automatically picks up wherever the last successful push left off -
  already-landed chunks aren't resent.

  Note: filenames are assumed not to contain literal tab or newline
  characters (true for everything in this repo). That's fine for DAT/DLL
  style trees; don't reuse this script as-is against a repo with exotic
  filenames.

.PARAMETER Repo
  Path to the git repo. Defaults to the folder this script lives in.

.PARAMETER Branch
  Branch to push. Defaults to the current branch.

.PARAMETER Remote
  Remote name. Defaults to "origin".

.PARAMETER Base
  Explicit ref/commit to diff from. Defaults to "<Remote>/<Branch>".

.PARAMETER Title
  Commit message title. Required.

.PARAMETER ChunkGB
  Max raw size per chunk, in GiB. Default 3.5 - proven safe against this
  repo's DAT files (10.5 GiB raw compressed to just over 2 GiB and got
  rejected; ~3.5 GiB raw chunks compressed comfortably under it). Lower this
  if a push ever fails with GitHub's "pack exceeds maximum allowed size"
  error - compression ratio isn't identical for every batch of files.

.PARAMETER DryRun
  Print the chunk plan and exit without touching anything.

.PARAMETER NoFetch
  Skip the automatic `git fetch <Remote> <Branch>` before resolving the
  default base.

.EXAMPLE
  .\git-split-push.ps1 -Title "September update"

.EXAMPLE
  .\git-split-push.ps1 -Title "September update" -DryRun
#>
[CmdletBinding()]
param(
    [string]$Repo = $PSScriptRoot,
    [string]$Branch,
    [string]$Remote = "origin",
    [string]$Base,
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [double]$ChunkGB = 3.5,
    [switch]$DryRun,
    [switch]$NoFetch
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [string]$IndexPath,
        [switch]$NoCapture,
        [switch]$AllowFailure
    )
    $prevIndex = $env:GIT_INDEX_FILE
    if ($IndexPath) { $env:GIT_INDEX_FILE = $IndexPath }
    try {
        $allArgs = @('-C', $Repo) + $GitArgs
        if ($NoCapture) {
            & git @allArgs
            if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
                throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
            }
            return $null
        }
        $output = & git @allArgs
        if ($LASTEXITCODE -ne 0) {
            if ($AllowFailure) { return $null }
            throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE (see git's error output above)"
        }
        if ($null -eq $output) { return "" }
        return ($output -join [Environment]::NewLine).Trim()
    }
    finally {
        if ($IndexPath) {
            if ($null -eq $prevIndex) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue }
            else { $env:GIT_INDEX_FILE = $prevIndex }
        }
    }
}

function Get-TreeListing {
    param($Repo, $Commit)
    $out = Invoke-Git -Repo $Repo -GitArgs @('ls-tree', '-r', '-l', $Commit)
    $result = @{}
    if (-not $out) { return $result }
    foreach ($line in ($out -split "`r?`n")) {
        if (-not $line) { continue }
        $tabIdx = $line.IndexOf("`t")
        $meta = $line.Substring(0, $tabIdx)
        $path = $line.Substring($tabIdx + 1)
        $parts = $meta -split '\s+' | Where-Object { $_ -ne '' }
        $sizeStr = $parts[3]
        $size = if ($sizeStr -eq '-') { 0L } else { [int64]$sizeStr }
        $result[$path] = [PSCustomObject]@{ Mode = $parts[0]; Type = $parts[1]; Sha = $parts[2]; Size = $size }
    }
    return $result
}

function Get-DiffRecords {
    param($Repo, $BaseSha, $Target)
    $out = Invoke-Git -Repo $Repo -GitArgs @('diff', '--name-status', $BaseSha, $Target)
    $records = @()
    if (-not $out) { return $records }
    foreach ($line in ($out -split "`r?`n")) {
        if (-not $line) { continue }
        $fields = $line -split "`t"
        if ($fields.Count -ge 3) {
            $records += [PSCustomObject]@{ Status = $fields[0]; Paths = @($fields[1], $fields[2]) }
        }
        else {
            $records += [PSCustomObject]@{ Status = $fields[0]; Paths = @($fields[1]) }
        }
    }
    return $records
}

function Get-RecordWeight {
    param($Record, $TargetTree)
    $weight = 0L
    foreach ($p in $Record.Paths) {
        if ($TargetTree.ContainsKey($p)) {
            $s = $TargetTree[$p].Size
            if ($s -gt $weight) { $weight = $s }
        }
    }
    return $weight
}

function Get-Chunks {
    param($Records, $TargetTree, [long]$ChunkBytes)
    # Plain arrays with explicit comma-guards, not List[Object].Add(): PowerShell
    # silently spreads an array's elements when it's passed to .Add() (or += on
    # another array) instead of nesting it as one item - the comma forces it to
    # be treated as a single element. Needed at every append AND at the final
    # return, otherwise a result with exactly one chunk gets unwrapped back down
    # to a plain list of records.
    $chunks = @()
    $current = @()
    $currentSize = 0L
    foreach ($rec in $Records) {
        $weight = Get-RecordWeight -Record $rec -TargetTree $TargetTree
        if ($current.Count -gt 0 -and ($currentSize + $weight) -gt $ChunkBytes) {
            $chunks += , $current
            $current = @()
            $currentSize = 0L
        }
        $current += $rec
        $currentSize += $weight
        if ($weight -gt $ChunkBytes) {
            $lastPath = $rec.Paths[$rec.Paths.Count - 1]
            Write-Warning ("  note: {0} alone is {1:N2} GiB, bigger than -ChunkGB; it gets its own chunk regardless." -f $lastPath, ($weight / 1GB))
        }
    }
    if ($current.Count -gt 0) { $chunks += , $current }
    return , $chunks
}

function Get-ChunkTotalBytes {
    param($Chunk, $TargetTree)
    $total = 0L
    foreach ($rec in $Chunk) { $total += (Get-RecordWeight -Record $rec -TargetTree $TargetTree) }
    return $total
}

function Get-WorkingTreeAsTree {
    # Computes the tree that `git add -A` would produce, WITHOUT touching the
    # real index: operates on a throwaway copy, so it's safe to call even
    # during -DryRun. Caller must ensure the target branch is the one
    # actually checked out (otherwise "the working tree" doesn't correspond
    # to it).
    param($Repo)
    $realIndex = Join-Path $Repo ".git\index"
    $scratchIndex = Join-Path $Repo ".git\git-split-push-worktree-index"
    if (Test-Path $scratchIndex) { Remove-Item $scratchIndex -Force }
    if (Test-Path $realIndex) { Copy-Item $realIndex $scratchIndex -Force }
    try {
        Invoke-Git -Repo $Repo -IndexPath $scratchIndex -NoCapture -GitArgs @('add', '-A') | Out-Null
        return Invoke-Git -Repo $Repo -IndexPath $scratchIndex -GitArgs @('write-tree')
    }
    finally {
        if (Test-Path $scratchIndex) { Remove-Item $scratchIndex -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-BuildAndPushChunk {
    param($Repo, $IndexPath, $Chunk, $TargetTree, $Parent, $Message, $Remote, $Branch)

    foreach ($rec in $Chunk) {
        $kind = $rec.Status.Substring(0, 1)
        if ($kind -eq 'D') {
            Invoke-Git -Repo $Repo -IndexPath $IndexPath -GitArgs @('update-index', '--force-remove', '--', $rec.Paths[0]) | Out-Null
        }
        elseif ($kind -eq 'R' -or $kind -eq 'C') {
            $oldPath, $newPath = $rec.Paths
            Invoke-Git -Repo $Repo -IndexPath $IndexPath -GitArgs @('update-index', '--force-remove', '--', $oldPath) | Out-Null
            $entry = $TargetTree[$newPath]
            Invoke-Git -Repo $Repo -IndexPath $IndexPath -GitArgs @('update-index', '--add', '--cacheinfo', "$($entry.Mode),$($entry.Sha),$newPath") | Out-Null
        }
        else {
            $path = $rec.Paths[0]
            $entry = $TargetTree[$path]
            Invoke-Git -Repo $Repo -IndexPath $IndexPath -GitArgs @('update-index', '--add', '--cacheinfo', "$($entry.Mode),$($entry.Sha),$path") | Out-Null
        }
    }

    $tree = Invoke-Git -Repo $Repo -IndexPath $IndexPath -GitArgs @('write-tree')
    $commit = Invoke-Git -Repo $Repo -GitArgs @('commit-tree', $tree, '-p', $Parent, '-m', $Message)
    Write-Host "  pushing $($commit.Substring(0,10)) ..."
    Invoke-Git -Repo $Repo -NoCapture -GitArgs @('push', $Remote, "${commit}:refs/heads/${Branch}") | Out-Null
    return [PSCustomObject]@{ Commit = $commit; Tree = $tree }
}

function Find-AutoBase {
    param($Repo, $Remote, $Target)
    $out = Invoke-Git -Repo $Repo -AllowFailure -GitArgs @('for-each-ref', "refs/remotes/$Remote", '--format=%(objectname) %(refname)')
    if (-not $out) { return $null }

    $best = $null
    $bestName = $null
    $bestDistance = -1
    $seen = @{}
    foreach ($line in ($out -split "`r?`n")) {
        if (-not $line) { continue }
        $parts = $line -split ' ', 2
        $sha = $parts[0]
        $refname = $parts[1]
        if ($refname -like "*/HEAD") { continue }
        if ($seen.ContainsKey($sha)) { continue }
        $seen[$sha] = $true

        Invoke-Git -Repo $Repo -AllowFailure -GitArgs @('merge-base', '--is-ancestor', $sha, $Target) | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        $countStr = Invoke-Git -Repo $Repo -AllowFailure -GitArgs @('rev-list', '--count', "$sha..$Target")
        if (-not $countStr) { continue }
        $distance = [int]$countStr
        if ($bestDistance -eq -1 -or $distance -lt $bestDistance) {
            $best = $sha
            $bestName = $refname
            $bestDistance = $distance
        }
    }
    if ($best) {
        Write-Host "  using $bestName ($($best.Substring(0,10))) as base - $bestDistance commit(s) ahead of it."
    }
    return $best
}

try {
    if (-not $Branch) {
        $Branch = Invoke-Git -Repo $Repo -GitArgs @('symbolic-ref', '--short', 'HEAD')
    }
    $StartingTip = Invoke-Git -Repo $Repo -GitArgs @('rev-parse', $Branch)

    if (-not $NoFetch) {
        Write-Host "fetching ${Remote}/${Branch} ..."
        Invoke-Git -Repo $Repo -NoCapture -AllowFailure -GitArgs @('fetch', $Remote, $Branch) | Out-Null
    }

    $BaseSha = $null
    if ($Base) {
        $BaseSha = Invoke-Git -Repo $Repo -AllowFailure -GitArgs @('rev-parse', '--verify', $Base)
        if (-not $BaseSha) { throw "couldn't resolve -Base '$Base'." }
    }
    else {
        $BaseRef = "${Remote}/${Branch}"
        $BaseSha = Invoke-Git -Repo $Repo -AllowFailure -GitArgs @('rev-parse', '--verify', $BaseRef)
        if (-not $BaseSha) {
            # Brand new branch, never pushed - fall back to the nearest already-pushed
            # ancestor commit (i.e. whichever remote branch this one forked from).
            Write-Host "no '$BaseRef' yet (never pushed) - looking for the branch this forked from ..."
            $BaseSha = Find-AutoBase -Repo $Repo -Remote $Remote -Target $StartingTip
            if (-not $BaseSha) {
                throw "couldn't resolve base 'origin/$Branch', and no ancestor of '$Branch' was found among any existing $Remote branch either. Pass -Base explicitly (e.g. the tip of the previous branch this one forked from)."
            }
        }
    }

    # Fold in whatever's currently on disk for this branch (committed or not),
    # instead of requiring a commit be made first. Computed via a throwaway
    # copy of the index, so this never touches the real index or working
    # tree - safe to do even under -DryRun. If a different branch is checked
    # out, there's no "working tree state" for our target branch to fold in,
    # so just fall back to its last real commit.
    $CurrentHeadBranch = Invoke-Git -Repo $Repo -AllowFailure -GitArgs @('symbolic-ref', '--short', 'HEAD')
    if ($CurrentHeadBranch -eq $Branch) {
        $DiffTarget = Get-WorkingTreeAsTree -Repo $Repo
    }
    else {
        Write-Warning "checked-out branch ('$CurrentHeadBranch') isn't the target branch ('$Branch') - any uncommitted changes are ignored; only pushing what's already committed on '$Branch'."
        $DiffTarget = $StartingTip
    }

    $BaseTree = Invoke-Git -Repo $Repo -GitArgs @('rev-parse', "${BaseSha}^{tree}")
    $TargetTreeSha = Invoke-Git -Repo $Repo -GitArgs @('rev-parse', "${DiffTarget}^{tree}")
    if ($BaseTree -eq $TargetTreeSha) {
        Write-Host "nothing to push - tree content is identical to base (metadata-only diff)."
        exit 0
    }

    $TargetTree = Get-TreeListing -Repo $Repo -Commit $DiffTarget
    $Records = Get-DiffRecords -Repo $Repo -BaseSha $BaseSha -Target $DiffTarget
    $ChunkBytes = [long]($ChunkGB * 1GB)
    $Chunks = Get-Chunks -Records $Records -TargetTree $TargetTree -ChunkBytes $ChunkBytes

    Write-Host ""
    Write-Host "$($Records.Count) changed paths, split into $($Chunks.Count) chunk(s):"
    for ($i = 0; $i -lt $Chunks.Count; $i++) {
        $sizeGiB = (Get-ChunkTotalBytes -Chunk $Chunks[$i] -TargetTree $TargetTree) / 1GB
        Write-Host ("  part {0}/{1}: {2} paths, ~{3:N2} GiB" -f ($i + 1), $Chunks.Count, $Chunks[$i].Count, $sizeGiB)
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "-DryRun: stopping here, nothing pushed."
        exit 0
    }

    $IndexPath = Join-Path $Repo ".git\git-split-push-index"
    Invoke-Git -Repo $Repo -IndexPath $IndexPath -GitArgs @('read-tree', $BaseSha) | Out-Null

    $Parent = $BaseSha
    $FinalCommit = $null
    $FinalTree = $null
    $N = $Chunks.Count
    try {
        for ($i = 0; $i -lt $N; $i++) {
            $Message = if ($N -eq 1) { $Title } else { "$Title [part $($i + 1)/$N]" }
            Write-Host ""
            Write-Host "=== building & pushing part $($i + 1)/$N ==="
            $result = Invoke-BuildAndPushChunk -Repo $Repo -IndexPath $IndexPath -Chunk $Chunks[$i] `
                -TargetTree $TargetTree -Parent $Parent -Message $Message -Remote $Remote -Branch $Branch
            $Parent = $result.Commit
            $FinalTree = $result.Tree
            $FinalCommit = $result.Commit
        }
    }
    finally {
        if (Test-Path $IndexPath) { Remove-Item $IndexPath -Force -ErrorAction SilentlyContinue }
    }

    if ($FinalTree -ne $TargetTreeSha) {
        throw "MISMATCH: final tree $FinalTree != expected $TargetTreeSha. Pushed commits are safe on the remote, but the local branch ref was NOT updated - investigate before rerunning."
    }

    $CurrentBranchTip = Invoke-Git -Repo $Repo -GitArgs @('rev-parse', $Branch)
    if ($CurrentBranchTip -ne $StartingTip) {
        Write-Warning "local branch '$Branch' moved during this run ($($StartingTip.Substring(0,10)) -> $($CurrentBranchTip.Substring(0,10))). Not touching the ref; your new commits ($($FinalCommit.Substring(0,10))) are pushed and safe - reconcile manually."
        exit 1
    }

    Invoke-Git -Repo $Repo -GitArgs @('update-ref', "refs/heads/$Branch", $FinalCommit) | Out-Null

    if ($CurrentHeadBranch -eq $Branch) {
        # Sync the real index to the new HEAD so `git status` reads clean -
        # this only touches the index (never working-tree files), and is
        # safe since we've just verified the new commit's tree matches
        # exactly what's on disk.
        Invoke-Git -Repo $Repo -GitArgs @('read-tree', $FinalCommit) | Out-Null
    }

    Write-Host ""
    Write-Host "done. '$Branch' now points at $($FinalCommit.Substring(0,10)), tree verified identical to the original tip."
}
catch {
    Write-Error "error: $($_.Exception.Message)"
    exit 1
}
