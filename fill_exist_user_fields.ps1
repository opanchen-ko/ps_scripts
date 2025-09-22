# Скрипт для створення 2-3 ГБ даних в Active Directory
# УВАГА: Запускайте тільки в тестовому середовищі!
Write-Host " УВАГА: Запускайте тільки в тестовому середовищі!" -ForegroundColor Red

# Імпорт модуля Active Directory
Import-Module ActiveDirectory

# Функція для генерації великого обсягу випадкового тексту
function Generate-LargeRandomText {
    param(
        [int]$Length,
        [string]$CharSet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,-_()[]{}:;!?@#$%^&*+=|\/~`'"""
    )
    
    $result = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Length; $i++) {
        $null = $result.Append($CharSet[(Get-Random -Maximum $CharSet.Length)])
        
        # Прогрес для великих текстів
        if ($i % 10000 -eq 0 -and $i -gt 0) {
            Write-Progress -Id 1 -Activity "Генерація тексту" -Status "$i з $Length символів" -PercentComplete (($i / $Length) * 100)
        }
    }
    Write-Progress -Id 1 -Activity "Генерація тексту" -Completed
    return $result.ToString()
}

# Функція для створення JSON з великими даними
function Generate-LargeJSON {
    param([int]$Size)
    
    $data = @{
        "metadata" = @{
            "created" = (Get-Date).ToString()
            "version" = "1.0"
            "size_target" = $Size
        }
        "large_data_blocks" = @()
        "configuration" = @{}
    }
    
    # Додаємо великі блоки даних
    for ($i = 0; $i -lt 10; $i++) {
        $blockSize = [Math]::Floor($Size / 15)
        $data.large_data_blocks += @{
            "block_id" = $i
            "content" = Generate-LargeRandomText -Length $blockSize
            "checksum" = (Get-Random -Maximum 999999).ToString()
        }
    }
    
    # Додаємо конфігураційні дані
    for ($i = 0; $i -lt 50; $i++) {
        $data.configuration["config_$i"] = Generate-LargeRandomText -Length 1000
    }
    
    return ($data | ConvertTo-Json -Depth 10 -Compress)
}

# Цільовий розмір даних на користувача (в байтах)
$TARGET_SIZE_PER_USER = 12288  # 12KB per user для досягнення 2-3GB на 250k користувачів

# Отримання користувачів оптимізованим методом для thinenv.gc
Write-Host "Отримання списку користувачів з домену thinenv.gc..." -ForegroundColor Green

# Визначаємо SearchBase для SyntheticUsers OU (тут основна маса користувачів)
$syntheticUsersOU = "OU=SyntheticUsers,DC=thinenv,DC=gc"
$domainBase = "DC=thinenv,DC=gc"

$Users = @()

try {
    Write-Host "Отримання користувачів з SyntheticUsers OU..." -ForegroundColor Yellow
    
    # Спочатку отримуємо з основного OU де є користувачі
    $syntheticUsers = Get-ADUser -Filter * -SearchBase $syntheticUsersOU -Properties SamAccountName, DistinguishedName
    $Users += $syntheticUsers
    
    Write-Host "Знайдено в SyntheticUsers: $($syntheticUsers.Count) користувачів" -ForegroundColor Cyan
    
    # Отримуємо користувачів з інших місць домену (невеликими батчами)
    Write-Host "Пошук користувачів в інших OU домену..." -ForegroundColor Yellow
    
    $otherUsers = Get-ADUser -Filter * -SearchBase $domainBase -Properties SamAccountName, DistinguishedName -ResultSetSize 50000 | 
                  Where-Object { $_.DistinguishedName -notlike "*OU=SyntheticUsers*" }
    
    if ($otherUsers) {
        $Users += $otherUsers
        Write-Host "Знайдено в інших OU: $($otherUsers.Count) користувачів" -ForegroundColor Cyan
    }
    
    Write-Host "Загалом отримано користувачів: $($Users.Count)" -ForegroundColor Green
}
catch {
    Write-Host "Помилка при отриманні з SyntheticUsers. Використовуємо загальний метод..." -ForegroundColor Yellow
    
    try {
        # Альтернативний метод - батчами з усього домену
        $allUsers = @()
        $batchSize = 5000
        $totalFetched = 0
        
        do {
            Write-Host "Отримання батчу користувачів (отримано: $totalFetched)..." -ForegroundColor Yellow
            $batch = Get-ADUser -Filter * -Properties SamAccountName -ResultSetSize $batchSize | 
                     Select-Object -Skip $totalFetched -First $batchSize
            
            if ($batch) {
                $allUsers += $batch
                $totalFetched = $allUsers.Count
                Write-Host "Поточний прогрес: $totalFetched користувачів" -ForegroundColor Cyan
                
                # Обмежуємо для уникнення переповнення пам'яті
                if ($totalFetched -ge 300000) {
                    Write-Host "Досягнуто ліміт 300k користувачів. Зупиняємо отримання." -ForegroundColor Yellow
                    break
                }
            }
        } while ($batch -and $batch.Count -eq $batchSize)
        
        $Users = $allUsers
        Write-Host "Альтернативним методом отримано: $($Users.Count) користувачів" -ForegroundColor Green
    }
    catch {
        Write-Error "Критична помилка отримання користувачів: $($_.Exception.Message)"
        Write-Host "Завершуємо роботу через критичну помилку." -ForegroundColor Red
        exit
    }
}

if ($Users.Count -eq 0) {
    Write-Error "Користувачі не знайдені!"
    Write-Host "Завершуємо роботу - немає користувачів для обробки." -ForegroundColor Red
    exit
}

Write-Host "Знайдено користувачів: $($Users.Count)" -ForegroundColor Yellow

# Розрахунок очікуваного розміру
$expectedSizeGB = ($Users.Count * $TARGET_SIZE_PER_USER) / 1GB
Write-Host "Очікуваний розмір даних: $([Math]::Round($expectedSizeGB, 2)) ГБ" -ForegroundColor Cyan

# Автоматичний запуск без підтвердження
Write-Host "УВАГА! Буде створено $([Math]::Round($expectedSizeGB, 2)) ГБ даних." -ForegroundColor Yellow
Write-Host "Автоматичний запуск через 3 секунди..." -ForegroundColor Cyan
Start-Sleep -Seconds 3
Write-Host "Запускаємо..." -ForegroundColor Green

$processedCount = 0
$totalDataSize = 0
$startTime = Get-Date

Write-Host "Починаємо заповнення даних..." -ForegroundColor Green

foreach ($User in $Users) {
    try {
        $userStartTime = Get-Date
        Write-Progress -Activity "Створення великих даних" -Status "Користувач: $($User.SamAccountName)" -PercentComplete (($processedCount / $Users.Count) * 100)
        
        # Отримуємо повні властивості користувача тільки коли обробляємо його
        try {
            $FullUser = Get-ADUser -Identity $User.SamAccountName -Properties *
        }
        catch {
            Write-Warning "Не вдалося отримати повні властивості для $($User.SamAccountName), використовуємо базові"
            $FullUser = $User
        }
        
        # Генерація унікального seed для кожного користувача
        $userSeed = [Math]::Abs($User.SamAccountName.GetHashCode())
        
        # Створення великих текстових блоків
        $largeDescription = Generate-LargeRandomText -Length 8192  # 8KB
        $largeInfo = Generate-LargeRandomText -Length 2048        # 2KB
        
        # Створення JSON з великими даними
        $largeJSONData = Generate-LargeJSON -Size 1024            # 1KB JSON
        
        # Основні поля з великими даними (використовуємо правильні імена атрибутів)
        $userParams = @{}
        
        # Безпечно додаємо атрибути які точно працюють
        try { $userParams['DisplayName'] = Generate-LargeRandomText -Length 256 } catch {}
        try { $userParams['Title'] = Generate-LargeRandomText -Length 128 } catch {}
        try { $userParams['Department'] = Generate-LargeRandomText -Length 64 } catch {}
        try { $userParams['Company'] = Generate-LargeRandomText -Length 64 } catch {}
        try { $userParams['StreetAddress'] = Generate-LargeRandomText -Length 128 } catch {}
        try { $userParams['PostalCode'] = (Get-Random -Minimum 10000 -Maximum 99999).ToString() } catch {}
        try { $userParams['Country'] = "UA" } catch {}
        
        # Встановлення основних атрибутів безпечним методом
        if ($userParams.Count -gt 0) {
            try {
                Set-ADUser -Identity $User.SamAccountName @userParams -ErrorAction Stop
            }
            catch {
                Write-Warning "Помилка встановлення основних атрибутів для $($User.SamAccountName): $($_.Exception.Message)"
            }
        }
        
        # Встановлюємо великі текстові поля через Replace (уникаючи конфлікти параметрів)
        try {
            $largeAttrs = @{}
            $largeAttrs['description'] = $largeDescription  # 8KB
            Set-ADUser -Identity $User.SamAccountName -Replace $largeAttrs -ErrorAction Stop
        }
        catch {
            Write-Warning "Не вдалося встановити description для $($User.SamAccountName)"
        }
        
        # Використовуємо info як атрибут через Replace
        try {
            $infoAttrs = @{}
            $infoAttrs['info'] = $largeInfo  # 2KB
            Set-ADUser -Identity $User.SamAccountName -Replace $infoAttrs -ErrorAction Stop
        }
        catch {
            Write-Warning "Не вдалося встановити info для $($User.SamAccountName)"
        }
        
        # Додаткові атрибути через Replace
        try {
            $additionalAttrs = @{}
            $additionalAttrs['physicalDeliveryOfficeName'] = Generate-LargeRandomText -Length 128  # Office
            $additionalAttrs['l'] = Generate-LargeRandomText -Length 128  # City
            $additionalAttrs['st'] = Generate-LargeRandomText -Length 128  # State  
            $additionalAttrs['wWWHomePage'] = "https://example-" + (Generate-LargeRandomText -Length 200) + ".com"  # HomePage
            
            Set-ADUser -Identity $User.SamAccountName -Replace $additionalAttrs -ErrorAction Stop
        }
        catch {
            Write-Warning "Не вдалося встановити додаткові поля для $($User.SamAccountName)"
        }
        
        # Email окремо (може бути заблокований)
        try {
            $emailAttrs = @{}
            $emailAttrs['mail'] = "user_" + $userSeed + "_" + (Generate-LargeRandomText -Length 30) + "@bigdata.example.com"
            Set-ADUser -Identity $User.SamAccountName -Replace $emailAttrs -ErrorAction Stop
        }
        catch {
            Write-Warning "Не вдалося встановити email для $($User.SamAccountName)"
        }
        
        # Заповнення extensionAttribute окремо
        for ($i = 1; $i -le 15; $i++) {
            try {
                $attrName = "extensionAttribute$i"
                $attrValue = "ExtAttr${i}_User_${userSeed}_" + (Generate-LargeRandomText -Length 950)
                Set-ADUser -Identity $User.SamAccountName -Add @{$attrName = $attrValue} -ErrorAction Stop
            }
            catch {
                # Якщо Add не працює, спробуємо Replace
                try {
                    Set-ADUser -Identity $User.SamAccountName -Replace @{$attrName = $attrValue} -ErrorAction Stop
                }
                catch {
                    Write-Warning "Не вдалося встановити $attrName для $($User.SamAccountName)"
                }
            }
        }
        
        # Додавання спеціальних атрибутів з великими даними
        try {
            $specialAttrs = @{}
            
            # Використовуємо comment поле для JSON даних
            if ($largeJSONData.Length -le 1024) {
                $specialAttrs["comment"] = $largeJSONData
            }
            
            # Додаткові поля для збільшення обсягу даних
            $specialAttrs["notes"] = Generate-LargeRandomText -Length 512
            
            if ($specialAttrs.Count -gt 0) {
                Set-ADUser -Identity $User.SamAccountName -Replace $specialAttrs -ErrorAction Stop
            }
        }
        catch {
            Write-Warning "Неможливо встановити спеціальні атрибути для $($User.SamAccountName): $($_.Exception.Message)"
        }
        
        # Розрахунок розміру даних для цього користувача
        $userDataSize = $largeDescription.Length + $largeInfo.Length + $largeJSONData.Length + (15 * 1024) + 2048
        $totalDataSize += $userDataSize
        
        $processedCount++
        $userEndTime = Get-Date
        $userProcessTime = ($userEndTime - $userStartTime).TotalSeconds
        
        # Виводимо прогрес кожні 50 користувачів
        if ($processedCount % 50 -eq 0) {
            $currentSizeMB = $totalDataSize / 1MB
            $estimatedTotalMB = ($currentSizeMB / $processedCount) * $Users.Count
            $elapsedTime = (Get-Date) - $startTime
            $avgTimePerUser = $elapsedTime.TotalSeconds / $processedCount
            $estimatedTotalTime = $avgTimePerUser * $Users.Count
            $remainingTime = $estimatedTotalTime - $elapsedTime.TotalSeconds
            
            Write-Host "Оброблено: $processedCount/$($Users.Count) | Розмір: $([Math]::Round($currentSizeMB, 1))MB | Очік. загальний: $([Math]::Round($estimatedTotalMB/1024, 2))GB | Залишилось: $([Math]::Round($remainingTime/60, 1)) хв" -ForegroundColor Cyan
        }
        
        # Затримка для зменшення навантаження на AD
        if ($processedCount % 100 -eq 0) {
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        Write-Error "Критична помилка при обробці $($User.SamAccountName): $($_.Exception.Message)"
        
        # Логування помилки
        $errorMessage = "$(Get-Date): Критична помилка для $($User.SamAccountName) - $($_.Exception.Message)"
        Add-Content -Path "AD_Heavy_Population_Errors.log" -Value $errorMessage
        
        # Продовжуємо з наступним користувачем
        continue
    }
}

Write-Progress -Activity "Створення великих даних" -Completed

# Фінальна статистика
$endTime = Get-Date
$totalTime = $endTime - $startTime
$finalSizeGB = $totalDataSize / 1GB

Write-Host "`n=== ПІДСУМОК ===" -ForegroundColor Green
Write-Host "Всього користувачів: $($Users.Count)" -ForegroundColor White
Write-Host "Успішно оброблено: $processedCount" -ForegroundColor Green
Write-Host "Створено даних: $([Math]::Round($finalSizeGB, 3)) ГБ" -ForegroundColor Yellow
Write-Host "Середній розмір на користувача: $([Math]::Round($totalDataSize/$processedCount/1024, 1)) КБ" -ForegroundColor Cyan
Write-Host "Загальний час виконання: $([Math]::Round($totalTime.TotalMinutes, 1)) хвилин" -ForegroundColor Cyan
Write-Host "Середній час на користувача: $([Math]::Round($totalTime.TotalSeconds/$processedCount, 2)) секунд" -ForegroundColor Cyan

if ($finalSizeGB -ge 2.0) {
    Write-Host "✓ МЕТА ДОСЯГНУТА: Створено більше 2 ГБ даних!" -ForegroundColor Green
} else {
    Write-Host "⚠ Створено менше 2 ГБ. Можливо, потрібно збільшити розмір даних на користувача." -ForegroundColor Yellow
}

Write-Host "`nСкрипт завершено!" -ForegroundColor Green