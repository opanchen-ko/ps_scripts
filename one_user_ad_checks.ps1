# Тестовий скрипт для встановлення параметрів одному користувачу
# Для тестування та налагодження перед масовою обробкою

Import-Module ActiveDirectory

# Функція для генерації випадкового тексту
function Generate-RandomText {
    param([int]$Length)
    
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,-"
    $result = ""
    for ($i = 0; $i -lt $Length; $i++) {
        $result += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $result.Trim()
}

# НАЛАШТУВАННЯ: Вкажіть ім'я користувача для тестування
$TestUserName = "user1"  # ЗМІНІТЬ НА РЕАЛЬНОГО КОРИСТУВАЧА

Write-Host "=== ТЕСТ ВСТАНОВЛЕННЯ ПАРАМЕТРІВ AD КОРИСТУВАЧА ===" -ForegroundColor Green
Write-Host "Тестовий користувач: $TestUserName" -ForegroundColor Yellow

# Перевірка існування користувача
try {
    $TestUser = Get-ADUser -Identity $TestUserName -ErrorAction Stop
    Write-Host "✓ Користувач знайдений: $($TestUser.SamAccountName)" -ForegroundColor Green
}
catch {
    Write-Error "✗ Користувач '$TestUserName' не знайдений: $($_.Exception.Message)"
    Write-Host "Доступні користувачі в SyntheticUsers:" -ForegroundColor Yellow
    try {
        $availableUsers = Get-ADUser -Filter * -SearchBase "OU=SyntheticUsers,DC=thinenv,DC=gc" -ResultSetSize 10
        $availableUsers | ForEach-Object { Write-Host "  - $($_.SamAccountName)" -ForegroundColor Cyan }
    }
    catch {
        Write-Host "Не вдалося отримати список користувачів" -ForegroundColor Red
    }
    exit
}

# Генерація тестових даних
$userSeed = [Math]::Abs($TestUserName.GetHashCode())
Write-Host "Генерація тестових даних (seed: $userSeed)..." -ForegroundColor Yellow

$testData = @{
    smallText = Generate-RandomText -Length 50
    mediumText = Generate-RandomText -Length 200  
    largeText = Generate-RandomText -Length 1000
    hugeText = Generate-RandomText -Length 8000
}

Write-Host "✓ Тестові дані згенеровані" -ForegroundColor Green

# ТЕСТ 1: Основні параметри через Set-ADUser з параметрами
Write-Host "`n=== ТЕСТ 1: Основні параметри ===" -ForegroundColor Cyan

$basicParams = @{}
$testResults = @()

# Тестуємо кожен параметр окремо
$paramsToTest = @(
    @{Name="DisplayName"; Value=$testData.smallText; Safe=$true},
    @{Name="Title"; Value=$testData.smallText; Safe=$true},
    @{Name="Department"; Value=$testData.smallText; Safe=$true},
    @{Name="Company"; Value=$testData.smallText; Safe=$true},
    @{Name="StreetAddress"; Value=$testData.smallText; Safe=$true},
    @{Name="PostalCode"; Value="12345"; Safe=$true},
    @{Name="Country"; Value="UA"; Safe=$true},
    @{Name="Info"; Value=$testData.mediumText; Safe=$false},  # Потенційно проблемний
    @{Name="Description"; Value=$testData.largeText; Safe=$true}
)

foreach ($param in $paramsToTest) {
    try {
        $singleParam = @{$param.Name = $param.Value}
        Set-ADUser -Identity $TestUserName @singleParam -ErrorAction Stop
        Write-Host "✓ $($param.Name): SUCCESS" -ForegroundColor Green
        $testResults += [PSCustomObject]@{Parameter=$param.Name; Status="SUCCESS"; Method="Parameter"}
    }
    catch {
        Write-Host "✗ $($param.Name): FAILED - $($_.Exception.Message)" -ForegroundColor Red
        $testResults += [PSCustomObject]@{Parameter=$param.Name; Status="FAILED"; Method="Parameter"; Error=$_.Exception.Message}
    }
}

# ТЕСТ 2: Проблемні поля через -Replace
Write-Host "`n=== ТЕСТ 2: Поля через -Replace ===" -ForegroundColor Cyan

$replaceTests = @(
    @{AttrName="description"; Value=$testData.hugeText},
    @{AttrName="info"; Value=$testData.largeText},
    @{AttrName="physicalDeliveryOfficeName"; Value=$testData.smallText},  # Office
    @{AttrName="l"; Value=$testData.smallText},                         # City
    @{AttrName="st"; Value=$testData.smallText},                        # State
    @{AttrName="mail"; Value="test_${userSeed}@example.com"},          # Email
    @{AttrName="wWWHomePage"; Value="https://test-${userSeed}.example.com"}, # HomePage
    @{AttrName="comment"; Value=$testData.mediumText}
)

foreach ($test in $replaceTests) {
    try {
        $replaceHash = @{$test.AttrName = $test.Value}
        Set-ADUser -Identity $TestUserName -Replace $replaceHash -ErrorAction Stop
        Write-Host "✓ $($test.AttrName): SUCCESS" -ForegroundColor Green
        $testResults += [PSCustomObject]@{Parameter=$test.AttrName; Status="SUCCESS"; Method="Replace"}
    }
    catch {
        Write-Host "✗ $($test.AttrName): FAILED - $($_.Exception.Message)" -ForegroundColor Red
        $testResults += [PSCustomObject]@{Parameter=$test.AttrName; Status="FAILED"; Method="Replace"; Error=$_.Exception.Message}
    }
}

# ТЕСТ 3: ExtensionAttributes
Write-Host "`n=== ТЕСТ 3: Extension Attributes ===" -ForegroundColor Cyan

$successfulExtensions = 0
for ($i = 1; $i -le 15; $i++) {
    $attrName = "extensionAttribute$i"
    $attrValue = "ExtAttr${i}_Test_${userSeed}_" + (Generate-RandomText -Length 900)
    
    try {
        # Спробуємо Add спочатку
        Set-ADUser -Identity $TestUserName -Add @{$attrName = $attrValue} -ErrorAction Stop
        Write-Host "✓ $attrName (Add): SUCCESS" -ForegroundColor Green
        $testResults += [PSCustomObject]@{Parameter=$attrName; Status="SUCCESS"; Method="Add"}
        $successfulExtensions++
    }
    catch {
        # Якщо Add не працює, спробуємо Replace
        try {
            Set-ADUser -Identity $TestUserName -Replace @{$attrName = $attrValue} -ErrorAction Stop
            Write-Host "✓ $attrName (Replace): SUCCESS" -ForegroundColor Yellow
            $testResults += [PSCustomObject]@{Parameter=$attrName; Status="SUCCESS"; Method="Replace"}
            $successfulExtensions++
        }
        catch {
            Write-Host "✗ ${attrName}: FAILED - $($_.Exception.Message)" -ForegroundColor Red
            $testResults += [PSCustomObject]@{Parameter=$attrName; Status="FAILED"; Method="Both"; Error=$_.Exception.Message}
        }
    }
}

# ТЕСТ 4: Перевірка встановлених значень
Write-Host "`n=== ТЕСТ 4: Перевірка встановлених значень ===" -ForegroundColor Cyan

try {
    $updatedUser = Get-ADUser -Identity $TestUserName -Properties * -ErrorAction Stop
    
    Write-Host "Перевіряємо встановлені значення:" -ForegroundColor Yellow
    
    # Перевіряємо розмір даних
    $totalSize = 0
    
    if ($updatedUser.Description) { 
        $size = $updatedUser.Description.Length
        $totalSize += $size
        Write-Host "  Description: $size символів" -ForegroundColor White 
    }
    
    if ($updatedUser.Info) { 
        $size = $updatedUser.Info.Length  
        $totalSize += $size
        Write-Host "  Info: $size символів" -ForegroundColor White 
    }
    
    # Перевіряємо extensionAttributes
    $extAttrSize = 0
    for ($i = 1; $i -le 15; $i++) {
        $attrName = "extensionAttribute$i"
        $attrValue = $updatedUser.$attrName
        if ($attrValue) {
            $size = $attrValue.Length
            $extAttrSize += $size
            Write-Host "  ${attrName}: $size символів" -ForegroundColor White
        }
    }
    $totalSize += $extAttrSize
    
    Write-Host "Загальний розмір даних користувача: $([Math]::Round($totalSize/1024, 2)) КБ" -ForegroundColor Cyan
}
catch {
    Write-Warning "Не вдалося перевірити встановлені значення: $($_.Exception.Message)"
}

# ПІДСУМОК
Write-Host "`n=== ПІДСУМОК ТЕСТУВАННЯ ===" -ForegroundColor Green

$successful = ($testResults | Where-Object {$_.Status -eq "SUCCESS"}).Count
$failed = ($testResults | Where-Object {$_.Status -eq "FAILED"}).Count

Write-Host "Успішно встановлено: $successful параметрів" -ForegroundColor Green
Write-Host "Не вдалося встановити: $failed параметрів" -ForegroundColor Red
Write-Host "Extension Attributes: $successfulExtensions з 15" -ForegroundColor Cyan

if ($failed -gt 0) {
    Write-Host "`nНевдалі параметри:" -ForegroundColor Red
    $testResults | Where-Object {$_.Status -eq "FAILED"} | ForEach-Object {
        Write-Host "  - $($_.Parameter): $($_.Error)" -ForegroundColor Red
    }
}

Write-Host "`nРекомендації для масового скрипта:" -ForegroundColor Yellow
$workingMethods = $testResults | Where-Object {$_.Status -eq "SUCCESS"} | Group-Object Method
foreach ($method in $workingMethods) {
    Write-Host "  $($method.Name): $($method.Count) параметрів" -ForegroundColor Cyan
}

Write-Host "`nТест завершено!" -ForegroundColor Green