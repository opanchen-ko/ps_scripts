<#
ensure_principals.ps1

Опис:
  Перевіряє наявність Principal'ів зі списку шаблонів і створює відсутні (групи або користувачі).
  За замовчуванням робить dry-run. Для реального створення вкажіть -Apply.

Параметри:
  -Apply            : реально створює об'єкти (інакше WhatIf режим)
  -GroupsOU         : OU для створення нових груп (наприклад "OU=Groups,DC=thinenv,DC=gc")
  -UsersOU          : OU для створення нових користувачів (наприклад "OU=ServiceAccounts,DC=thinenv,DC=gc")
  -DefaultUserPassword : Приклад пароля (рядок). Якщо не задано, пароль згенерується автоматично.
  -LogPath          : шлях до CSV лог (default .\principals_check_log.csv)

Приклад:
  # dry-run (перевірка)
  .\ensure_principals.ps1 -GroupsOU "OU=Groups,DC=thinenv,DC=gc" -UsersOU "OU=ServiceAccounts,DC=thinenv,DC=gc"

  # реально створити (apply)
  .\ensure_principals.ps1 -Apply -GroupsOU "OU=Groups,DC=thinenv,DC=gc" -UsersOU "OU=ServiceAccounts,DC=thinenv,DC=gc"

#>

param(
  [switch]$Apply,
  [string]$GroupsOU = "OU=Groups,DC=thinenv,DC=gc",
  [string]$UsersOU  = "OU=ServiceAccounts,DC=thinenv,DC=gc",
  [string]$DefaultUserPassword = "",
  [string]$LogPath = ".\principals_check_log.csv"
)

Import-Module ActiveDirectory -ErrorAction Stop

# --- ВАШІ шаблони ACL / Principal'ів (редагуйте за потреби) ---
$AclTemplates = @(
  @{ Principal = "Domain Admins";         PrincipalType = "Group" },
  @{ Principal = "Enterprise Admins";     PrincipalType = "Group" },
  @{ Principal = "SYNTHETIC-ADMINS";      PrincipalType = "Group" },
  @{ Principal = "Administrators";        PrincipalType = "Group" },
  @{ Principal = "svc_techsuplly";        PrincipalType = "User" },
  @{ Principal = "svc_sqlsep";            PrincipalType = "User" },
  @{ Principal = "svc_deploy";            PrincipalType = "User" }
)
# -----------------------------------------------

# Utility: нормалізувати ім'я (вирізати domain\ якщо є)
function Normalize-PrincipalName {
  param([string]$raw)
  if (-not $raw) { return $null }
  $s = $raw.Trim()
  if ($s -like "*\*") {
    $parts = $s.Split("\",2)
    return $parts[1]
  }
  return $s
}

# Utility: згенерувати сильний пароль
function New-RandomPassword {
  param($length = 20)
  # Символи: великі, малі, цифри, символи
  $upper = 65..90 | ForEach-Object {[char]$_}
  $lower = 97..122 | ForEach-Object {[char]$_}
  $digits = 48..57 | ForEach-Object {[char]$_}
  $symbols = "!,@,#,$,%,^,&,*,(,),-,_,=,+".Split(",")
  $alls = $upper + $lower + $digits + $symbols
  $pw = -join ((1..$length) | ForEach-Object { $alls | Get-Random })
  return $pw
}

# перевірка/створення групи
function Ensure-Group {
  param(
    [string]$GroupName,
    [string]$TargetOU,
    [switch]$ApplyFlag
  )
  $groupNameNorm = $GroupName.Trim()
  # спробувати знайти групу по Name або samAccountName
  $existing = Get-ADGroup -Filter "Name -eq '$groupNameNorm' -or SamAccountName -eq '$groupNameNorm'" -ErrorAction SilentlyContinue
  if ($existing) {
    return @{Status="Exists"; Object=$existing}
  }

  if (-not $ApplyFlag) {
    return @{Status="Missing"; Action="WouldCreateGroup"; Name=$groupNameNorm}
  }

  # створити групу (Global, Security)
  try {
    New-ADGroup -Name $groupNameNorm -SamAccountName $groupNameNorm -GroupScope Global -GroupCategory Security -Path $TargetOU -ErrorAction Stop
    $created = Get-ADGroup -Identity $groupNameNorm -ErrorAction SilentlyContinue
    return @{Status="Created"; Object=$created}
  } catch {
    return @{Status="Error"; Message=$_}
  }
}

# перевірка/створення користувача (сервісна)
function Ensure-User {
  param(
    [string]$UserName,
    [string]$TargetOU,
    [string]$PasswordPlain,
    [switch]$ApplyFlag
  )
  $userNameNorm = $UserName.Trim()

  # спроба знайти користувача по samAccountName або по Name
  $existing = Get-ADUser -Filter "SamAccountName -eq '$userNameNorm' -or Name -eq '$userNameNorm'" -ErrorAction SilentlyContinue
  if ($existing) {
    return @{Status="Exists"; Object=$existing}
  }

  if (-not $ApplyFlag) {
    return @{Status="Missing"; Action="WouldCreateUser"; Name=$userNameNorm}
  }

  # якщо пароль не заданий, згенеруємо
  if (-not $PasswordPlain -or $PasswordPlain -eq "") {
    $PasswordPlain = New-RandomPassword -length 20
  }
  $securePwd = ConvertTo-SecureString -AsPlainText $PasswordPlain -Force

  # Створимо користувача вимкненим (Enabled=$false), із SamAccountName = userNameNorm
  try {
    New-ADUser -Name $userNameNorm `
               -SamAccountName $userNameNorm `
               -AccountPassword $securePwd `
               -Enabled $false `
               -Path $TargetOU `
               -ChangePasswordAtLogon $false `
               -PasswordNeverExpires $true `
               -Description "Auto-created service account for tests" -ErrorAction Stop

    $created = Get-ADUser -Identity $userNameNorm -ErrorAction SilentlyContinue
    return @{Status="Created"; Object=$created; Password=$PasswordPlain}
  } catch {
    return @{Status="Error"; Message=$_}
  }
}

# Підготовка логу
if (-not (Test-Path (Split-Path $LogPath))) {
  New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
}
if (-not (Test-Path $LogPath)) {
  "Timestamp,Principal,Type,Result,Details" | Out-File -FilePath $LogPath -Encoding UTF8
}

# Якщо користувач задав пароль через параметр, збережемо його для створення
$explicitPassword = $DefaultUserPassword

Write-Host "Apply mode: $Apply"
Write-Host "Groups OU: $GroupsOU"
Write-Host "Users  OU: $UsersOU"
Write-Host "Processing templates..."

foreach ($t in $AclTemplates) {
  $raw = $t.Principal
  $type = $t.PrincipalType
  $name = Normalize-PrincipalName -raw $raw

  if ($type -match '^Group$') {
    $res = Ensure-Group -GroupName $name -TargetOU $GroupsOU -ApplyFlag:$Apply
    if ($res.Status -eq "Exists") {
      $line = "$(Get-Date -Format o),$name,Group,Exists,$($res.Object.DistinguishedName)"
    } elseif ($res.Status -eq "Missing") {
      $line = "$(Get-Date -Format o),$name,Group,Missing,WouldCreate"
    } elseif ($res.Status -eq "Created") {
      $line = "$(Get-Date -Format o),$name,Group,Created,$($res.Object.DistinguishedName)"
    } else {
      $line = "$(Get-Date -Format o),$name,Group,Error,$($res.Message -replace ',',';')"
    }
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
  }
  elseif ($type -match '^User$') {
    $pwdForThis = $explicitPassword
    $res = Ensure-User -UserName $name -TargetOU $UsersOU -PasswordPlain $pwdForThis -ApplyFlag:$Apply
    if ($res.Status -eq "Exists") {
      $line = "$(Get-Date -Format o),$name,User,Exists,$($res.Object.DistinguishedName)"
    } elseif ($res.Status -eq "Missing") {
      $line = "$(Get-Date -Format o),$name,User,Missing,WouldCreate"
    } elseif ($res.Status -eq "Created") {
      # збережемо пароль в деталях (якщо створено) — обережно з логами
      $line = "$(Get-Date -Format o),$name,User,Created,DN=$($res.Object.DistinguishedName);Password=$($res.Password)"
    } else {
      $line = "$(Get-Date -Format o),$name,User,Error,$($res.Message -replace ',',';')"
    }
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
  }
  else {
    $line = "$(Get-Date -Format o),$name,UnknownType,Skipped,Type $type not supported"
    Add-Content -Path $LogPath -Value $line
    Write-Warning $line
  }
}

Write-Host "Completed. Log saved to: $LogPath"
if (-not $Apply) { Write-Warning "Dry-run mode — не було змінено AD. Використайте -Apply щоб реально створити відсутні об'єкти." }
