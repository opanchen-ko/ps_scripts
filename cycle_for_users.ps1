# Масив користувачів від user1 до user25
$users = 1..25 | ForEach-Object { "user$_" }

# Шлях до твого скрипта, який приймає параметри
$scriptPath = "one_user_sid_ace_checks.ps1"

foreach ($user in $users) {
    Write-Host "Виконуємо скрипт для користувача: $user"

    # Виклик скрипта з параметром TargetUserSam
    & $scriptPath -TargetUserSam $user -TargetDomain "thinenv.gc" -DC "" 
}