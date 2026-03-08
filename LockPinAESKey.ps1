<#
.SYNOPSIS
    Version 1.0.0.0
    Сценарий генерирует AES-ключ для шифрования PIN-кода и сохраняет его
    в сетевую папку, откуда ключ используют Lock-Monitor.ps1 и Lock-Pin.ps1.
    Назначение:
    Генерирует AES-ключ для шифрования PIN-кода и сохраняет его в сетевую папку.
    Важно:
        - Скрипт предполагает существование сетевого пути \\<server>\Lock_Pin
        - Ключ обязателен для связки Lock-Monitor.ps1 <-> Lock-Pin.ps1
.DESCRIPTION
    |==========================================|
    |   Вспомогательные операции               |
    |==========================================|
    | - Формирование сетевого пути             |
    | - Создание резервной копии ключа         |
    | - Переименование backup с датой/временем |
    | - Вывод popup-уведомления                |
    |==========================================|
    
    |========================================|
    |       Основная механика сценария       |
    |========================================|
    | 1. Генерация случайного AES-ключа      |
    | 2. Сохранение ключа в lpaes.key        |
    | 3. Копирование ключа в backup_key      |
    | 4. Контрольное уведомление оператору   |
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
    # Сервер, на котором хранится общая папка со скриптами и ключом
    $sourceSRV = "<УКАЖИТЕ НАЗВАНИЕ СЕРВЕРА ГДЕ ХРАНЯТСЯ СКРИПТЫ>"
)

# Базовый сетевой путь, где лежат артефакты Lock Pin
$Path = "\\$($sourceSRV)\Lock_Pin"

# Генерация криптографически стойкого AES-ключа длиной 32 байта (AES-256)
$AESKey = New-Object Byte[] 32
[Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($AESKey)

# Сохранение ключа в рабочий файл lpaes.key
$AESKey | Out-File "$($Path)\lpaes.key"

# Резервная копия ключа в папку backup_key (если папка существует)
Copy-Item -Path "$($Path)\lpaes.key" -Destination "$($Path)\backup_key" -Force -ErrorAction SilentlyContinue

Start-Sleep -Milliseconds 500

# Переименование резервной копии в формат с отметкой даты/времени
if (Test-Path -Path "$($Path)\backup_key\lpaes.key") {
    
    Rename-Item -Path "$($Path)\backup_key\lpaes.key" -NewName "lpaes_$(Get-Date -Format "yyyy_MM_dd_hhmmss").key"
}

# Визуальное подтверждение для оператора
$shell = New-Object -ComObject Wscript.Shell

[void]($shell.popup("Создан закрытый ключ.`n$($Path)\lpaes.key", 0, "Результат", 0 + 64 + 4096))
