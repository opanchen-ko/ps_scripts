param(
    [string]$TargetGroupSam = "group1",   # група, на яку додаємо права
    [switch]$DryRun
)

Import-Module ActiveDirectory -ErrorAction Stop

if ($DryRun) { Write-Host "DryRun увімкнено — змін не буде" } else { Write-Host "DryRun вимкнено — зміни застосовуються" }

# Отримуємо групу
$ADGroup = Get-ADGroup -Identity $TargetGroupSam -Properties DistinguishedName -ErrorAction SilentlyContinue
if (-not $ADGroup) { Write-Error "Групу '$TargetGroupSam' не знайдено"; exit 1 }

$GroupDE = [ADSI]"LDAP://$($ADGroup.DistinguishedName)"
$acl = $GroupDE.ObjectSecurity

# SID групи (для AccessRule)
$sid = New-Object System.Security.Principal.SecurityIdentifier($ADGroup.SID.Value)

# Прості права
$basicRights = @("GenericAll","GenericWrite","WriteDacl","WriteOwner","GenericRead","ReadProperty","WriteProperty","Delete","DeleteChild","Self")

foreach ($r in $basicRights) {
    try {
        $adRight = [System.DirectoryServices.ActiveDirectoryRights]::$r
        $accessType = [System.Security.AccessControl.AccessControlType]::Allow
        $inheritance = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None

        $aceObj = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $adRight, $accessType, $inheritance)

        if ($DryRun) { Write-Host "DryRun: Додано правило '$r' для '$TargetGroupSam'" }
        else { $acl.AddAccessRule($aceObj) }
    } catch {
        Write-Warning "Не вдалося додати правило '$r': $($_.Exception.Message)"
    }
}

# Extended Rights
$extendedRights = @{
    "ForceChangePassword" = "00299570-246d-11d0-a768-00aa006e0529"
    "AllExtendedRights"   = "f30a8c74-6a88-11d0-9991-00aa006c33ed"
    "DCSync"              = "1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"
}

foreach ($name in $extendedRights.Keys) {
    try {
        $guid = [guid]$extendedRights[$name]
        $adRight = [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight
        $accessType = [System.Security.AccessControl.AccessControlType]::Allow
        $inheritance = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None

        $aceObj = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $adRight, $accessType, $inheritance, $guid)

        if ($DryRun) { Write-Host "DryRun: Додано ExtendedRight '$name' для '$TargetGroupSam'" }
        else { $acl.AddAccessRule($aceObj) }
    } catch {
        Write-Warning "Не вдалося додати ExtendedRight '$name': $($_.Exception.Message)"
    }
}

# Commit змін
if (-not $DryRun) {
    try {
        $GroupDE.ObjectSecurity = $acl
        $GroupDE.CommitChanges()
        Write-Host "ACE успішно додані для групи '$TargetGroupSam'"
        Get-Acl -Path ("AD:" + $ADGroup.DistinguishedName) | Select-Object -ExpandProperty Access
    } catch {
        Write-Error "Не вдалося зберегти зміни: $($_.Exception.Message)"
    }
} else { Write-Host "DryRun завершено — змін не внесено." }
