# CLAUDE.md — PoshBot (форк FUIB / OSP-BOT)

Форк [PoshBot](https://github.com/poshbotio/PoshBot) 0.14.x (автор форка — Andrew V. Golubenkoff, FUIB).
Бот — это PowerShell-модуль: любые PowerShell-модули-плагины, загруженные в бота, становятся командами чата.
Ведётся развитие: новые бекенды, команды и работа бота с AI через сервисы Azure.

Подробная спецификация ядра (ролевая модель, динамическое создание команд из папки скриптов,
конвейер обработки сообщений, контракт бекенда) для будущего переписывания на .NET:
**[docs/architecture/bot-core-spec.md](docs/architecture/bot-core-spec.md)**.

---

## 1. Где что лежит

| Путь | Что это |
|---|---|
| `PoshBot/Classes/*.ps1` | Ядро: `Bot`, `CommandParser`, `PluginManager`, `RoleManager`, `CommandExecutor`, `Scheduler`, модели (`Message`, `Response`, `Command`, `Permission`, `Role`, `Group` …) |
| `PoshBot/Classes/PoshBotAttribute.ps1` | C#-атрибуты `[PoshBot.BotCommand()]` и `[PoshBot.FromConfig()]` (грузятся через `ScriptsToProcess`) |
| `PoshBot/Implementations/<Backend>/` | Бекенды: `Slack` (старый RTM), **`SlackAppSM`** (Slack App, Socket Mode — **прод**), `Teams`, `Discord` |
| `PoshBot/Public/*.ps1` | Экспортируемые функции (`New-PoshBotInstance`, `Start-PoshBot`, `New-PoshBot*Response`, `New-PoshBotFileUpload` …) |
| `PoshBot/Plugins/Builtin/` | Встроенный плагин (управление ролями/группами/плагинами/расписаниями, help). Выполняется **в процессе бота**, получает `-Bot` |
| `docs/` | Документация upstream (mkdocs). `docs/tutorials/backend-development/*` — контракт бекенда |
| `out/PoshBot/<version>/` | Результат сборки (в `.gitignore`). Именно эта папка копируется на прод |
| `Tests/Unit` | Pester 4.x тесты upstream |

Прод-обвязка лежит **вне** этого репо: `..\..\FUIB\ospbot\`
- `PoshBot-Slack-Prod.ps1` — запуск (служба через NSSM): импортирует `Modules\PSSlackAG\1.0.6a\PSSlack.psd1` и `Modules\PoshBot\<ver>\PoshBot.psd1` **по явному пути и версии**, затем `New-PoshBotSlackAppSMBackend` → `New-PoshBotInstance` → `Start-PoshBot` в бесконечном цикле.
- Конфиг бота: `%USERPROFILE%\.poshbot.slack\fuib-poshbot-slack.config.psd1` (там же `plugins.psd1`, `roles.psd1`, `groups.psd1`, `permissions.psd1`, `schedules.psd1`).
- `Modules\FuibBotPlugin\` — основной плагин с командами (см. §5).
- `PoshBot-Slack-rbac.ps1` — шпаргалка команд настройки ролей/групп.
- `osp-bot-app-manifest-slack.json` — манифест Slack-приложения.

**Секреты** (xoxb/xapp токены, ключи Azure) хранятся только в конфиге бота / `PluginConfiguration`. Никогда не коммитить их и не писать в лог.

## 2. Сборка и деплой

```powershell
# Windows PowerShell 5.1 (как в проде), из корня репозитория:
.\build.ps1 -Task Test        # компиляция + PSScriptAnalyzer + Pester (нужны psake, BuildHelpers, Pester 4.10.1, PSScriptAnalyzer, platyPS)
.\build.ps1 -Task Build       # только сборка в out\PoshBot\<ModuleVersion>
.\build.ps1 -Bootstrap -Task Test   # первый раз на чистой машине: ставит зависимости из requirements.psd1
```

- Модуль **компилируется в один `PoshBot.psm1`**. Порядок классов задан **вручную** в `psakeFile.ps1` (task `Compile`). Новый файл в `Classes/` нужно добавить в этот список в правильном месте (после классов, от которых он зависит), иначе модуль не загрузится.
- `Implementations/**/*.ps1` дописываются в конец psm1 автоматически (кроме `*ServiceBusReceiver*`).
- `Compile` начинается с `Clean`, который **очищает `out/PoshBot/<ModuleVersion>`**. Перед сборкой релиза поднимайте `ModuleVersion` в `PoshBot/PoshBot.psd1`, чтобы не перезаписать задеплоенную версию.
- Деплой: скопировать `out/PoshBot/<ver>` в `FUIB/ospbot/Modules/PoshBot/<ver>` и поправить путь импорта в `PoshBot-Slack-Prod.ps1`.
- Тесты (`Tests/`) написаны на синтаксисе Pester 3/4 (`Should Be`), поэтому build использует **Pester 4.10.1**. Pester 3.4.0 (был прибит ранее) падает на текущем Windows PowerShell; Pester 5/6 потребует переписать тесты (`Should -Be`, `BeforeAll`, `InModuleScope`).
- `build.ps1` перед сборкой импортирует PSSlackAG (см. §4, п.8); параметр `-PSSlackPath` переопределяет путь.
- Быстрая проверка синтаксиса отдельного файла: `[System.Management.Automation.Language.Parser]::ParseFile(...)` — ошибки вида «Unable to find type [Backend]» нормальны (типы определены в других файлах).
- Код должен работать в **Windows PowerShell 5.1** (прод) и PowerShell 7. Не использовать синтаксис только 7.x (`??`, `?.`, тернарный оператор, `ForEach-Object -Parallel`) в ядре.

## 3. Как бот обрабатывает сообщение (кратко)

`Bot.Start()` — цикл каждые 100 мс:
`Backend.ReceiveMessage()` → middleware `PreReceive` → очередь → `IsBotCommand` (префикс `!`, или alt-префиксы `poshbot` + `:`/`,`/`;`) → `CommandParser.Parse` → `PluginManager.MatchCommand` → `PostReceive` → проверка `ChannelRules` → config-provided параметры → `PreExecute` → `CommandExecutor.ExecuteCommand` (права → approval → запуск **в `Start-Job`**, Builtin — in-process) → `ProcessCompletedJobs` → `PostExecute` → формирование `Response` → `PreResponse` → `Backend.SendMessage(Response)` → `PostResponse`.

Подробно с диаграммой — в спецификации.

## 4. Бекенды: контракт

Бекенд = класс `XxxBackend : Backend` + `XxxConnection : Connection` + функция-фабрика `New-PoshBotXxxBackend` (принимает hashtable `BackendConfiguration`). Экспортировать фабрику через `Export-ModuleMember` и добавить её в `FunctionsToExport` в `PoshBot.psd1`.

Обязательные методы `Backend` (иначе `throw 'Implement me!'`):

| Метод | Назначение |
|---|---|
| `Connect()` / `Disconnect()` | Подключение. Обычно: `Connection.Connect()`, затем `BotId = GetBotIdentity()`, `LoadUsers()`, `LoadRooms()` |
| `[Message[]] ReceiveMessage()` | Неблокирующе вернуть новые сообщения (0..n). Отфильтровать сообщения самого бота (`MsgFromBot`) — иначе петля |
| `SendMessage([Response])` | Отправить `Response.Data` (кастомные ответы) и `Response.Text` (строки) |
| `AddReaction` / `RemoveReaction` | Реакции на исходное сообщение (`ReactionType` → emoji) |
| `GetUser`, `UsernameToUserId`, `UserIdToUsername`, `GetUserInfo` (hashtable) | Резолв пользователей. **В ролевой модели хранятся ID** |
| `ChannelIdToName`, `ResolveFromName`, `ResolveToName` | Нужны для `ChannelRules` (они матчатся по **имени** канала) |
| `GetBotIdentity`, `LoadUsers`, `LoadRooms`, `Ping` | |

Правила для `Message`, который отдаёт бекенд:
- `To` — ID канала/DM, `From` — ID пользователя, `IsDM` — `$true` для личных сообщений, `Text` — с уже заменёнными `<@U123>` → `@nick`, `RawMessage` — оригинальный объект сети (используется для `ts`/`thread_ts`, реакций).
- `Type`/`Subtype` — из enum `MessageType`/`MessageSubtype` (нужны для `Event`-триггеров).

### Кастомные ответы команд (контракт, который нельзя ломать — на нём все плагины)

| Тип (`PSTypeName`) | Создаётся | Поля |
|---|---|---|
| `PoshBot.Text.Response` | `New-PoshBotTextResponse` | `Text`, `AsCode`, `DM`, `TH` |
| `PoshBot.Card.Response` | `New-PoshBotCardResponse` | `Type`, `Title`, `Text`, `Color`, `Fields`, `ImageUrl`, `ThumbnailUrl`, `LinkUrl`, `CustomData`, `DM`, `TH` |
| `PoshBot.File.Upload` | `New-PoshBotFileUpload` | `Path` **или** `Content`+`FileName`+`FileType`, `Title`, `DM`, `TH`, `KeepFile` |

- `-DM` — ответ в личку вызвавшему. `-TH` — ответ в тред исходного сообщения (расширение форка; поддерживается бекендами Slack).
- Флаги хранить как `[bool]` (`$Switch.IsPresent`): объект проходит сериализацию `Start-Job`, а десериализованный `SwitchParameter` всегда truthy.
- Всё, что не кастомный ответ, бот превращает в текст: примитивы → `ToString()`, объекты → `Format-List | Out-String`.

### Slack (SlackAppSM, Socket Mode) — обязательные правила

Сверено с docs.slack.dev (chat.postMessage, Socket Mode, files.*):

1. **Треды.** `thread_ts` = `ts` **родительского** сообщения. Если входящее сообщение уже в треде (`RawMessage.thread_ts` есть) — отвечать в `thread_ts`, а не в его `ts` («Avoid using a reply's ts value; use its parent instead»). Никаких префиксов к ts. Реализовано в `SlackAppSMBackend._ResolveThreadTs()`. Если команда пришла из треда, **любой** ответ (в т.ч. ошибки, «unauthorized», plain-text) идёт в этот тред.
2. **DM.** В `chat.postMessage` передавать **user ID** как `channel` (Slack сам откроет DM). `@username` как канал — deprecated. Для файлов нужен ID разговора: `conversations.open` (scope `im:write`) — `_ResolveConversationId()`.
3. **Файлы.** `files.upload` выведен из эксплуатации. Только: `files.getUploadURLExternal` (POST form: `filename`, `length`) → POST байтов на `upload_url` (200 = ок) → `files.completeUploadExternal` (`files[]`, `channel_id`, `thread_ts`). Проверять `ok` у каждого шага. Нужен scope **`files:write`** (в `osp-bot-app-manifest-slack.json` его нет — проверить в реальном приложении). Реализовано в `_SlackClient.ps1`.
4. **Socket Mode.** Каждый конверт с `envelope_id` (`events_api`, `slash_commands`, `interactive`) подтверждать `{"envelope_id": "..."}` сразу. `hello` — пропустить. `disconnect` (`refresh_requested`/`warning`/`link_disabled`) — штатное событие раз в несколько часов → переподключение. `interactive` (кнопки/модалки) пока не обрабатывается.
5. **Slash-команды** приходят без `ts`: реакции и `-TH` для них не работают (это ожидаемо). `/cmd` превращается в `!cmd <text>`.
6. `as_user` — legacy-параметр «только для classic apps». Текущие PSSlack-вызовы передают `-AsUser` и это работает, но в новом коде его не использовать.
7. Текст ≤ ~4000 символов на сообщение (бекенд режет по 3900 по строкам — `_ChunkString`).
8. **PSSlack = ваш форк `PSSlackAG 1.0.6a`** (`..\..\FUIB\ospbot\Modules\PSSlackAG\1.0.6a\PSSlack.psd1`, внутри — модуль `PSSlack` версии 1.0.6). От оригинала 1.0.6 отличается только `Get-SlackUser` (пагинация, `limit=999`). Прод импортирует его по пути; папка не совпадает с именем манифеста, поэтому через `PSModulePath` он не находится. Сборка и тесты тоже грузят его (`build.ps1 -PSSlackPath`). Используемые бекендом `Send-SlackMessage -Thread`, `New-SlackMessage -Thread`, `Send-SlackApi` в форке идентичны оригиналу.

Токены: `Token` = `xoxb-…` (bot, все Web API вызовы), `TokenApp` = `xapp-…` (только `apps.connections.open`).

## 5. Плагины и команды («папка со скриптами»)

Плагин = PowerShell-модуль (`.psd1` + `.psm1`). Прод-плагин `FuibBotPlugin`:

```
FuibBotPlugin/
  FuibBotPlugin.psd1   # RequiredModules = 'PoshBot'; PrivateData.Permissions = @('osp','uib','sd','superadmin',...)
  FuibBotPlugin.psm1   # dot-source Private/*.ps1 и Public/*.ps1, Export-ModuleMember -Function <имена файлов Public>
  Private/*.ps1        # хелперы, не команды
  Public/<Имя>.ps1     # ОДИН файл = ОДНА функция = ОДНА команда; имя функции == имя файла
```

Шаблон новой команды (`Public/Get-Something.ps1`):

```powershell
function Get-Something {
    <#
    .SYNOPSIS
        Короткое описание — показывается в !help
    .EXAMPLE
        !something -Name foo
    #>
    [PoshBot.BotCommand(
        CommandName = 'something',            # имя в чате (иначе — имя функции)
        Aliases     = ('sth', 'get-sth'),
        Permissions = 'osp'                   # без префикса плагина; должно быть в PrivateData.Permissions манифеста
        # TriggerType = 'Regex', Regex = '...'   — реагировать на текст без префикса '!'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Name,
        [PoshBot.FromConfig('AzureOpenAIKey')] [string]$ApiKey     # значение из PluginConfiguration.FuibBotPlugin.AzureOpenAIKey
    )
    # $global:PoshBotContext: From, FromName, To, ToName, CallingUserInfo, OriginalMessage (hashtable; RawMessage.ts / thread_ts),
    #                         BackendType ('SlackAppSMBackend' / 'TeamsBackend'), ConfigurationDirectory, ParsedCommand
    New-PoshBotCardResponse -Type Normal -Title 'Result' -Text "Hello $Name" -TH
}
```

Правила:
- Команды выполняются **в отдельном процессе** (`Start-Job`): в каждом вызове заново импортируются PoshBot и плагин. Нет общего состояния в памяти между вызовами → использовать `Get/Set-PoshBotStatefulData` (clixml-файлы в `ConfigurationDirectory`, scope `Module`/`Global`) или внешнее хранилище. Старт job (новый процесс + импорт модулей) занимает порядка секунд.
- Таймаута выполнения команды нет — долгие вызовы (AI) не блокируют бота, но и не прерываются. Ставить таймауты на HTTP-вызовы внутри команды.
- Для Regex-триггера параметры из текста не парсятся: функция получает `-Arguments` (группы совпадения) — объявляйте `param([parameter(ValueFromRemainingArguments)]$Dummy)` или `$Arguments`.
- Разные ответы для бекендов: `if ($global:PoshBotContext.BackendType -like '*Slack*') { ... }`.
- После добавления файла в `Public/` плагин нужно **переустановить** (`!update-plugin` / `!remove-plugin` + `!install-plugin`) или перезапустить бота: список команд строится при загрузке модуля.
- Права новой permission нужно выдать ролям (`!add-rolepermission <role> FuibBotPlugin:<perm>`).

## 6. Ролевая модель (кратко)

`Permission` (`Plugin:name`) → входит в `Role` → роли назначаются `Group` → в группу добавляются **user ID**.
Команда без permissions доступна всем; с permissions — если у пользователя есть **хотя бы одна** из них. Встроенная группа/роль `Admin` + `BotAdmins` из конфига. Дополнительно: `ApprovalConfiguration` (подтверждение команды группой), `ChannelRules` (какие команды в каких каналах), `SendCommandResponseToPrivate`, `DisallowDMs`.
Полное описание — в [спецификации, §6](docs/architecture/bot-core-spec.md).

## 7. Направление развития: AI через Azure

Рекомендации для новых команд/бекендов:
- Отдельный плагин-модуль (например, `FuibAIPlugin`) по схеме §5, со своими permissions (`ai-user`, `ai-admin`).
- Endpoint/deployment/ключи — только через `[PoshBot.FromConfig()]` + `PluginConfiguration` в конфиге бота (или Managed Identity / Key Vault), не в коде.
- Ключ диалога для истории — `channel + thread_ts` (`$global:PoshBotContext.OriginalMessage.RawMessage.thread_ts`, иначе `.ts`). Отвечать `-TH`, чтобы диалог жил в треде. История — `Set-PoshBotStatefulData` / Azure Storage / Cosmos DB.
- Ответы модели длинные: учитывать лимит 3900 символов (бекенд режет сам) и Markdown Slack (mrkdwn ≠ Markdown).
- «Ответить на любое сообщение» без префикса: Regex-триггер или middleware `PreReceive` (маршрутизация), но обязательно фильтровать сообщения бота и ограничивать каналы через `ChannelRules`.
- Не логировать промпты с персональными данными и токены (`LogCommandHistory` пишет параметры команд в `CommandHistory.log`).

## 8. Известный техдолг (не ломать при правках, чинить осознанно)

- `RtmConnect()` берёт только первые 100 публичных каналов (`conversations.list` без пагинации/`types`) в `LoginData.channels`; `LoadRooms()` через PSSlack — с пагинацией, но тоже только публичные.
- Receive-job шлёт RTM-`ping`, которого нет в протоколе Socket Mode (безвреден, но лишний).
- При `disconnect`/падении job переподключение занимает ~5 с (`Reconnect()` = Disconnect + Sleep 5 + Connect); Slack допускает до 10 соединений — можно сделать бесшовную смену.
- `PluginManager.LoadState()` восстанавливает ad-hoc permissions **команд** на уровень плагина (наследие upstream).
- `Response.Text` (не кастомный вывод) не поддерживает `-DM`.
- В `SlackAppSMBackend` много дублей с `SlackBackend` (цветовая карта, резолверы) — кандидаты на общий базовый класс.

## 9. Стиль

- Классы PowerShell: методы с явными типами, логирование через `$this.LogDebug/LogVerbose/LogInfo([LogSeverity]::…)`, ошибки — `[ExceptionFormatter]::Summarize($_)`.
- Не использовать `Write-Host` в ядре — только логгер.
- Комментарии в коде — на английском; документация — на русском.
