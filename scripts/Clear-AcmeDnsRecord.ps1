<#
.SYNOPSIS
    win-acme DNS-01 "delete" hook for ONE-TIME manual validation - reminds you to remove the
    temporary TXT record once validation has completed. (Manual DNS has no API to delete it.)

.NOTES
    Part of Cert-Man-Windows. Wired automatically by generate-cert.ps1 (DNS option 7).
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RecordName)

Write-Host ''
Write-Host ('  Validation done. You may now remove the one-time TXT record: {0}' -f $RecordName) -ForegroundColor DarkGray
exit 0
