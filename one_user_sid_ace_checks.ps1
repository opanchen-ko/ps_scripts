<#
Diagnostics prototype: add GenericWrite ACE for user1 on its own object and show before/after (compare by SID)
Usage examples:
  .\add-ace-proto.ps1 -TargetDomain thinenv.gc -TargetUserSam user1 -DC dc01.thinenv.gc
  .\add-ace-proto.ps1 -TargetDomain thinenv.gc -TargetUserSam user1 -DryRun

Notes:
 - Requires RSAT ActiveDirectory module.
 - Run as a user with permission to modify ACLs in AD.
#>

param(
    [string]$TargetDomain = "thinenv.gc",
    [string]$TargetUserSam = "user2",
    [string]$DC = "",        # optional: fqdn of a domain controller (LDAP server)
    [switch]$DryRun
)

Import-Module ActiveDirectory -ErrorAction Stop

function Show-ACL {
    param($de, $label)
    Write-Host "=== ACL: $label ===" -ForegroundColor Cyan
    $sec = $de.ObjectSecurity
    $rules = $sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    $i = 0
    foreach ($r in $rules) {
        $i++
        $sid = $r.IdentityReference.Value
        # try to resolve to account name (best-effort)
        try { $acct = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { $acct = "<unresolvable>" }
        $rights = $r.ActiveDirectoryRights
        $type = $r.AccessControlType
        $inherited = $r.IsInherited
        Write-Host ("{0}. SID={1} ({2}), Rights={3}, Type={4}, Inherited={5}" -f $i, $sid, $acct, $rights, $type, $inherited)
    }
    Write-Host "=== end ACL ===`n"
}
$users = 26..250 | ForEach-Object { "user$_" }


foreach ($TargetUserSam in $users) {
try {
    # find user (optionally using specified DC)
    if ($DC -ne "") {
        $user = Get-ADUser -Server $DC -Identity $TargetUserSam -Properties DistinguishedName, SamAccountName
    } else {
        $user = Get-ADUser -Server $TargetDomain -Identity $TargetUserSam -Properties DistinguishedName, SamAccountName
    }

    if (-not $user) {
        Write-Error "Користувача '$TargetUserSam' не знайдено в домені $TargetDomain (або на DC=$DC)."
        exit 1
    }

    $dn = $user.DistinguishedName
    Write-Host "Користувач знайдений: $($user.SamAccountName) -> $dn" -ForegroundColor Green

    # LDAP path — прив'язка до конкретного DC якщо вказано
    if ($DC -ne "") { $ldapPath = "LDAP://$DC/$dn" } else { $ldapPath = "LDAP://$dn" }
    $de = New-Object System.DirectoryServices.DirectoryEntry($ldapPath)

    # show ACL before
    Show-ACL -de $de -label "Before"

    # Prepare identity as SID (reliable)
    $nt = New-Object System.Security.Principal.NTAccount("$TargetDomain\$TargetUserSam")
    $sid = $nt.Translate([System.Security.Principal.SecurityIdentifier])
    Write-Host "Resolved identity: $($nt.Value) -> SID=$($sid.Value)" -ForegroundColor Yellow

    # right to add
    $right = [System.DirectoryServices.ActiveDirectoryRights]::GenericWrite

    $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid,
        $right,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    if ($DryRun) {
        Write-Host "(DryRun) Would add ACE: Identity=$($sid.Value), Rights=$right" -ForegroundColor Magenta
        exit 0
    }

    # Add ACE
    $sd = $de.ObjectSecurity
    $sd.AddAccessRule($ace)
    $de.ObjectSecurity = $sd
    $de.CommitChanges()
    Write-Host "Спроба додати ACE завершена. CommitChanges() викликано." -ForegroundColor Green

    # small delay to let DC apply local change (optional)
    Start-Sleep -Seconds 1

    # rebind (recreate DirectoryEntry to avoid cached security)
    if ($DC -ne "") { $de2 = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DC/$dn") } else { $de2 = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dn") }

    Show-ACL -de $de2 -label "After"

    # check existence by searching rules for the same SID and rights bit
    $rulesAfter = $de2.ObjectSecurity.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    $found = $false
    foreach ($r in $rulesAfter) {
        if ($r.IdentityReference.Value -eq $sid.Value -and (($r.ActiveDirectoryRights -band $right) -ne 0) -and $r.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow) {
            $found = $true
            break
        }
    }

    if ($found) {
        Write-Host "Верифікація успішна: ACE присутній (SID $($sid.Value))." -ForegroundColor Green
    } else {
        Write-Warning "ACE не знайдено після запису. Можливі причини — див. поради нижче."
    }

} catch {
    Write-Error "Виникла помилка: $_"
    exit 2
}
}
# --- Поради якщо ACE не знайдено ---
Write-Host "`n=== Поради для діагностики (якщо ACE не знайдено) ===" -ForegroundColor Cyan
Write-Host "1) Перевір права облікового запису, під яким ви запускаєте скрипт — потрібні права на зміну ACL (Domain Admin або делеговані права на зміну DACL)." 
Write-Host "2) Якщо ви не вказали DC, зміни могли бути застосовані на іншому контролері або ще не репліковані — вкажіть DC (параметр -DC) напр., dc01.thinenv.gc" 
Write-Host "3) Перевірте, чи ACE був доданий як успадкований (IsInherited=True) — тоді може виглядати інакше." 
Write-Host "4) Іноді NTAccount переклад не відображається — тому ми використовуємо SID для перевірки." 
Write-Host "5) Якщо додаєте спеціальне право (наприклад ForceChangePassword), воно може бути представлене як ExtendedRight з конкретним GUID — потрібно інший спосіб створення ACE." 
Write-Host "6) Перевірте логи DC та eventvwr на помилки доступу/безпеки." 
Write-Host "7) Якщо потрібно, пришліть вивід блоків 'Before' і 'After' (перші ~30 правил) — я підкажу наступний крок."
