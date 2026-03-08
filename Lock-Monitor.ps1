<#
.SYNOPSIS
	Version 1.0.0.0 
	Сценарий предназначен для удаленной блокировки пользовательской сессии до ввода PIN-кода.
    Работает совместно с Lock-Pin.ps1.
    Назначение:
    - Подготовить удалённый хост (копия Lock Pin.exe, PNG, ключа и зашифрованного PIN).
    - Запустить блокирующее окно через планировщик задач в контексте пользователя.
    - Мониторить состояние блокировки, включая перезапуск после reboot.
    - После успешного ввода PIN удалить все следы (задача + временные файлы).
.DESCRIPTION
    |=========================================|
    |     Основная механика блокировки        |
    |=========================================|
    | 1. Проверка сервера и пользователя      |
    | 2. Генерация и шифрование PIN           |
    | 3. Копирование файлов на удаленный ПК   |
    | 4. Регистрация и запуск задачи          |
    | 5. Мониторинг / перезапуск после reboot |
    | 6. Финальная очистка артефактов         |
    |=========================================|

	|========================================|
	|   Вспомогательные функции              |
	|========================================|
	|                                        |
	| Ввод и проверки:                       |
	| - Set-Server                           |
	| - Set-User                             |
	|                                        |
	| Криптография:                          |
	| - Get-KeyBytesFromFile                 |
	| - Get-EncryptedPinPayload              |
	|                                        |
	| Работа с удаленной задачей:            |
	| - Register-LockPinTask                 |
	| - Start-LockPinTask                    |
	| - Get-RemoteState                      |
	| - Cleanup-RemoteArtifacts              |
	|                                        |
	|========================================|

	Для работы сценария требуется настроенная служба - Windows Remote Management (WinRM).
    https://learn.microsoft.com/en-us/windows/win32/winrm/portal

    Перед первым запуском может потребоваться установить политику выполнения PowerShell, например:
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
    (при изменении политики для всей системы могут потребоваться права администратора).
.COPYRIGHT
    Автор: t3hc0nnect10n
    Лицензия: CC BY-NC 4.0
    (c) 2026 t3hc0nnect10n
#>

# Параметры
param(
    $sourceSRV = "<УКАЖИТЕ НАЗВАНИЕ СЕРВЕРА ГДЕ ХРАНЯТСЯ СКРИПТЫ>",
    $namePNG   = "<УКАЖИТЕ НАЗВАНИЕ КАРТИНКИ В ФОРМАТЕ PNG>"
)

function Set-Server {
    # Интерактивный выбор сервера с двойной проверкой:
    # существование в AD + доступность по сети (ICMP)
    while ($true) {
        echo ""
        Write-Host "Введите имя сервера" -ForegroundColor Yellow
        Write-Host "Пример: " -ForegroundColor Yellow -NoNewline
        Write-Host "SRV-1C-01" -ForegroundColor Gray
        [string]$InputServer = (Read-Host "Сервер").ToUpper()

        if (-Not ($InputServer -like $null)) {
            try {
                $ADServer = Get-ADComputer $InputServer -ErrorAction Stop
                if ($ADServer) {
                    try {
                        $TestConnection = Test-Connection $InputServer -Count 1 -ErrorAction Stop
                        if ($TestConnection) {
                            echo ""
                            Start-Sleep -Milliseconds 500
                            Write-Host "ОК" -ForegroundColor Green
                            $Global:SetServer = $InputServer
                            break
                        }
                    } catch {
                        echo ""
                        Start-Sleep -Milliseconds 500
                        Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
                        Write-Host "Сервер " -NoNewline
                        Write-Host "$($InputServer) " -ForegroundColor Gray -NoNewline
                        Write-Host "не в сети."
                    }
                }
            } catch {
                echo ""
                Start-Sleep -Milliseconds 500
                Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
                Write-Host "Сервер " -NoNewline
                Write-Host "$($InputServer) " -ForegroundColor Gray -NoNewline
                Write-Host "не существует."
            }
        } else {
            echo ""
            Start-Sleep -Milliseconds 500
            Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
            Write-Host "Введено пустое значение."
        }
    }
}

function Set-User {
    # Интерактивный выбор пользователя с проверкой существования в AD
    while ($true) {
        echo ""
        Write-Host "Введите логин пользователя" -ForegroundColor Yellow
        Write-Host "Пример: " -ForegroundColor Yellow -NoNewline
        Write-Host "ivanov" -ForegroundColor Gray
        [string]$InputUser = Read-Host "User"

        if (-Not ($InputUser -like $null)) {
            try {
                if (Get-ADUser $InputUser -ErrorAction Stop) {
                    echo ""
                    Start-Sleep -Milliseconds 500
                    Write-Host "ОК" -ForegroundColor Green
                    $Global:SetUser = $InputUser
                    break
                }
            } catch {
                echo ""
                Start-Sleep -Milliseconds 500
                Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
                Write-Host "Пользователя " -NoNewline
                Write-Host "$($InputUser) " -ForegroundColor Gray -NoNewline
                Write-Host "не существует."
            }
        } else {
            echo ""
            Start-Sleep -Milliseconds 500
            Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
            Write-Host "Введено пустое значение."
        }
    }
}

function Get-KeyBytesFromFile {
    # Чтение AES-ключа из файла lpaes.key в формате "byte,byte,..."
    param([string]$Path)

    $rawKey = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
    $parts = $rawKey -split '[,\s]+' | Where-Object { $_ }
    $bytes = @($parts | ForEach-Object { [byte]$_ })

    if ($bytes.Count -notin 16,24,32) {
        throw "Неверная длина ключа в lpaes.key. Ожидается 16/24/32 байта."
    }

    return [byte[]]$bytes
}

function Get-EncryptedPinPayload {
    # Шифрует PIN в строку ConvertFrom-SecureString с использованием AES-ключа
    param(
        [string]$PinCode,
        [string]$KeyFilePath
    )

    $keyBytes = Get-KeyBytesFromFile -Path $KeyFilePath
    $securePin = ConvertTo-SecureString -String $PinCode -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString -SecureString $securePin -Key $keyBytes

    [PSCustomObject]@{
        EncryptedPin  = $encrypted
    }
}

function Register-LockPinTask {
    # Создание/обновление задачи планировщика на удалённом ПК:
    # запуск Lock Pin.exe при логоне выбранного пользователя
    param(
        [string]$Server,
        [string]$TaskName,
        [string]$UserPrincipal,
        [string]$ExeRemote
    )

    Invoke-Command -ComputerName $Server -ScriptBlock {
        param($TaskName, $UserPrincipal, $ExeRemote)

        $Action     = New-ScheduledTaskAction -Execute $ExeRemote
        $Trigger    = New-ScheduledTaskTrigger -AtLogOn -User $UserPrincipal
        $Principal  = New-ScheduledTaskPrincipal -UserId $UserPrincipal -LogonType Interactive -RunLevel Highest

        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Force | Out-Null
    } -ArgumentList $TaskName, $UserPrincipal, $ExeRemote -ErrorAction Stop
}

function Start-LockPinTask {
    # Принудительный запуск ранее зарегистрированной задачи
    param([string]$Server, [string]$TaskName)

    Invoke-Command -ComputerName $Server -ScriptBlock {
        param($TaskName)
        Start-ScheduledTask -TaskName $TaskName
    } -ArgumentList $TaskName -ErrorAction Stop
}

function Get-RemoteState {
    # Сбор состояния удалённого ПК для цикла мониторинга:
    # - время последней загрузки (детект reboot)
    # - активность целевого пользователя (наличие explorer.exe в его сессии)
    # - запущен ли Lock Pin.exe
    # - маркер успешной разблокировки
    param(
        [string]$Server,
        [string]$UserPrincipal,
        [string]$SuccessMarkerPath,
        [string]$ExeRemote
    )

    Invoke-Command -ComputerName $Server -ScriptBlock {
        param($UserPrincipal, $SuccessMarkerPath, $ExeRemote)

        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $bootTime = $os.LastBootUpTime

        $isUserActive = [bool](Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object {
            $_.UserName -eq $UserPrincipal
        })

        $exeName = [IO.Path]::GetFileName($ExeRemote)
        $lockPinRunning = [bool](Get-CimInstance -ClassName Win32_Process -Filter ("Name = '{0}'" -f $exeName) -ErrorAction SilentlyContinue | Where-Object {
            $_.SessionId -gt 0
        })

        $successToken = $null
        if (Test-Path -LiteralPath $SuccessMarkerPath -PathType Leaf) {
            $successToken = (Get-Content -LiteralPath $SuccessMarkerPath -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($successToken) { $successToken = $successToken.Trim() }
        }

        [PSCustomObject]@{
            BootTime      = $bootTime
            IsUserActive  = $isUserActive
            IsPinRunning  = $lockPinRunning
            SuccessToken  = $successToken
        }
    } -ArgumentList $UserPrincipal, $SuccessMarkerPath, $ExeRemote -ErrorAction Stop
}

function Cleanup-RemoteArtifacts {
    # Финальная очистка: удаление scheduled task и временных файлов
    param(
        [string]$Server,
        [string]$TaskName,
        [string[]]$FilesToDelete
    )

    Invoke-Command -ComputerName $Server -ScriptBlock {
        param($TaskName, $FilesToDelete)

        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        foreach ($item in $FilesToDelete) {
            Remove-Item -LiteralPath $item -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $TaskName, $FilesToDelete -ErrorAction Stop
}

# ----------------------------------------------
# Заголовок
# ----------------------------------------------

echo ""
Write-Host "Made by t3hc0nnect10n (c) 2026" -ForegroundColor Gray
Write-Host "Version 1.0" -ForegroundColor Gray

echo ""
Write-Host "########################################################################" -ForegroundColor Magenta
Write-Host "# Hellow Senior System Administrator, Lets go block user and help him! #" -ForegroundColor Magenta
Write-Host "########################################################################" -ForegroundColor Magenta

Start-Sleep -Seconds 1
Set-Server
Start-Sleep -Seconds 1
Set-User
Start-Sleep -Seconds 1

if ($SetServer -and $SetUser) {
    
    # Получаем домен автоматически из текущего пользователя
	$defaultDomain = $null
	try {
		# Пробуем получить домен из переменной окружения
		if (-not [string]::IsNullOrEmpty($env:USERDOMAIN)) {
			$defaultDomain = $env:USERDOMAIN
		} else {
			# Если не получилось, пробуем через WMI
			$defaultDomain = (Get-WmiObject Win32_ComputerSystem).Domain
			# Если домен в формате FQDN (например, domain.local), берём только первую часть
			if ($defaultDomain -match "^([^.]+)") {
				$defaultDomain = $matches[1]
			}
		}
	}
	catch {
		# Если не удалось получить домен, используем пустую строку
		$defaultDomain = ""
	}

    # Нормализация исходных параметров и служебных путей
    $Server = $SetServer
    $UserName = $SetUser
    $UserPrincipal = "$($defaultDomain)\$($UserName)"
    $TaskName = "LockPinTask"

    $RemoteDir     = "C:\Windows\Temp"
    $ScriptRemote  = Join-Path $RemoteDir "Lock Pin.exe"
    $PngRemote     = Join-Path $RemoteDir "$($namePNG)"
    $KeyRemote     = Join-Path $RemoteDir "lpaes.key"
    $PinRemote     = Join-Path $RemoteDir "lpkey.txt"
    $TokenRemote   = Join-Path $RemoteDir "lprun.token"
    $SuccessRemote = Join-Path $RemoteDir "lpunlock.ok"

    $SourceScript = "\\$($sourceSRV)\Lock_Pin\Lock Pin.exe"
    $SourcePng    = "\\$($sourceSRV)\Lock_Pin\$($namePNG)"
    $LocalAES     = "\\$($sourceSRV)\Lock_Pin\lpaes.key"

    # Предварительные проверки обязательных исходных файлов
    if (-not (Test-Path -LiteralPath $SourceScript -PathType Leaf)) {
        Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
        Write-Host "Не найден файл Lock Pin.exe на $($sourceSRV)."
        exit 1
    }

    if (-not (Test-Path -LiteralPath $SourcePng -PathType Leaf)) {
        Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
        Write-Host "Не найден файл $($namePNG) на $($sourceSRV)."
        exit 1
    }

    if (-not (Test-Path -LiteralPath $LocalAES -PathType Leaf)) {
        Write-Host "ОШИБКА: " -ForegroundColor Red -NoNewline
        Write-Host "Не найден файл lpaes.key рядом с Lock-Monitor.ps1."
        exit 1
    }

    $RandInt = Get-Random -Minimum 1000 -Maximum 10000
    # PIN шифруется до передачи на удалённый ПК, в открытом виде хранится только в памяти текущей консоли
    $payload = Get-EncryptedPinPayload -PinCode "$RandInt" -KeyFilePath $LocalAES
    # Уникальный токен запуска связывает конкретный "сеанс блокировки" с фактом успешной разблокировки
    $RunToken = [Guid]::NewGuid().ToString("N")

    echo ""
    Write-Warning "Если закрыть эту консоль, то потеряешь PIN-CODE и мониторинг завершится."
    echo ""
    Write-Host "PIN-CODE: " -ForegroundColor Green -NoNewline
    Write-Host "$RandInt"
    echo ""

    try {
        # Подготовка артефактов на удалённом ПК
        Copy-Item -LiteralPath $SourceScript -Destination "\\$Server\C$\Windows\Temp\Lock Pin.exe" -Force
        Copy-Item -LiteralPath $SourcePng -Destination "\\$Server\C$\Windows\Temp\$($namePNG)" -Force
        Copy-Item -LiteralPath $LocalAES -Destination "\\$Server\C$\Windows\Temp\lpaes.key" -Force

        Set-Content -LiteralPath "\\$Server\C$\Windows\Temp\lpkey.txt" -Value $payload.EncryptedPin -Encoding ASCII -Force
        Set-Content -LiteralPath "\\$Server\C$\Windows\Temp\lprun.token" -Value $RunToken -Encoding ASCII -Force
        Remove-Item -LiteralPath "\\$Server\C$\Windows\Temp\lpunlock.ok" -Force -ErrorAction SilentlyContinue

        Register-LockPinTask -Server $Server -TaskName $TaskName -UserPrincipal $UserPrincipal -ExeRemote $ScriptRemote
    } catch {
        Write-Host "ОШИБКА подготовки на удаленном ПК: " -ForegroundColor Red -NoNewline
        Write-Host "Не удалось выполнить подготовку (без подробностей)."
        exit 1
    }

    $lastBootTime = $null
    $hadReboot    = $false

    # Основной мониторинговый цикл:
    # следит за reboot, активной сессией пользователя и состоянием процесса блокировки
    while ($true) {
        try {
            $state = Get-RemoteState -Server $Server -UserPrincipal $UserPrincipal -SuccessMarkerPath $SuccessRemote -ExeRemote $ScriptRemote
        } catch {
            Write-Host "Нет связи с ${Server}. Повтор через 1 секунд..." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }

        if (-not $lastBootTime) {
            $lastBootTime = $state.BootTime
        } elseif ($state.BootTime -ne $lastBootTime) {
            $lastBootTime = $state.BootTime
            $hadReboot = $true
            Write-Host "Обнаружена перезагрузка $Server. Ожидание входа пользователя..." -ForegroundColor Yellow
        }

        if ($state.SuccessToken -eq $RunToken -and -not $state.IsPinRunning) {
            Write-Host ""
            Write-Host "PIN-CODE успешно введён, блокировка снята. Запущена финальная очистка..." -ForegroundColor Green
            break
        }

        if ($state.IsUserActive -and -not $state.IsPinRunning) {
            try {
                # Самовосстановление: если окно блокировки закрыто/не запущено, стартуем задачу снова
                Start-LockPinTask -Server $Server -TaskName $TaskName
                if ($hadReboot) {
                    Write-Host "Пользователь снова в системе. Lock-Pin запущен повторно." -ForegroundColor Yellow
                    $hadReboot = $false
                }
            } catch {
                Write-Host "Не удалось перезапустить Lock-Pin на ${Server}. Повтор будет выполнен автоматически." -ForegroundColor Yellow
            }
        }

        Start-Sleep -Seconds 1
    }

    # Цикл надёжной очистки: повторяет попытки, пока связь с хостом не восстановится
    while ($true) {
        try {
            Cleanup-RemoteArtifacts -Server $Server -TaskName $TaskName -FilesToDelete @(
                $ScriptRemote, $PngRemote, $KeyRemote, $PinRemote, $TokenRemote, $SuccessRemote
            )
            Write-Host "Финальная очистка завершена: задача и файлы удалены." -ForegroundColor Green
            break
        } catch {
            Write-Host "Не удалось выполнить финальную очистку на ${Server}." -ForegroundColor Yellow
            Write-Host "Ожидание восстановления связи и повтор..." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

echo ""

Read-Host "Для завершения нажмите клавишу `"Enter`""



