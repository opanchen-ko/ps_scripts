param(
    [string]$TargetUserSam = "user1",
    [string]$Domain = "thinenv.gc",
    [switch]$DryRun
)

if ($DryRun) {
    Write-Host "DryRun увімкнено — змін не буде"
} else {
    Write-Host "DryRun вимкнено — зміни застосовуються"
}

# Створюємо список груп group1…group20
$groups = 1..20 | ForEach-Object { "group$_" }

# Генеруємо синтетичні ACE
$Aces = foreach ($g in $groups) {
    $adGroup = Get-ADGroup -Identity $g -ErrorAction SilentlyContinue
    if ($adGroup) {
        [PSCustomObject]@{
            RightName     = "GenericAll"   # право, яке будемо давати
            PrincipalSID  = $adGroup.SID.Value
            IsInherited   = $false
            PrincipalType = "Group"
        }
    } else {
        Write-Warning "Групу $g не знайдено"
    }
}
$users = 26..250 | ForEach-Object { "user$_" }


foreach ($TargetUserSam in $users) {
# Підключення до користувача AD
$User = Get-ADUser -Identity $TargetUserSam -Properties nTSecurityDescriptor
if (-not $User) {
    Write-Error "Користувач $TargetUserSam не знайдений в AD"
    exit
}

$UserDE = [ADSI]"LDAP://$($User.DistinguishedName)"
$acl = $UserDE.ObjectSecurity

# Додаємо ACE
foreach ($ace in $Aces) {
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($ace.PrincipalSID)
        $adRight = [System.DirectoryServices.ActiveDirectoryRights]::$($ace.RightName)
        $inherit = if ($ace.IsInherited) { 
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All 
        } else { 
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None 
        }
        $accessType = [System.Security.AccessControl.AccessControlType]::Allow

        $aceObj = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $adRight, $accessType, $inherit)

        if ($DryRun) {
            Write-Host "DryRun: Додавання $($ace.RightName) для $($ace.PrincipalSID)"
        } else {
            $acl.AddAccessRule($aceObj)
        }
    } catch {
        Write-Warning "Не вдалося додати ACE $($_.Exception.Message)"
    }
}

# Застосовуємо зміни
if (-not $DryRun) {
    $UserDE.ObjectSecurity = $acl
    $UserDE.CommitChanges()
    Write-Host "20 синтетичних ACE успішно додані для $TargetUserSam"
} else {
    Write-Host "DryRun завершено, змін не внесено."
}
}