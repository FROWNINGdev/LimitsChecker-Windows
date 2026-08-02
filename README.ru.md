# LimitsChecker для Windows

*(English: [README.md](README.md))*

Трей-индикатор **лимитов Claude Code** для Windows — порт
[LimitsChecker](https://github.com/lapurryt/LimitsChecker) (GNOME/AppIndicator +
macOS menu bar). Тот же слой данных (OAuth-эндпоинт Anthropic), но рендер через
WinForms `NotifyIcon`.

Показывает те же окна лимитов, что и `/usage` в Claude Code:

- `Session` — 5-часовое скользящее окно сессии
- `Week` — 7-дневное недельное окно (вся активность)
- `<model>` — 7-дневное окно по модели, когда оно активно

**Зависимостей нет**: только Windows PowerShell 5.1 и .NET Framework, которые уже
есть в Windows 10/11. Ни Python, ни установки чего-либо.

## Как выглядит

В macOS/GNOME строка `Session 5% · Week 42% · Fable 59%` рисуется прямо в панели.
В трее Windows текста нет, поэтому:

- **иконка** — наибольший процент, цветом по порогу (зелёный → жёлтый → красный),
- **тултип** — та же строка `Session 16% · Week 12%`,
- **меню** — строки с настоящими цветными прогресс-барами и обратным отсчётом:

```
[====------]  16%  Session   ·  resets in 1h 40m
[===-------]  12%  Week      ·  resets in 2d 10h
[=---------]   2%  Fable     ·  resets in 2d 10h
```

Меню следует тёмной/светлой теме Windows. При выходе за порог (по умолчанию 80 %)
или при ненормальной severity от API иконка краснеет, в тултипе появляется `⚠`,
и один раз показывается всплывающее уведомление.

**Двойной клик** по иконке — немедленное обновление; **Show details** открывает
в блокноте разбивку и сырой JSON ответа.

## Как это работает

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken из %USERPROFILE%\.claude\.credentials.json>
anthropic-beta: oauth-2025-04-20
```

Основной источник — массив `limits[]` (`session`, `weekly_all`, `weekly_scoped`),
`five_hour` / `seven_day` используются как запасной вариант. Токен перечитывается
с диска **на каждом опросе**, поэтому фоновое обновление токена самим Claude Code
подхватывается без перезапуска. Мёртвый токен виден по 401 от эндпоинта (нужен
повторный вход в Claude). У OAuth-токена должен быть scope `user:profile` — у
логинов Claude Code он есть.

Если файла `.credentials.json` нет, читается generic-запись из «Диспетчера учётных
данных» Windows (имя — `LIMITSCHECKER_CREDENTIAL_TARGET`), аналог связки ключей
на macOS.

Сеть опрашивается в фоновом runspace, поэтому медленный ответ не подвешивает
меню. Один неудачный опрос не гасит цифры: последние хорошие значения остаются,
внизу меню появляется строка об ошибке, а повтор идёт через
`RETRY_SECONDS` (для 401 — вчетверо реже). 5xx считается временным и
повторяется внутри опроса; 429 пропускает лишние попытки и вместо этого
расширяет паузу (1м, 2м, 4м, 8м, максимум 10м) с учётом `Retry-After`.

Каждый успешный опрос кэшируется, поэтому после перезапуска сразу видны
последние известные цифры — с пометкой о давности — вместо пустой панели.

Эндпоинт пропускает примерно один запрос в две минуты на токен — поэтому
интервал опроса по умолчанию три минуты. Меньшее значение `REFRESH_SECONDS`
даёт более свежие цифры ценой 429 на каждом втором опросе.

## Требования

- Windows 10/11, Windows PowerShell 5.1 (`powershell.exe` — есть по умолчанию)
- Claude Code, в который выполнен вход (существует `%USERPROFILE%\.claude\.credentials.json`)

## Запуск

```powershell
# разово, без установки (без окна консоли)
wscript.exe LimitsChecker.vbs

# или напрямую
powershell -NoProfile -ExecutionPolicy Bypass -File LimitsChecker.ps1
```

## Установка

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Установщик копирует файлы в `%LOCALAPPDATA%\LimitsChecker`, кладёт ярлык в папку
автозагрузки (`shell:startup`) и запускает приложение. Права администратора не
нужны. Флаги: `-NoAutostart`, `-NoLaunch`.

Автозагрузку можно включать и выключать прямо из меню — пункт **Run at startup**.

Иконка попадает в скрытую область трея; чтобы закрепить её на панели —
«Параметры → Персонализация → Панель задач → Другие значки на панели задач».

## Проверка

```powershell
# один синхронный опрос в консоль, без трея
powershell -NoProfile -ExecutionPolicy Bypass -File LimitsChecker.ps1 -SelfTest

# сырые данные
$t = (Get-Content "$env:USERPROFILE\.claude\.credentials.json" -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
Invoke-RestMethod https://api.anthropic.com/api/oauth/usage -Headers @{
    Authorization = "Bearer $t"; 'anthropic-beta' = 'oauth-2025-04-20' } | ConvertTo-Json -Depth 8
```

## Настройки

Переменные окружения. Работают оба префикса: `LIMITSCHECKER_*` (приоритет) и
`CLAUDEBAR_*` — как в Linux-версии. Кривое значение откатывается к умолчанию и
зажимается в диапазон, поэтому случайная переменная не помешает запуску.

| Переменная | Умолчание | Значение |
| --- | --- | --- |
| `..._CREDENTIALS` | `%USERPROFILE%\.claude\.credentials.json` | Путь к OAuth-учёткам Claude |
| `..._CREDENTIAL_TARGET` | `Claude Code-credentials` | Имя записи в Диспетчере учётных данных (запасной источник токена) |
| `..._ENDPOINT` | `https://api.anthropic.com/api/oauth/usage` | Эндпоинт |
| `..._BETA` | `oauth-2025-04-20` | Значение заголовка `anthropic-beta` |
| `..._REFRESH_SECONDS` | `180` | Интервал опроса, сек (минимум 5) |
| `..._RETRY_SECONDS` | `30` | Пауза перед повтором после сбоя, сек |
| `..._FETCH_ATTEMPTS` | `3` | Попыток внутри одного опроса (1–10) |
| `..._TIMEOUT` | `30` | Таймаут HTTP, сек |
| `..._WARN_PERCENT` | `80` | Порог для ⚠ и красного цвета (0–100) |
| `..._SHOW_SCOPED` | `1` | Показывать окно по модели в тултипе |
| `..._SCOPED_INACTIVE` | `0` | Показывать окно по модели, даже когда API помечает его неактивным |
| `..._NOTIFY` | `1` | Всплывающее уведомление при переходе через порог |
| `..._THEME` | `auto` | `auto` \| `dark` \| `light` — тема меню |
| `..._MENU_FONT` | `Segoe UI` | Шрифт меню |
| `..._BAR_PX` | `92` | Длина цветного бара в меню, пиксели |
| `..._BAR_WIDTH` | `10` | Ширина текстового бара (`-SelfTest`, детали) |
| `..._FILL_CHAR` / `..._TRACK_CHAR` | `█` / `▒` | Глифы текстового бара |
| `..._NAME_SESSION` / `..._NAME_WEEK` | `Session` / `Week` | Подписи окон |
| `..._ICON` | — | Путь к своей иконке `.ico` вместо рисованной |
| `..._TITLE` | `LimitsChecker` | Заголовок приложения и окна деталей |
| `..._CACHE` | `%LOCALAPPDATA%\LimitsChecker\usage-cache.json` | Последний удачный ответ, показывается на старте, пока идёт первый опрос |

Чтобы переменные действовали и при автозапуске, задавайте их для пользователя:

```powershell
[Environment]::SetEnvironmentVariable('LIMITSCHECKER_WARN_PERCENT', '70', 'User')
```

## Удаление

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Убирает ярлык автозагрузки, останавливает приложение и удаляет
`%LOCALAPPDATA%\LimitsChecker`.

## Отличия от оригинала

- Прогресс-бары в меню — настоящая графика с цветом, а не блочные глифы: в
  WinForms меню рисуется владельцем, ограничения DBusMenu тут нет. Текстовые бары
  остались в `-SelfTest` и в окне деталей.
- Панельной строки нет (в трее Windows нельзя показать текст) — она ушла в тултип,
  а число выводится на иконке.
- Обновление по двойному клику вместо среднего клика.
- Добавлены переключатель автозапуска в меню, тема под Windows и всплывающее
  уведомление при пересечении порога.

## Лицензия

MIT — как и у оригинального проекта. Оригинал:
[lapurryt/LimitsChecker](https://github.com/lapurryt/LimitsChecker).
