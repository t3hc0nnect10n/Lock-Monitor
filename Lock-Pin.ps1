<#
.SYNOPSIS
    Version 1.0.0.0
    Сценарий запускает экран блокировки и снимает блокировку только после ввода корректного PIN.
    Работает совместно с Lock-Monitor.ps1 и использует lpaes.key/lpkey.txt/lprun.token.
    Назначение:
    Локальный "экран блокировки" с запросом PIN.
    PIN сверяется по SHA-256 хэшу, исходный PIN хранится в памяти минимально.
    Входные файлы (в C:\Windows\Temp):
        - lpaes.key      : AES-ключ
        - lpkey.txt      : зашифрованный PIN
        - lprun.token    : идентификатор запуска
    Выходной маркер:
        - lpunlock.ok    : токен успешной разблокировки
.DESCRIPTION
    |===========================================|
    |   Вспомогательные функции                 |
    |===========================================|
    |                                           |
    | Безопасность:                             |
    | - Get-StringSha256                        |
    | - Get-KeyBytesFromFile                    |
    | - Get-DecryptedPin                        |
    | - Write-UnlockMarkerAndCleanupSecretFiles |
    |                                           |
    | Защита сеанса:                            |
    | - Start-TaskManagerGuard                  |
    | - Stop-TaskManagerGuard                   |
    | - Complete-Unlock                         |
    |                                           |
    | GUI/ресурсы:                              |
    | - Resolve-ImagePath                       |
    | - New-PinForm                             |
    | - New-ImageForm                           |
    |                                           |
    |===========================================|

    |========================================|
    |         Основная механика экрана       |
    |========================================|
    | 1. Расшифровка PIN и подготовка хэша   |
    | 2. Создание форм на всех мониторах     |
    | 3. Блокировка горячих клавиш / TaskMgr |
    | 4. Проверка введенного PIN             |
    | 5. Запись маркера успеха и очистка     |
    | 6. Закрытие форм и снятие блокировок   |
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
    $namePNG = "<УКАЖИТЕ НАЗВАНИЕ КАРТИНКИ В ФОРМАТЕ PNG>"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Базовые пути к служебным файлам (по умолчанию рядом со скриптом/EXE)
$script:RemoteBasePath = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Windows\Temp' }
$script:Path_lpaes     = $script:RemoteBasePath
$script:Path_lpkey     = $script:RemoteBasePath
$script:Path_lprun     = $script:RemoteBasePath
$script:Path_lpunlock  = $script:RemoteBasePath

$script:LpAesFile        = Join-Path $script:Path_lpaes 'lpaes.key'
$script:LpKeyFile        = Join-Path $script:Path_lpkey 'lpkey.txt'
$script:RunTokenFile     = Join-Path $script:Path_lprun 'lprun.token'
$script:UnlockMarkerFile = Join-Path $script:Path_lpunlock 'lpunlock.ok'

function Get-StringSha256([string]$s) {
    # Хэширование строки PIN для сравнения без хранения "эталона" в открытом виде
    $bytes = [Text.Encoding]::UTF8.GetBytes($s)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    try {
        ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
}

function Get-KeyBytesFromFile {
    # Загрузка AES-ключа из текстового файла lpaes.key
    param([string]$Path)

    $rawKey = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
    $parts = $rawKey -split '[,\s]+' | Where-Object { $_ }
    $bytes = @($parts | ForEach-Object { [byte]$_ })

    if ($bytes.Count -notin 16,24,32) {
        throw "Неверная длина AES-ключа в lpaes.key. Ожидается 16/24/32 байта."
    }

    return [byte[]]$bytes
}

function Get-DecryptedPin {
    # Расшифровка PIN из lpkey.txt с ключом из lpaes.key
    # Временные секреты очищаются в finally
    param(
        [string]$Path_lpkey,
        [string]$Path_lpaes
    )

    $BSTR = [IntPtr]::Zero
    try {
        $Data = (Get-Content -LiteralPath (Join-Path $Path_lpkey 'lpkey.txt') -Raw -ErrorAction Stop).Trim()
        $Key = Get-KeyBytesFromFile -Path (Join-Path $Path_lpaes 'lpaes.key')
        $Pass = $Data | ConvertTo-SecureString -Key $Key

        Clear-Variable -Name "Data" -ErrorAction SilentlyContinue
        Clear-Variable -Name "Key" -ErrorAction SilentlyContinue

        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Pass)
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        return $Password
    }
    finally {
        if ($BSTR -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }

        Clear-Variable -Name "Pass" -ErrorAction SilentlyContinue
        Clear-Variable -Name "BSTR" -ErrorAction SilentlyContinue
    }
}

function Write-UnlockMarkerAndCleanupSecretFiles {
    # При успешном вводе PIN:
    # 1) пишем lpunlock.ok с токеном текущего запуска
    # 2) удаляем секретные файлы (ключ/зашифрованный PIN/токен запуска)
    $token = ''
    try {
        if (Test-Path -LiteralPath $script:RunTokenFile -PathType Leaf) {
            $token = (Get-Content -LiteralPath $script:RunTokenFile -Raw -ErrorAction Stop).Trim()
        }
    } catch {
        $token = ''
    }

    try {
        Set-Content -LiteralPath $script:UnlockMarkerFile -Value $token -Encoding ASCII -Force
    } catch {
        # Ошибки записи маркера не критичны при закрытии интерфейса
    }

    Remove-Item -LiteralPath $script:LpAesFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:LpKeyFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:RunTokenFile -Force -ErrorAction SilentlyContinue
}

try {
    # PIN нужен только для построения эталонного хэша
    $PlainPin = Get-DecryptedPin -Path_lpkey $script:Path_lpkey -Path_lpaes $script:Path_lpaes
    if ([string]::IsNullOrWhiteSpace($PlainPin)) {
        exit 1
    }
} catch {
    exit 1
}

$pinHashTarget = Get-StringSha256 -s $PlainPin
$PlainPin = $null

$script:IsAuthenticated = $false
$script:forms = @()
$script:ImageFileName = $namePNG
$script:TaskMgrGuardTimer = $null

function Start-TaskManagerGuard {
    # Таймер-защита: пока PIN не введён, закрывает Task Manager
    if ($script:TaskMgrGuardTimer) {
        return
    }

    $guardTick = {
        if (-not $script:IsAuthenticated) {
            Get-Process -Name 'Taskmgr' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    Stop-Process -Id $_.Id -Force -ErrorAction Stop
                } catch {
                    # Игнорируем гонки состояний при завершении Диспетчера задач
                }
            }
        }
    }.GetNewClosure()

    $script:TaskMgrGuardTimer = New-Object System.Windows.Forms.Timer
    $script:TaskMgrGuardTimer.Interval = 250
    $script:TaskMgrGuardTimer.Add_Tick($guardTick)
    & $guardTick
    $script:TaskMgrGuardTimer.Start()
}

function Stop-TaskManagerGuard {
    # Корректная остановка и освобождение ресурсов таймера
    if ($script:TaskMgrGuardTimer) {
        try {
            $script:TaskMgrGuardTimer.Stop()
        } catch {
            # Игнорируем ошибки остановки таймера
        }
        try {
            $script:TaskMgrGuardTimer.Dispose()
        } catch {
            # Игнорируем ошибки освобождения таймера
        }
        $script:TaskMgrGuardTimer = $null
    }
}

function Complete-Unlock {
    # Общая точка завершения после успешной авторизации:
    # снимаем блокировки клавиш/TaskMgr и закрываем все формы
    $script:IsAuthenticated = $true
    Stop-TaskManagerGuard
    try {
        if ('GlobalKeyboardBlocker' -as [type]) {
            [GlobalKeyboardBlocker]::Uninstall()
        }
    } catch {
        # Игнорируем ошибки очистки клавиатурного хука
    }

    foreach ($frm in @($script:forms)) {
        if ($frm -and -not $frm.IsDisposed) {
            try {
                $frm.Close()
            } catch {
                # Игнорируем ошибки закрытия форм при завершении
            }
        }
    }

    [System.Windows.Forms.Application]::ExitThread()
}

function Resolve-ImagePath {
    # Поиск изображения для вторичных мониторов:
    # рядом со скриптом, рядом с EXE, затем в текущей директории
    param([string]$FileName)

    $candidates = @()
    if ($PSScriptRoot) {
        $candidates += (Join-Path -Path $PSScriptRoot -ChildPath $FileName)
    }

    try {
        $exePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $exeDir = [IO.Path]::GetDirectoryName($exePath)
        if ($exeDir) {
            $candidates += (Join-Path -Path $exeDir -ChildPath $FileName)
        }
    } catch {
        # Игнорируем ошибку и продолжаем проверку других путей
    }

    $candidates += (Join-Path -Path (Get-Location).Path -ChildPath $FileName)

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

$script:ImagePath = Resolve-ImagePath -FileName $script:ImageFileName

$source = @"
using System;
using System.Windows.Forms;
public class NoMoveForm : Form {
    private const int WM_NCLBUTTONDOWN = 0xA1;
    private const int HTCAPTION = 2;
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_NCLBUTTONDOWN && (int)m.WParam == HTCAPTION) {
            return;
        }
        base.WndProc(ref m);
    }
}
"@
if (-not ('NoMoveForm' -as [type])) {
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms -IgnoreWarnings
}

$keyboardHookSource = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class GlobalKeyboardBlocker
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;

    private const int VK_ESCAPE = 0x1B;
    private const int VK_TAB = 0x09;
    private const int VK_R = 0x52;
    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int VK_LSHIFT = 0xA0;
    private const int VK_RSHIFT = 0xA1;
    private const int VK_LMENU = 0xA4;
    private const int VK_RMENU = 0xA5;
    private const int VK_LWIN = 0x5B;
    private const int VK_RWIN = 0x5C;

    private static IntPtr _hookId = IntPtr.Zero;
    private static LowLevelKeyboardProc _proc = HookCallback;

    public static void Install()
    {
        if (_hookId != IntPtr.Zero) return;
        _hookId = SetHook(_proc);
    }

    public static void Uninstall()
    {
        if (_hookId == IntPtr.Zero) return;
        UnhookWindowsHookEx(_hookId);
        _hookId = IntPtr.Zero;
    }

    private static IntPtr SetHook(LowLevelKeyboardProc proc)
    {
        using (Process curProcess = Process.GetCurrentProcess())
        using (ProcessModule curModule = curProcess.MainModule)
        {
            return SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(curModule.ModuleName), 0);
        }
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
            {
                int vkCode = Marshal.ReadInt32(lParam);

                bool ctrl = (GetAsyncKeyState(VK_LCONTROL) & 0x8000) != 0 || (GetAsyncKeyState(VK_RCONTROL) & 0x8000) != 0;
                bool shift = (GetAsyncKeyState(VK_LSHIFT) & 0x8000) != 0 || (GetAsyncKeyState(VK_RSHIFT) & 0x8000) != 0;
                bool alt = (GetAsyncKeyState(VK_LMENU) & 0x8000) != 0 || (GetAsyncKeyState(VK_RMENU) & 0x8000) != 0;
                bool win = (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 || (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;

                // Block Ctrl+Shift+Esc
                if (vkCode == VK_ESCAPE && ctrl && shift)
                {
                    return (IntPtr)1;
                }

                // Block Win+R
                if (vkCode == VK_R && win)
                {
                    return (IntPtr)1;
                }

                // Block Alt+Tab and Win+Tab
                if (vkCode == VK_TAB && (alt || win))
                {
                    return (IntPtr)1;
                }

                // Block standalone Win key (Start menu)
                if (vkCode == VK_LWIN || vkCode == VK_RWIN)
                {
                    return (IntPtr)1;
                }
            }
        }

        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
}
"@

if (-not ('GlobalKeyboardBlocker' -as [type])) {
    Add-Type -TypeDefinition $keyboardHookSource -IgnoreWarnings
}

function New-PinForm {
    # Основная форма ввода PIN (primary monitor)
    param($screen)

    $form = New-Object NoMoveForm
    $form.Text              = 'Требуется PIN'
    $form.TopMost           = $true
    $form.FormBorderStyle   = 'None'
    $form.ControlBox        = $false
    $form.MinimizeBox       = $false
    $form.MaximizeBox       = $false
    $form.ShowInTaskbar     = $true
    $form.KeyPreview        = $true
    $form.StartPosition     = 'Manual'
    $form.Location          = $screen.Bounds.Location
    $form.Size              = $screen.Bounds.Size

    # --- Элементы управления ---
    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text      = 'При возникновении проблем обратитесь в IT-отдел.'
    $lblInfo.Font      = New-Object System.Drawing.Font('Segoe UI',14,[System.Drawing.FontStyle]::Italic)
    $lblInfo.ForeColor = [System.Drawing.Color]::Olive
    $lblInfo.TextAlign = [System.Drawing.ContentAlignment]::TopCenter
    $lblInfo.AutoSize  = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text      = 'Введите PIN для закрытия:'
    $lbl.Font      = New-Object System.Drawing.Font('Segoe UI',32,[System.Drawing.FontStyle]::Bold)
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $lbl.AutoSize  = $false

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Font       = New-Object System.Drawing.Font('Segoe UI',24)
    $tb.Width      = [math]::Min(500, [math]::Round($form.Width * 0.4))
    $tb.Height     = 50
    $tb.UseSystemPasswordChar = $true
    $tb.TabIndex   = 0

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = 'OK'
    $btnOk.Font     = New-Object System.Drawing.Font('Segoe UI',19)
    $btnOk.Size     = New-Object System.Drawing.Size(140,52)
    $btnOk.TabIndex = 1

    $err = New-Object System.Windows.Forms.Label
    $err.ForeColor = [System.Drawing.Color]::Firebrick
    $err.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $err.Font      = New-Object System.Drawing.Font('Segoe UI',16)
    $err.AutoSize  = $false
    $err.Visible   = $false

    $form.Controls.AddRange(@($lblInfo,$lbl,$tb,$btnOk,$err))

    $centerControls = {
        # Задаём ширину метка/ошибки/инфо по всей форме каждый раз
        $lbl.Width     = $form.Width
        $lblInfo.Width = $form.Width
        $err.Width     = $form.Width

        $lblInfo.Height = 30
        $lbl.Height = 70
        $tb.Height = 50
        $btnOk.Height = 52
        $err.Height = 36

        # Подсчитем общую высоту блока
        $gap1 = 10
        $gap2 = 34
        $gap3 = 28
        $gap4 = 10
        $totalBlockHeight = $lbl.Height + $gap1 + $tb.Height + $gap2 + $btnOk.Height + $gap3 + $err.Height

        # Центр блока по высоте (20 - отступ для $lblInfo сверху)
        $startY = [math]::Round(($form.Height - $totalBlockHeight) / 2) + 20

        # Верхняя информационная надпись - всегда сверху
        $lblInfo.Top = 20
        $lblInfo.Left = 0

        # Центрируем основной блок
        $lbl.Top = $startY
        $lbl.Left = 0

        $tb.Left = [math]::Round(($form.Width - $tb.Width) / 2)
        $tb.Top = $lbl.Bottom + $gap1

        $btnOk.Left  = [math]::Round(($form.Width - $btnOk.Width) / 2)
        $btnOk.Top = $tb.Bottom + $gap2

        $err.Top = $btnOk.Bottom + $gap3
        $err.Left = 0
    }.GetNewClosure()
    $form.add_Resize({ & $centerControls }.GetNewClosure())

    $form.add_FormClosing({
        param($sender,$e)
        if (-not $script:IsAuthenticated) {
            $e.Cancel = $true
        }
    }.GetNewClosure())

    $form.add_KeyDown({
        param($sender,$e)
        if (($e.Alt -and $e.KeyCode -eq 'F4') -or ($e.KeyCode -eq 'Escape')) {
            $e.Handled = $true
            $e.SuppressKeyPress = $true
        }
    }.GetNewClosure())

    $checkPin = {
        # Сравнение выполняется только по SHA-256 хэшу введённого PIN
        $err.Visible = $false
        $pinHashTry = Get-StringSha256 -s $tb.Text
        if ($pinHashTry -eq $pinHashTarget) {
            Write-UnlockMarkerAndCleanupSecretFiles
            Complete-Unlock
        } else {
            $err.Text = 'Неверный PIN. Попробуйте ещё раз.'
            $err.Visible = $true
            & $centerControls
            $tb.Clear()
            $tb.Focus()
        }
    }.GetNewClosure()
    $btnOk.Add_Click($checkPin)
    $tb.Add_KeyDown({
        param($s,$e)
        if ($e.KeyCode -eq 'Enter') {
            & $checkPin
        }
    }.GetNewClosure())

    $form.Add_Shown({
        & $centerControls
        $tb.Focus()
    }.GetNewClosure())

    return $form
}

function New-ImageForm {
    # Полноэкранная форма-картинка для остальных мониторов
    param($screen, $imagePath)

    $form = New-Object NoMoveForm
    $form.Text              = 'Lock Screen'
    $form.TopMost           = $true
    $form.FormBorderStyle   = 'None'
    $form.ControlBox        = $false
    $form.MinimizeBox       = $false
    $form.MaximizeBox       = $false
    $form.ShowInTaskbar     = $false
    $form.KeyPreview        = $true
    $form.StartPosition     = 'Manual'
    $form.Location          = $screen.Bounds.Location
    $form.Size              = $screen.Bounds.Size
    $form.BackColor         = [System.Drawing.Color]::Black

    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.Dock     = [System.Windows.Forms.DockStyle]::Fill
    $picture.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
    $picture.BackColor = [System.Drawing.Color]::Black

    if ($imagePath) {
        try {
            $picture.Image = [System.Drawing.Image]::FromFile($imagePath)
        } catch {
            $picture.Image = $null
            $form.BackColor = [System.Drawing.Color]::Black
        }
    }

    $form.Controls.Add($picture)

    $form.add_FormClosing({
        param($sender,$e)
        if (-not $script:IsAuthenticated) {
            $e.Cancel = $true
        }
    }.GetNewClosure())

    $form.add_KeyDown({
        param($sender,$e)
        if (($e.Alt -and $e.KeyCode -eq 'F4') -or ($e.KeyCode -eq 'Escape')) {
            $e.Handled = $true
            $e.SuppressKeyPress = $true
        }
    }.GetNewClosure())

    $form.Add_FormClosed({
        if ($picture.Image) {
            $picture.Image.Dispose()
            $picture.Image = $null
        }
    }.GetNewClosure())

    return $form
}

$allScreens = [System.Windows.Forms.Screen]::AllScreens
$primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
$script:forms = @()
foreach ($screen in $allScreens) {
    # На главном мониторе — PIN-форма, на остальных — фон-картинка
    if ($screen.Primary -or ($primaryScreen -and $screen.DeviceName -eq $primaryScreen.DeviceName)) {
        $script:forms += (New-PinForm -screen $screen)
    } else {
        $script:forms += (New-ImageForm -screen $screen -imagePath $script:ImagePath)
    }
}

try {
    # Глобальный low-level hook блокирует горячие клавиши выхода
    [GlobalKeyboardBlocker]::Install()
} catch {
    # Продолжаем выполнение, даже если клавиатурный хук не удалось установить
}
Start-TaskManagerGuard

foreach ($f in $script:forms) { $null = $f.Show() }
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    Stop-TaskManagerGuard
    try {
        [GlobalKeyboardBlocker]::Uninstall()
    } catch {
        # Игнорируем ошибки очистки клавиатурного хука
    }

}



