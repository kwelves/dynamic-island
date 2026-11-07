<#
.SYNOPSIS
    Собирает моды из репозитория и устанавливает их в Windhawk как локальные:
      - local@dynamic-island-topbar-dev     — бар и остров (dynamic-island-for-windows.wh.cpp);
      - local@dynamic-island-tray-bridge-dev — мост трея внутри Explorer (dynamic-island-tray-bridge.wh.cpp).
    Windhawk сам перезапускает моды.

.DESCRIPTION
    Повторяет то, что делает кнопка «Compile Mod» в редакторе Windhawk 1.7.3:

      1. Компилирует каждый мод компилятором Windhawk (clang++) с теми же
         флагами, для 32- и 64-битных процессов, в DLL с новым случайным
         именем. Компиляция идёт без прав администратора; ошибки видны сразу.
      2. С правами администратора (одно окно UAC на все моды), для каждого мода:
         - кладёт DLL в Engine\Mods\32 и Engine\Mods\64;
         - дописывает в реестр значения по умолчанию для НОВЫХ настроек
           (существующие значения не трогает);
         - отключает мод и ждёт, пока старая DLL выгрузится (процесс мода
           у бара, explorer.exe у моста), обновляет запись мода в реестре,
           копирует исходник в ModsSource и включает мод снова;
         - удаляет старые DLL этого мода (занятые оставляет).
         Мост трея, если его ещё нет в Windhawk, заводится так же, как это
         делает Windhawk: ключ в Engine\Mods и исходник в ModsSource.
      3. Ждёт, пока новая версия загрузится.

    Чужие моды скрипт не трогает: имена модов зашиты в скрипт и сверяются с
    @id в исходниках, а все пути и ключи реестра строятся только от них.

    Если что-то не сходится (другая версия Windhawk, portable-установка, бара
    ещё нет в Windhawk, непонятный блок настроек), скрипт ничего не меняет и
    переходит к запасному варианту: копирует исходник бара в буфер обмена и
    открывает Windhawk.

.PARAMETER Mod
    Какие моды собрать и поставить: all (по умолчанию), topbar или tray.

.PARAMETER ClipboardOnly
    Сразу запасной вариант: исходник бара в буфер обмена + открыть Windhawk.

.PARAMETER BuildOnly
    Только скомпилировать (проверка сборки), ничего не устанавливать.

.PARAMETER Force
    Разрешить установку на версии Windhawk, отличной от проверенной (1.7.3).

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -Mod tray
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'topbar', 'tray')]
    [string]$Mod = 'all',
    [switch]$ClipboardOnly,
    [switch]$BuildOnly,
    [switch]$Force,

    # Внутренние параметры: так скрипт вызывает сам себя с правами администратора.
    [string]$InstallFrom,
    [string]$LogFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ── Константы ─────────────────────────────────────────────────────────────────
# Name — для -Mod; Id — @id в исходнике; Tool — мод живёт в своём процессе
# windhawk.exe -tool-mod (иначе внедряется в explorer.exe); CanCreate — скрипту
# можно самому завести мод в Windhawk, если его там ещё нет.
$ModDefs = @(
    [pscustomobject]@{ Name = 'topbar'; Id = 'dynamic-island-topbar-dev'; File = 'dynamic-island-for-windows.wh.cpp'; Tool = $true; CanCreate = $false }
    [pscustomobject]@{ Name = 'tray'; Id = 'dynamic-island-tray-bridge-dev'; File = 'dynamic-island-tray-bridge.wh.cpp'; Tool = $false; CanCreate = $true }
)
foreach ($d in $ModDefs) {
    $d | Add-Member -NotePropertyName Key -NotePropertyValue "local@$($d.Id)"  # так Windhawk называет локальный мод
    $d | Add-Member -NotePropertyName Source -NotePropertyValue (Join-Path $PSScriptRoot $d.File)
}
$MainSource = $ModDefs[0].Source
$WindhawkDir = Join-Path $env:ProgramFiles 'Windhawk'
$TestedEngineVersion = '1.7.3'             # флаги компиляции взяты из этой версии

# ── Вспомогательное ───────────────────────────────────────────────────────────
function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

function Get-WindhawkLayout {
    $ini = Join-Path $WindhawkDir 'windhawk.ini'
    if (-not (Test-Path $ini)) { throw "Не найден $ini. Windhawk установлен в другое место?" }
    $values = @{}
    foreach ($line in Get-Content $ini) {
        if ($line -match '^\s*([^=;\[]+?)\s*=\s*(.*?)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    if ($values['Portable'] -ne '0') { throw 'Portable-установка Windhawk: скрипт рассчитан на обычную.' }
    if ($values['RegistryKey'] -ne 'HKLM\SOFTWARE\Windhawk') {
        throw "Неожиданный RegistryKey в windhawk.ini: $($values['RegistryKey'])"
    }
    $enginePath = Join-Path $WindhawkDir $values['EnginePath']
    [pscustomobject]@{
        CompilerPath  = Join-Path $WindhawkDir $values['CompilerPath']
        EnginePath    = $enginePath
        EngineVersion = Split-Path $enginePath -Leaf
        AppDataPath   = [Environment]::ExpandEnvironmentVariables($values['AppDataPath'])
    }
}

function Open-ModsKey([bool]$Writable) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    $base.OpenSubKey('SOFTWARE\Windhawk\Engine\Mods', $Writable)
}

# Метаданные из шапки // ==WindhawkMod== ... // ==/WindhawkMod==
function Get-ModMetadata([string]$Text) {
    $m = [regex]::Match($Text, '(?s)// ==WindhawkMod==(.*?)// ==/WindhawkMod==')
    if (-not $m.Success) { throw 'В исходнике нет блока // ==WindhawkMod==.' }
    $meta = @{ include = @(); exclude = @(); architecture = @() }
    foreach ($line in $m.Groups[1].Value -split "`r?`n") {
        if ($line -match '^//\s*@([A-Za-z]+)\s+(.*?)\s*$') {
            $key = $Matches[1]; $val = $Matches[2]
            if ($key -in 'include', 'exclude', 'architecture') { $meta[$key] += $val } else { $meta[$key] = $val }
        }
    }
    $meta
}

# Значения по умолчанию из блока // ==WindhawkModSettings== в том виде, в каком
# их пишет в реестр Windhawk: bool -> 1/0, числа -> DWORD, остальное -> строка.
# Понимает только то, что встречается в этих модах (группы со скалярами). На
# всём незнакомом останавливается, чтобы не записать в реестр ерунду.
function Get-DefaultSettings([string]$Text) {
    $m = [regex]::Match($Text, '(?s)// ==WindhawkModSettings==\s*/\*(.*?)\*/\s*// ==/WindhawkModSettings==')
    if (-not $m.Success) { return [ordered]@{} }
    $result = [ordered]@{}
    $group = $null
    foreach ($line in $m.Groups[1].Value -split "`r?`n") {
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*\$') { continue }                 # $name, $description, $options
        if ($line -match '^ {4,}- ') { continue }               # пункты $options
        if ($line -match '^- ([A-Za-z0-9_]+):\s*$') { $group = $Matches[1]; continue }
        if ($line -match '^- ([A-Za-z0-9_]+):\s*(.+)$') { $group = $null; $key = $Matches[1]; $raw = $Matches[2] }
        elseif ($group -and $line -match '^  - ([A-Za-z0-9_]+):\s*(.+)$') { $key = "$group.$($Matches[1])"; $raw = $Matches[2] }
        else { throw "Непонятная строка в блоке настроек: '$line'" }

        $raw = $raw.Trim()
        if ($raw -match '^(true|True|TRUE)$') { $value = [long]1 }
        elseif ($raw -match '^(false|False|FALSE)$') { $value = [long]0 }
        elseif ($raw -match '^[-+]?\d+$') { $value = [long]$raw }
        elseif ($raw -match '^[-+]?(\d+\.\d*|\.\d+)$') { $value = [long][math]::Truncate([double]::Parse($raw, [cultureinfo]::InvariantCulture)) }
        elseif ($raw -match "^'(.*)'$") { $value = $Matches[1] -replace "''", "'" }
        elseif ($raw -match '^"([^"\\]*)"$') { $value = $Matches[1] }
        elseif ($raw -match '^[\[\{"|>&*!%@`]') { throw "Неподдерживаемое значение настройки ${key}: $raw" }
        else { $value = ($raw -replace '\s+#.*$', '') }
        $result[$key] = $value
    }
    $result
}

function Use-ClipboardFallback([string]$Reason) {
    if ($Reason) { Write-Warning $Reason }
    Write-Step 'Запасной вариант: исходник бара в буфер обмена, открываю Windhawk'
    Set-Clipboard -Value ([IO.File]::ReadAllText($MainSource))
    Start-Process (Join-Path $WindhawkDir 'windhawk.exe')
    Write-Host 'В Windhawk откройте мод в редакторе, выделите всё (Ctrl+A), вставьте (Ctrl+V) и нажмите Compile Mod.'
}

function Get-ToolModProcess([string]$Key) {
    Get-CimInstance Win32_Process -Filter "Name='windhawk.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*-tool-mod*$Key*" }
}

# Имена DLL этого мода, загруженные сейчас в explorer.exe (мост трея).
function Get-ExplorerModDlls([string]$Key) {
    $names = @()
    foreach ($p in @(Get-Process explorer -ErrorAction SilentlyContinue)) {
        try {
            $names += @($p.Modules | Where-Object { $_.ModuleName -like "${Key}_*.dll" } | ForEach-Object { $_.ModuleName })
        } catch { }
    }
    $names
}

# ── Шаг 2: установка (выполняется с правами администратора) ────────────────────
function Install-OneMod($Item, $Layout, $Mods, $Log) {
    $modsDir = Join-Path $Layout.AppDataPath 'Engine\Mods'
    $text = [IO.File]::ReadAllText($Item.Source)
    $meta = Get-ModMetadata $text
    if ($meta['id'] -ne $Item.Id) { throw "@id в $($Item.File) '$($meta['id'])', ожидался '$($Item.Id)'." }
    $dllName = $Item.Dll

    $key = $Mods.OpenSubKey($Item.Key, $true)
    $created = $false
    if (-not $key) {
        if (-not $Item.CanCreate) { throw "В реестре нет мода $($Item.Key)." }
        # Как Windhawk при первой компиляции: выключенная запись, включается ниже.
        $key = $Mods.CreateSubKey($Item.Key)
        $key.SetValue('Disabled', 1, 'DWord')
        $key.SetValue('LoggingEnabled', 0, 'DWord')
        $key.SetValue('SettingsChangeTime', [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), 'DWord')
        $created = $true
        $Log.Add("Новый мод в Windhawk: $($Item.Key)")
    }

    # 2a. DLL на место. Имя новое, поэтому загруженную сейчас DLL не трогаем.
    foreach ($sub in '32', '64') {
        $dst = Join-Path $modsDir "$sub\$dllName"
        if (Test-Path $dst) { throw "Файл уже существует: $dst" }
        foreach ($lib in 'libc++.whl', 'libunwind.whl', 'windhawk-mod-shim.dll') {
            if (-not (Test-Path (Join-Path $modsDir "$sub\$lib"))) {
                throw "Нет $sub\$lib. Скомпилируйте мод один раз из редактора Windhawk."
            }
        }
        Copy-Item (Join-Path $InstallFrom "$($Item.Name)\$sub\$dllName") $dst
        $Log.Add("DLL: $dst")
    }

    # 2b. Новые настройки. Как в Windhawk: добавляются только ключи, которых нет
    # ни в реестре, ни среди значений по умолчанию прошлой версии исходника.
    $newDefaults = Get-DefaultSettings $text
    $oldSourcePath = Join-Path $Layout.AppDataPath "ModsSource\$($Item.Key).wh.cpp"
    $oldDefaults = @{}
    if (Test-Path $oldSourcePath) {
        try { $oldDefaults = Get-DefaultSettings ([IO.File]::ReadAllText($oldSourcePath)) }
        catch { $Log.Add("Старый исходник не разобран ($($_.Exception.Message)); считаю, что прошлых значений нет.") }
    }
    if ($newDefaults.Count -gt 0) {
        $settingsKey = $key.CreateSubKey('Settings')
        $existing = @{}
        foreach ($n in $settingsKey.GetValueNames()) { $existing[$n] = $true }
        $added = 0
        foreach ($name in $newDefaults.Keys) {
            if ($existing.ContainsKey($name) -or $oldDefaults.Contains($name)) { continue }
            $v = $newDefaults[$name]
            if ($v -is [long]) {
                # Windhawk пишет число как DWORD (value >>> 0): те же 32 бита.
                $dword = [BitConverter]::ToInt32([BitConverter]::GetBytes([long]$v), 0)
                $settingsKey.SetValue($name, $dword, 'DWord')
            } else {
                $settingsKey.SetValue($name, [string]$v, 'String')
            }
            $Log.Add("Новая настройка: $name = $v")
            $added++
        }
        $settingsKey.Close()
        if ($added -gt 0) {
            $key.SetValue('SettingsChangeTime', [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), 'DWord')
        }
    }

    # 2c-2e. Как «Отключить -> Включить» в Windhawk. Одна только смена
    # LibraryFileName не годится: движок запускает новый процесс мода, пока
    # старый ещё закрывается, и новый уходит с «Tool mod already running».
    # Поэтому мод отключается, старая DLL дожидается выгрузки, ставится новая
    # DLL, и мод включается снова. Новая запись моста включается в первый раз.
    $wasEnabled = $created -or ([int]$key.GetValue('Disabled', 0) -eq 0)
    try {
        if ($wasEnabled -and -not $created) {
            $key.SetValue('Disabled', 1, 'DWord')
            $Log.Add("$($Item.Name): мод временно отключён.")
            $deadline = (Get-Date).AddSeconds(15)
            if ($Item.Tool) {
                while ((Get-ToolModProcess $Item.Key) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
                if (Get-ToolModProcess $Item.Key) { $Log.Add('Старый процесс мода не завершился за 15 с, продолжаю.') }
            } else {
                while (@(Get-ExplorerModDlls $Item.Key).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
                if (@(Get-ExplorerModDlls $Item.Key).Count -gt 0) { $Log.Add('Старая DLL не выгрузилась из explorer.exe за 15 с, продолжаю.') }
            }
        }

        $key.SetValue('Include', ($meta['include'] -join '|'), 'String')
        $key.SetValue('Exclude', ($meta['exclude'] -join '|'), 'String')
        $key.SetValue('Architecture', ($meta['architecture'] -join '|'), 'String')
        $key.SetValue('Version', [string]$meta['version'], 'String')
        $key.SetValue('LibraryFileName', $dllName, 'String')
        $Log.Add("Реестр: LibraryFileName = $dllName")

        # Исходник для Windhawk (по нему он показывает версию и настройки).
        [IO.File]::WriteAllText($oldSourcePath, $text, (New-Object System.Text.UTF8Encoding($false)))
        $Log.Add("Исходник: $oldSourcePath")

        # Старые DLL этого мода. Тот же фильтр, что у Windhawk:
        # "<mod>_" + "...(^|_)цифры" + ".dll". Занятые файлы пропускаются.
        $prefix = "$($Item.Key)_"
        foreach ($sub in '32', '64') {
            $old = Get-ChildItem (Join-Path $modsDir $sub) -File | Where-Object {
                $_.Name -ne $dllName -and $_.Name.StartsWith($prefix) -and $_.Name.EndsWith('.dll') -and
                $_.Name.Substring($prefix.Length, $_.Name.Length - $prefix.Length - 4) -match '(^|_)[0-9]+$'
            }
            foreach ($file in @($old)) {
                # $file, а не $_: внутри catch переменная $_ — это уже ошибка.
                try {
                    Remove-Item -LiteralPath $file.FullName -ErrorAction Stop
                    $Log.Add("Удалена старая DLL: $sub\$($file.Name)")
                } catch {
                    $Log.Add("Старая DLL занята, оставлена: $sub\$($file.Name)")
                }
            }
        }
    } finally {
        if ($wasEnabled) {
            $key.SetValue('Disabled', 0, 'DWord')
            $Log.Add("$($Item.Name): мод включён.")
        } else {
            $Log.Add("ВНИМАНИЕ: $($Item.Key) был выключен в Windhawk и остался выключенным.")
        }
        $key.Close()
    }
}

function Install-CompiledMods {
    $log = New-Object System.Collections.Generic.List[string]
    try {
        $layout = Get-WindhawkLayout
        $plan = Get-Content (Join-Path $InstallFrom 'plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $mods = Open-ModsKey $true
        try {
            foreach ($entry in @($plan)) {
                $item = $ModDefs | Where-Object { $_.Name -eq $entry.Name }
                if (-not $item) { throw "Неизвестный мод в плане: $($entry.Name)" }
                $item | Add-Member -NotePropertyName Dll -NotePropertyValue ([string]$entry.Dll) -Force
                Install-OneMod $item $layout $mods $log
            }
        } finally {
            $mods.Close()
        }
        $log.Add('OK')
        $code = 0
    } catch {
        $log.Add("ОШИБКА: $($_.Exception.Message)")
        $code = 1
    }
    [IO.File]::WriteAllLines($LogFile, $log, (New-Object System.Text.UTF8Encoding($true)))
    exit $code
}

if ($InstallFrom) { Install-CompiledMods }

# ── Шаг 1: проверки и компиляция (обычные права) ──────────────────────────────
$selected = @($ModDefs | Where-Object { $Mod -eq 'all' -or $_.Name -eq $Mod })
foreach ($item in $selected) {
    if (-not (Test-Path $item.Source)) { throw "Нет файла $($item.Source)" }
}
if ($ClipboardOnly) { Use-ClipboardFallback ''; return }

try {
    $layout = Get-WindhawkLayout
    if ($layout.EngineVersion -ne $TestedEngineVersion -and -not $Force) {
        throw "Windhawk $($layout.EngineVersion), а скрипт проверен на $TestedEngineVersion. Флаги компиляции могли измениться; если уверены, запустите с -Force."
    }
    $mods = Open-ModsKey $false
    foreach ($item in $selected) {
        $text = [IO.File]::ReadAllText($item.Source)
        $meta = Get-ModMetadata $text
        if ($meta['id'] -ne $item.Id) { throw "@id в $($item.File) '$($meta['id'])', а скрипт обновляет только '$($item.Id)'." }
        $exists = $null -ne $mods.OpenSubKey($item.Key)
        if (-not $exists -and -not $item.CanCreate) {
            throw "Мода $($item.Key) ещё нет в Windhawk. Первый раз создайте его через редактор (Create a new mod)."
        }
        $null = Get-DefaultSettings $text   # блок настроек разбирается, иначе стоп до каких-либо изменений
        if ($meta['architecture'].Count -gt 0) { throw "В $($item.File) задан @architecture; скрипт рассчитан на сборку по умолчанию (32 + 64 бит)." }
        $item | Add-Member -NotePropertyName Meta -NotePropertyValue $meta -Force
        $item | Add-Member -NotePropertyName Text -NotePropertyValue $text -Force
        $item | Add-Member -NotePropertyName Exists -NotePropertyValue $exists -Force
    }
    $mods.Close()
} catch {
    Use-ClipboardFallback $_.Exception.Message
    exit 1
}

$modsDir = Join-Path $layout.AppDataPath 'Engine\Mods'
$stage = Join-Path ([IO.Path]::GetTempPath()) ("dynamic-island-deploy-" + [guid]::NewGuid().ToString('N'))

# Аргументы в response-файле: так кавычки в -DWH_MOD_ID=L"..." доходят до clang
# одинаково в Windows PowerShell 5.1 и PowerShell 7.
function Quote([string]$s) { if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }

$jobs = @()
foreach ($item in $selected) {
    $version = [string]$item.Meta['version']
    do {
        $dllName = '{0}_{1}_{2}.dll' -f $item.Key, $version, (Get-Random -Minimum 100000 -Maximum 1000000)
    } while ((Test-Path (Join-Path $modsDir "32\$dllName")) -or (Test-Path (Join-Path $modsDir "64\$dllName")))
    $item | Add-Member -NotePropertyName Dll -NotePropertyValue $dllName -Force
    $extra = @()
    if ($item.Meta['compilerOptions']) { $extra = $item.Meta['compilerOptions'] -split '\s+' | Where-Object { $_ } }

    Write-Step "Компиляция $($item.Key) $version (32 и 64 бит)…"
    foreach ($t in @(@{ Sub = '32'; Triple = 'i686-w64-mingw32' }, @{ Sub = '64'; Triple = 'x86_64-w64-mingw32' })) {
        $dir = Join-Path $stage "$($item.Name)\$($t.Sub)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $argList = @(
            '-std=c++23', '-O2', '-shared', '-DUNICODE', '-D_UNICODE',
            '-DWINVER=0x0A00', '-D_WIN32_WINNT=0x0A00', '-D_WIN32_IE=0x0A00', '-DNTDDI_VERSION=0x0A000008',
            '-D__USE_MINGW_ANSI_STDIO=0', '-DWH_MOD',
            "-DWH_MOD_ID=L`"$($item.Key)`"", "-DWH_MOD_VERSION=L`"$version`"",
            (Join-Path $layout.EnginePath "$($t.Sub)\windhawk.lib"),
            '-x', 'c++', $item.Source,
            '-include', 'windhawk_api.h', '-target', $t.Triple, '-Wl,--export-all-symbols',
            '-o', (Join-Path $dir $dllName)
        ) + $extra
        $rsp = Join-Path $stage "$($item.Name)-$($t.Sub).rsp"
        [IO.File]::WriteAllLines($rsp, [string[]]($argList | ForEach-Object { Quote $_ }))
        $err = Join-Path $stage "$($item.Name)-$($t.Sub).err"
        $p = Start-Process -FilePath (Join-Path $layout.CompilerPath 'bin\clang++.exe') `
            -ArgumentList "--rsp-quoting=windows @`"$rsp`"" `
            -WorkingDirectory $layout.CompilerPath -NoNewWindow -PassThru `
            -RedirectStandardError $err -RedirectStandardOutput (Join-Path $stage "$($item.Name)-$($t.Sub).out")
        $null = $p.Handle   # иначе ExitCode после выхода может оказаться пустым
        $jobs += [pscustomobject]@{ Mod = $item.Name; Sub = $t.Sub; Process = $p; Err = $err }
    }
}
$failed = $false
foreach ($j in $jobs) {
    $j.Process.WaitForExit()
    $msg = (Get-Content $j.Err -Raw -ErrorAction SilentlyContinue)
    if ($j.Process.ExitCode -ne 0) {
        $failed = $true
        Write-Host "Ошибка компиляции ($($j.Mod), $($j.Sub) бит):" -ForegroundColor Red
        Write-Host $msg
    } elseif ($msg) {
        Write-Host "Предупреждения ($($j.Mod), $($j.Sub) бит):" -ForegroundColor Yellow
        Write-Host $msg
    }
}
if ($failed) { Remove-Item $stage -Recurse -Force; exit 1 }
if ($BuildOnly) {
    Remove-Item $stage -Recurse -Force
    Write-Host 'Сборка прошла (32 и 64 бит). -BuildOnly: в Windhawk ничего не установлено.' -ForegroundColor Green
    exit 0
}

# ── Шаг 2: установка с правами администратора ─────────────────────────────────
Write-Step 'Установка в Windhawk (подтвердите запрос UAC)…'
$plan = @($selected | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Dll = $_.Dll } })
ConvertTo-Json -InputObject $plan | Set-Content (Join-Path $stage 'plan.json') -Encoding UTF8
$beforeTool = @{}
foreach ($item in @($selected | Where-Object Tool)) { $beforeTool[$item.Name] = @(Get-ToolModProcess $item.Key | ForEach-Object { $_.ProcessId }) }
$logFile = Join-Path $stage 'install.log'
$hostExe = (Get-Process -Id $PID).Path
$childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
    '-InstallFrom', "`"$stage`"", '-LogFile', "`"$logFile`"")
try {
    $child = Start-Process -FilePath $hostExe -ArgumentList $childArgs -Verb RunAs -WindowStyle Hidden -Wait -PassThru
} catch {
    Remove-Item $stage -Recurse -Force
    Write-Warning 'Права администратора не получены, ничего не изменено.'
    exit 1
}
$installLog = @()
if (Test-Path $logFile) { $installLog = @(Get-Content $logFile -Encoding UTF8) }
$installLog | Where-Object { $_ -ne 'OK' } | ForEach-Object { Write-Host "    $_" }
# По маркеру в логе: код выхода процесса, запущенного через UAC, доходит не всегда.
$ok = $installLog -contains 'OK'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
if (-not $ok) { Write-Host 'Установка не удалась (см. выше).' -ForegroundColor Red; exit 1 }

# ── Шаг 3: ждём, пока новая версия загрузится ─────────────────────────────────
foreach ($item in $selected) {
    Write-Step "Жду загрузки $($item.Key)…"
    $deadline = (Get-Date).AddSeconds(20)
    $done = $null
    while ((Get-Date) -lt $deadline) {
        if ($item.Tool) {
            $done = Get-ToolModProcess $item.Key | Where-Object { $beforeTool[$item.Name] -notcontains $_.ProcessId } | Select-Object -First 1
            if ($done) { $done = "процесс $($done.ProcessId)" }
        } elseif ((Get-ExplorerModDlls $item.Key) -contains $item.Dll) {
            $done = 'explorer.exe'
        }
        if ($done) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($done) {
        Write-Host "Готово: $($item.Name) загружен ($done)." -ForegroundColor Green
    } elseif ($item.Tool) {
        Write-Warning "Новый процесс $($item.Key) не появился за 20 с. Проверьте в Windhawk, что мод включён и Windhawk запущен."
    } else {
        Write-Warning "$($item.Key) не загрузился в explorer.exe за 20 с. Проверьте в Windhawk, что мод включён."
    }
}

# Редактор Windhawk держит свою копию исходника; компиляция оттуда перезапишет эту установку.
$editorFile = Join-Path $layout.AppDataPath 'EditorWorkspace\mod.wh.cpp'
if (Test-Path $editorFile) {
    $editorText = [IO.File]::ReadAllText($editorFile)
    foreach ($item in $selected) {
        if ($editorText -match "//\s*@id\s+$([regex]::Escape($item.Id))\s" -and ($editorText -replace "`r", '') -ne ($item.Text -replace "`r", '')) {
            Write-Warning "В редакторе Windhawk открыта другая версия $($item.Key). Не нажимайте там Compile Mod, иначе она заменит только что установленную."
        }
    }
}
