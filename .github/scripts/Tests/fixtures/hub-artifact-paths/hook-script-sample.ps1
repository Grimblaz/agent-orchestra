#Requires -Version 7.0
# Fixture for hub-artifact-paths extraction grammar tests — hook script scope.

# Single-quoted path literals (should be extracted)
$FramePredicatePath = '.github/scripts/lib/frame-predicate-core.ps1'
$CleanupScript = '.github/scripts/post-merge-cleanup.ps1'

# Double-quoted path literals (should be extracted)
$TestSuitePath = ".github/scripts/Tests/audit-hub-artifact-paths.Tests.ps1"

# Dot-source the core library
. $FramePredicatePath

# Invoke cleanup
& $CleanupScript

Write-Output "Hook script fixture loaded from $TestSuitePath"
