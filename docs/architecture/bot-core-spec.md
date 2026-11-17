# Спецификация ядра PoshBot (для реализации на .NET)

Документ описывает **как ядро работает сейчас** (PowerShell, форк FUIB, версия 0.14.33) — достаточно подробно, чтобы
воспроизвести поведение в .NET-приложении бота. Разделы «Рекомендации для .NET» — это проектные предложения, а не описание
текущего кода; такие места помечены явно.

Источники истины в коде: `PoshBot/Classes/*.ps1`, `PoshBot/Plugins/Builtin/*`, `PoshBot/Implementations/SlackAppSM/*`.
Пример плагина: `..\..\FUIB\ospbot\Modules\FuibBotPlugin` (вне репозитория).

## Содержание

1. Цели и границы совместимости
2. Компоненты и поток данных
3. Модели данных
4. Разбор команды (CommandParser)
5. Плагины и динамическое создание команд
6. Ролевая модель и авторизация
7. Выполнение команды и формирование ответа
8. Дополнительные механизмы (approvals, channel rules, scheduler, middleware, config-параметры)
9. Хранилище состояния
10. Контракт бекенда
11. Встроенные команды (паритет)
12. Подводные камни текущей реализации (не копировать слепо)
13. Рекомендации для .NET

---

## 1. Цели и границы совместимости

.NET-бот должен:
1. Выполнять **стандартные команды бота** (Builtin: роли, группы, плагины, расписания, help — §11) с теми же именами, алиасами, правами и форматом данных.
2. Подгружать **команды из папки со скриптами** динамически так же, как это делает PoshBot: одна функция = одна команда, метаданные в атрибуте `[PoshBot.BotCommand()]`, права через `PrivateData.Permissions` манифеста (§5).
3. Использовать **ту же ролевую модель** и желательно те же файлы состояния (`roles/groups/permissions/plugins/schedules.psd1`) для миграции без потери настроек (§9).
4. Сохранить контракт ответов команд (`PoshBot.Text.Response`, `PoshBot.Card.Response`, `PoshBot.File.Upload`) — на нём написаны все существующие плагины.

## 2. Компоненты и поток данных

```
Chat network ──(Socket Mode / WS / webhook)──► Backend.ReceiveMessage() ──► Message[]
                                                      │
 Bot.Start() loop, каждые 100 мс:                      ▼
   1. ReceiveMessage     : DM-фильтр (DisallowDMs) → HtmlDecode(Text) → middleware PreReceive → MessageQueue
   2. ProcessScheduledMessages : Scheduler.GetTriggeredMessages() → ResolveFromName/ToName → MessageQueue
   3. ProcessDeferredContexts  : истёкшие approvals (cancel) и одобренные/отклонённые
   4. ProcessMessageQueue → HandleMessage(msg):
        IsBotCommand? (префикс) → TrimPrefix → CommandParser.Parse → CallingUserInfo = Backend.GetUserInfo(From)
        PluginManager.MatchCommand(parsed, commandSearch = isBotCommand)
        нет совпадения и isBotCommand → ответ "No command found matching [...]" (если не MuteUnknownCommand)
        есть: middleware PostReceive → CommandInAllowedChannel (ChannelRules)
              → Plugin в ParsedCommand → regex: сброс параметров, Arguments = группы
              → Builtin: NamedParameters['Bot'] = bot
              → config-provided параметры → middleware PreExecute → Executor.ExecuteCommand
   5. ProcessCompletedJobs: middleware PostExecute → Response → SendCommandResponseToPrivate
                            → middleware PreResponse → Backend.SendMessage → middleware PostResponse
   6. Every 5 s: Backend.Ping()
```

Цикл — однопоточный; тяжёлая работа (команды плагинов) вынесена в `Start-Job`, поэтому бот остаётся отзывчивым.
Бот работает, пока `Backend.Connection.Connected = true`.

## 3. Модели данных

### Message (входящее сообщение, нормализованное бекендом)
| Поле | Тип | Смысл |
|---|---|---|
| `Id` | string | Может быть пустым |
| `Type` | enum `MessageType` | `Message, CardClicked, ChannelRenamed, PinAdded, PinRemoved, PresenceChange, ReactionAdded, ReactionRemoved, StarAdded, StarRemoved` |
| `Subtype` | enum `MessageSubtype` | `None, ChannelJoined, ChannelLeft, ChannelRenamed, ChannelPurposeChanged, ChannelTopicChanged` |
| `Text` | string | Текст (упоминания уже заменены на `@nick`) |
| `To` / `ToName` | string | ID и имя канала/DM |
| `From` / `FromName` | string | ID и имя автора |
| `Time` | datetime UTC | |
| `IsDM` | bool | |
| `Options` | hashtable | Бекенд-специфичное; ядро использует ключ `Scheduled=true` (форк, §8.4) |
| `RawMessage` | object | Оригинал из сети (Slack: `ts`, `thread_ts`, …). Передаётся в команду как `OriginalMessage.RawMessage` |

### Response (исходящее)
`Severity` (`Success|Warning|Error|None`), `Text: string[]` (простой вывод), `Data: object[]` (кастомные ответы),
`MessageFrom`, `To`, `OriginalMessage`.

### Кастомные ответы (контракт плагинов)
Определяются по `PSObject.TypeNames[0]` (также принимаются `Deserialized.*` — результат пересечения границы job):

| TypeName | Поля |
|---|---|
| `PoshBot.Text.Response` | `Text`, `AsCode`, `DM`, `TH` |
| `PoshBot.Card.Response` | `Type` (`Normal|Warning|Error`), `Title`, `Text`, `Color` (`#RRGGBB`; Normal `#008000`, Warning `#FFA500`, Error `#FF0000`, по умолчанию `#D3D3D3`), `Fields` (упорядоченный словарь), `ImageUrl`, `ThumbnailUrl`, `LinkUrl`, `CustomData`, `DM`, `TH` |
| `PoshBot.File.Upload` | `Path` или (`Content`, `FileName`, `FileType`), `Title`, `DM`, `TH`, `KeepFile` |

Семантика:
- `DM` — отправить пользователю в личные сообщения (по `Response.MessageFrom`), а не в исходный канал.
- `TH` — ответить в тред исходного сообщения (расширение форка). Если команда **уже вызвана из треда**, все ответы идут в этот тред независимо от `TH` (кроме DM, вынесенного из канала, и запланированных команд без `TH`).
- `KeepFile` — по умолчанию файл **удаляется** после загрузки.
- Всё остальное, что вернула команда: примитивы (`Byte…Decimal, String, Boolean, DateTime, TimeSpan, Guid, Uri, Version, Char, SecureString, XmlDocument, ProgressRecord`) → `ToString().Trim()` в `Response.Text`; прочие объекты → убрать служебные свойства (`PSComputerName, PSShowComputerName, PSSourceJobInstanceId, RunspaceId`) → `Format-List -Property * | Out-String`.
- Ошибки выполнения → карточки `Error` с заголовком `Command Exception`; без прав → карточка `Warning` «You do not have authorization to run command [...] :(» (`Command Unauthorized`).

Reaction-типы: `Success, Failure, Processing, Warning, ApprovalNeeded, Cancelled, Denied, Custom`. Слэк-эмодзи: `white_check_mark, exclamation, gear, warning, closed_lock_with_key, no_entry_sign, x`.

## 4. Разбор команды (CommandParser)

Вход: `Message`. Выход: `ParsedCommand { CommandString, Plugin, Command, Version, NamedParameters, PositionalParameters, From, FromName, To, ToName, Time, CallingUserInfo, OriginalMessage }`.

1. **Префикс** (`Bot.IsBotCommand`): первое слово (по пробелу) начинается с одного из префиксов:
   `CommandPrefix` (по умолчанию `!`), `AlternateCommandPrefixes` (по умолчанию `poshbot`) и каждый `alt + separator` (`:` `,` `;`). Если префикс — `$null`-символ, любое сообщение считается командой. Префикс срезается (`TrimPrefix`).
   Сообщение **без** префикса всё равно парсится, но матчится только по триггерам `Regex` и `Event` (`commandSearch=false`).
2. Текст `Trim()`, символ `U+00A0` → пробел.
3. Команда = первое слово по пробелу; остаток = аргументы. Если первое слово содержит `://` (URL) — не делить по `:`.
4. Делим первое слово по `:`:
   - `plugin:command`, `command:version`, `plugin:command:version` (версия определяется, если элемент приводится к `[Version]`).
   - Если `[1]` — версия → `Command=[0]`, `Plugin=null`. Иначе `Command=[1]`; если пусто → `Command=[0]`, `Plugin=null`; иначе `Plugin=[0]` (только для `Type=Message, Subtype=None`).
5. **Параметры** парсятся через PowerShell AST: строка `"fake-command <args>"`, заменяя `--name` на `-name`:
   - `-Name value [value2 …]` → именованный (несколько значений → массив; параметр без значения или перед другим параметром → `true` (switch));
   - `$var`-подобное значение сохраняется как текст (`Extent.Text`), без вычисления; значения вычисляются через `SafeGetValue()` (никакого выполнения кода);
   - остальное → позиционные.
   Ошибка разбора → `Write-Error`, команда продолжается с пустыми параметрами.

> .NET: нужен эквивалент разбора «как в PowerShell» (кавычки `'…'` `"…"`, массивы через запятую `a,b`, числа, `$true/$false`, `--` вместо `-`). Проще всего использовать `System.Management.Automation.Language.Parser` из `Microsoft.PowerShell.SDK` — поведение будет идентичным.

## 5. Плагины и динамическое создание команд

### 5.1 Что такое плагин
PowerShell-модуль (папка `Name/` с `Name.psd1` + `Name.psm1`). Модуль экспортирует функции; **каждая экспортированная функция/cmdlet = команда**. Имя плагина = имя модуля (BaseName манифеста).

Типовая структура прод-плагина (`FuibBotPlugin`) — «папка со скриптами»:
```
FuibBotPlugin/
  FuibBotPlugin.psd1     # ModuleVersion, RequiredModules=@('PoshBot'), PrivateData.Permissions
  FuibBotPlugin.psm1     # dot-source Private\*.ps1, затем Public\**\*.ps1; Export-ModuleMember -Function <BaseName каждого файла Public>
  Private\*.ps1          # хелперы
  Public\<Verb-Noun>.ps1 # одна функция на файл, имя функции = имя файла
```
Динамика на уровне модуля — это `.psm1`: добавили файл в `Public\` → он автоматически становится экспортируемой функцией при следующей загрузке модуля. Ядро PoshBot само «папки» не сканирует: оно получает **путь к `.psd1`** (из `ModuleManifestsToLoad` конфига, из сохранённого `plugins.psd1`, или после `!install-plugin`) и импортирует модуль.

### 5.2 Алгоритм `PluginManager.CreatePluginFromModuleManifest(moduleName, manifestPath, asJob, save)`
1. `Import-PowerShellDataFile` манифеста. Не прочитался → ошибка, плагин не создаётся.
2. `Plugin { Name = moduleName; Version = manifest.ModuleVersion (или '0.0.0'); Enabled = true; _ManifestPath }`.
3. Загрузить сохранённую конфигурацию плагина из `plugins.psd1` (по имени и версии): `Enabled`, `AdhocPermissions`, `CommandPermissions`.
4. **Permissions из манифеста**: `PrivateData.Permissions` — массив строк либо hashtable `{Name; Description}`. Каждая → `Permission(Name, Plugin=moduleName)` → в плагин. Полное имя: `"<Plugin>:<Name>"`.
5. Ad-hoc permissions из сохранённой конфигурации — вернуть плагину (если существуют в RoleManager).
6. `AddPlugin`: регистрирует плагин и **все его permissions в RoleManager**; пересоздаёт реестр команд.
7. `Import-Module <manifest> -Scope Local -Force` и `Get-Command -Module <name> -CommandType Function,Cmdlet`.
8. Для **каждой** команды:
   - Метаданные: у функции берётся `ScriptBlock.Attributes`, ищется атрибут типа `PoshBot.BotCommand` (cmdlet-ы метаданных не имеют).
   - `Command { Name = имя функции; ModuleQualifiedCommand = "<Module>\<Function>"; AsJob = asJob (true для внешних плагинов, false для Builtin); FunctionInfo/CmdletInfo }`.
   - **Атрибут `BotCommand`** (свойства): `CommandName`, `Aliases[]`, `Permissions[]`, `HideFromHelp` (false), `KeepHistory` (true), `TriggerType` (`Command|Event|Regex|Timer`, по умолчанию `Command`), `Regex`, `MessageType`, `MessageSubtype`, `Command` (bool; в коде ядра **не используется**).
   - Имя: `CommandName`, иначе имя функции. Алиасы → дополнительные `Command`-триггеры.
   - Permissions атрибута: каждое `p` → ищется `"<Plugin>:<p>"` среди permissions плагина (из манифеста) → `Command.AccessFilter.AddPermission`. См. подводный камень 12.1.
   - Триггеры по `TriggerType`:
     - `Command` → `Trigger(Command, <name>)` (+ алиасы);
     - `Event` → `Trigger(Event)` с `MessageType`/`MessageSubtype` из атрибута;
     - `Regex` → `Trigger(Regex, <Regex>)`; параметры из текста для такой команды не парсятся;
     - нет атрибута → `Command`-триггер с именем функции.
   - `Description` = `Synopsis` из `Get-Help`. `Usage` (для `Command`-триггера) = синтаксис из `Get-Help` в нижнем регистре, без `[<CommonParameters>]` и `-Bot`, с заменой имени функции на имя команды; для Regex — сам regex.
   - Команда добавляется в `plugin.Commands` (ключ — имя; дубликат имени игнорируется).
9. Если плагин ранее был отключён (`Enabled=false` в сохранённой конфигурации) — `Deactivate()`.
10. `LoadCommands()`; опционально `SaveState()`.

### 5.3 Реестр команд и версии
- `Plugins[name][version]` — несколько версий одного плагина могут быть загружены; активной считается **максимальная** версия (сортировка строк по убыванию — см. 12.4).
- Полное имя команды: `"<plugin>:<command>:<version>"`; именно оно используется в `ChannelRules`, `ApprovalConfiguration`, `SendCommandResponseToPrivate` с `-like`-подстановками.
- Плагин `Builtin` грузится при инициализации (`Plugins/Builtin/Builtin.psd1`), не сохраняется в `plugins.psd1`, команды выполняются **в процессе бота** (`AsJob=false`).

### 5.4 Сопоставление (`MatchCommand`)
Порядок:
1. Сначала **все команды Builtin** — первая, у которой `TriggerMatch`.
2. Если разобрано `plugin:command` — ищется только в этом плагине (указанная версия или последняя).
3. Иначе — перебор всех плагинов (последняя версия каждого); побеждает **первый** совпавший (порядок перебора hashtable не гарантирован — избегайте одинаковых имён команд в разных плагинах).

`TriggerMatch` для триггера:
- `Command` — только при `commandSearch=true` и `Message.Type=Message`: `trigger == parsed.Command` (регистронезависимо);
- `Event` — совпали `MessageType` и `MessageSubtype`;
- `Regex` — `-match` по **всей** `CommandString` (работает и без префикса).

### 5.5 Запуск команды плагина (`Command.Invoke`)
Для `AsJob=true` — новый PowerShell job (отдельный процесс). Внутри:
1. `Import-Module <PoshBot.psd1> -Force`, затем `Import-Module <plugin manifest> -Scope Local -Force`.
2. Устанавливается `$global:PoshBotContext`:
   `Plugin, Command, From, FromName, To, ToName, CallingUserInfo, ConfigurationDirectory, ParsedCommand (без From/FromName/To/ToName/CallingUserInfo/OriginalMessage), OriginalMessage (hashtable = Message.ToHash()), BackendType (имя класса бекенда, напр. 'SlackAppSMBackend')`.
3. Вызов `& "<Module>\<Function>" @namedParameters @positionalParameters`.
Результат job: Output-поток → данные ответа; Error-поток → ошибки; Information/Verbose/Warning — в результат (Warning влияет на реакцию).

Config-provided параметры: параметр с атрибутом `[PoshBot.FromConfig('Name')]` (или `[PoshBot.FromConfig()]` — имя параметра) заполняется значением `Configuration.PluginConfiguration[<PluginName>][<Name>]`, если пользователь не задал его явно.

## 6. Ролевая модель и авторизация

### 6.1 Сущности
```
Permission  { Name, Plugin, Description, Adhoc }   FullName = "<Plugin>:<Name>"
Role        { Name, Description, Permissions: {FullName → Permission} }
Group       { Name, Description, Users: {UserId → null}, Roles: {RoleName → Role} }
```
Связи: **User(ID) ∈ Group → Group ⊇ Roles → Role ⊇ Permissions**. Пользователи в группах хранятся по **ID бекенда** (Slack `U…`), а не по имени. Все словари регистронезависимые (PowerShell hashtable) — в .NET использовать `StringComparer.OrdinalIgnoreCase`.

Эффективные права пользователя = объединение permissions всех ролей всех групп, где он состоит.

### 6.2 Авторизация команды (`Command.IsAuthorized(userId)`)
```
если command.AccessFilter.Permissions.Count == 0:   → разрешено всем
иначе: для каждой permission пользователя:
          если FullName ∈ command.AccessFilter.Permissions (регистронезависимо) → разрешено
       разрешения нет → отказ
```
То есть достаточно **любой одной** совпавшей permission (OR). Применяется только к триггерам `Command` и `Regex`; для `Event`/`Timer` проверки прав нет.

Отказ → `Context.Result.Authorized = false`, ошибка `CommandNotAuthorized`, пользователю — карточка `Command Unauthorized`.

### 6.3 Встроенные роль/группа Admin
При первом запуске создаются:
- роль `Admin` с permissions `Builtin:` {`manage-roles`, `show-help`, `view`, `view-role`, `view-group`, `manage-plugins`, `manage-groups`, `manage-permissions`, `manage-schedules`};
- группа `Admin` с ролью `Admin`.
При каждой загрузке недостающие builtin-permissions добавляются в `Admin` обратно.
`Configuration.BotAdmins` (имена) при подключении разрешаются в ID (`Backend.UsernameToUserId`) и добавляются в группу `Admin` (бекенды с `LazyLoadUsers=true`, например Teams, — после получения первого сообщения).

**Важно:** `Admin` **не** получает автоматически права плагинов. Права на команды плагина нужно явно выдать (`!add-rolepermission admin FuibBotPlugin:osp`), см. `PoshBot-Slack-rbac.ps1`.

### 6.4 Типовая настройка (как в проде)
```
!new-role fuib-osp-role
!add-rolepermission fuib-osp-role FuibBotPlugin:osp
!new-group osp-members-group
!add-grouprole osp-members-group fuib-osp-role
!add-groupuser osp-members-group <username>      # имя → ID через Backend.UsernameToUserId
```
Permissions плагина FuibBotPlugin: `osp, uib, sd, superadmin, ad-write-user-password, ad-write-user-uac`.

### 6.5 Ad-hoc permissions
`!new-permission <name> <plugin>` создаёт permission с `Adhoc=true` (в плагин последней версии + RoleManager); `!add-commandpermission <plugin:command:version> <plugin:permission>` добавляет её команде. Сохраняются в `plugins.psd1` (`AdhocPermissions`, `CommandPermissions`) и восстанавливаются при старте.

### 6.6 Удаление и целостность
- Удаление permission → убирается из всех ролей; удаление роли → из всех групп; удаление группы — просто удаляется.
- Удаление плагина (единственной версии) удаляет его permissions из RoleManager.
- Любое изменение вызывает `SaveState()` (permissions/roles/groups → `*.psd1`).

### 6.6 Дополнительные ограничители доступа (вне ролей)
- `DisallowDMs` — игнорировать личные сообщения (реакция `Denied` + предупреждение).
- `ChannelRules` — §8.2. `ApprovalConfiguration` — §8.1.

## 7. Выполнение команды и формирование ответа

`CommandExecutor.ExecuteCommand(context)`:
1. Команда отключена (`Enabled=false`) → ошибка `CommandDisabled` (результат сразу, в очередь завершённых).
2. Для триггера `Command`: проверка **обязательных параметров** по всем parameter set-ам функции (`Get-Command`); достаточно, чтобы один набор был покрыт именованными + позиционными. Не хватает → ошибка с `Usage`.
3. Права (§6.2); нет → завершён с `Authorized=false`.
4. **Approval** (§8.1): нужен → реакция `ApprovalNeeded`, контекст в `DeferredCommandExecutionContexts`, карточка «Approval Needed…»; выполнение отложено.
5. Иначе — реакция `Processing`; запуск: job (`AsJob`) либо в текущей сессии (Builtin).
6. `TrackJob` — контексты хранятся до завершения.

`ReceiveJob()` (каждый цикл): для завершённых/упавших job — собрать потоки, `Success = (Error.Count == 0)`; реакция: нет успеха → `Failure`; были warning → `Warning`; иначе `Success`; убрать `Processing`; добавить в `History` (последние 100, если `KeepHistory`); счётчик успешных; `Duration`.

Затем `Bot.ProcessCompletedJobs`: формирование `Response` (§3), запись в `CommandHistory.log` (если `LogCommandHistory`), перенаправление в приват (`SendCommandResponseToPrivate`: если полное имя команды `-like` правилу → `Response.To = "@<username>"`), middleware и `Backend.SendMessage`.

## 8. Дополнительные механизмы

### 8.1 Approvals
`ApprovalConfiguration { ExpireMinutes = 30, Commands[] }`, где команда = `{ Expression (-like по полному имени), ApprovalGroups[], PeerApproval (true) }`.
- Нужно ли подтверждение: если `FullyQualifiedName -like Expression`: пользователь в одной из `ApprovalGroups` → подтверждение нужно только при `PeerApproval=true`; не в группе → нужно всегда.
- `!approve <id>` (алиасы `ack`, `approvecommand`): нельзя одобрять **свою** команду; одобряющий должен быть в одной из групп подтверждения. `!deny <id>`; `!pending` — список.
- Не подтверждено за `ExpireMinutes` → реакция `Cancelled`, сообщение об отмене.

### 8.2 ChannelRules
`ChannelRule { Channel (-like по ИМЕНИ канала), IncludeCommands[], ExcludeCommands[] }`, по умолчанию одно правило `* / * / —`.
Алгоритм: первое правило, чьё `Channel -like` совпало с `ToName`, решает: команда должна совпасть с одним из `IncludeCommands`, и не совпасть с `ExcludeCommands`. Если правило совпало по каналу, но include не нашлось → отказ. Совпадающих по каналу правил нет → **отказ**. **DM не проверяются.** Отказ → реакция `Denied` + предупреждение.

### 8.3 Middleware
Шесть точек: `PreReceive, PostReceive, PreExecute, PostExecute, PreResponse, PostResponse`. Хук — скрипт-файл, получающий `($Context, $Bot)` и возвращающий контекст; `$null` → сообщение отбрасывается; исключение → контекст отбрасывается (логируется). Хуки выполняются по порядку регистрации. Пример: `Middleware\middleware.slack.messagetojson.ps1`.

### 8.4 Scheduler
`!new-schedule`: `ScheduledMessage { Id, TimeInterval (Days|Hours|Minutes|Seconds), TimeValue, Message{Text, From, To, RawMessage}, Enabled, Once, IntervalMS, StartAfter (UTC), TimesExecuted }`.
Каждый цикл: для включённых — если `UtcNow > StartAfter` → клон сообщения (`Time=now`) в `MessageQueue`; `Once` → удалить, иначе `StartAfter += ceil((now-StartAfter)/Interval)*Interval`. Сообщение проходит обычный путь (парсинг, права от имени создателя). Хранится в `schedules.psd1`.
Форк: клон помечается `Options['Scheduled']=true`, чтобы бекенд не отвечал в тред сообщения, создавшего расписание (иначе напоминания «залипали» в старом треде).

### 8.5 Реакции
Если `AddCommandReactions` (по умолчанию true) — на сообщение команды: `Processing` → `Success|Failure|Warning`; `ApprovalNeeded`, `Cancelled`, `Denied`.

### 8.6 Конфигурация бота (`BotConfiguration`)
`Name, ConfigurationDirectory, LogDirectory, PluginDirectory, PluginRepository (['PSGallery']), ModuleManifestsToLoad[], LogLevel (Info|Verbose|Debug), MaxLogSizeMB (10), MaxLogsToKeep (5), LogCommandHistory, CommandHistoryMaxLogSizeMB, CommandHistoryMaxLogsToKeep, BackendConfiguration{Name, Token, TokenApp, …}, PluginConfiguration{<Plugin>{…}}, BotAdmins[], CommandPrefix ('!'), AlternateCommandPrefixes (['poshbot']), AlternateCommandPrefixSeperators ([':',',',';']), SendCommandResponseToPrivate[], MuteUnknownCommand (false), AddCommandReactions (true), DisallowDMs (false), FormatEnumerationLimitOverride (-1), ChannelRules[], ApprovalConfiguration, MiddlewareConfiguration`.
Хранится как `.psd1` (`Save-PoshBotConfiguration` / `Get-PoshBotConfiguration`).

## 9. Хранилище состояния
Каталог `ConfigurationDirectory` (прод: `%USERPROFILE%\.poshbot.slack`). Формат — PowerShell data file (`.psd1`, модуль `Configuration`: `ConvertTo-Metadata`/`ConvertFrom-Metadata`), UTF-8.

| Файл | Содержимое |
|---|---|
| `<Config>.psd1` (напр. `fuib-poshbot-slack.config.psd1`) | `BotConfiguration` |
| `permissions.psd1` | `{ "<Plugin>:<Name>": {Name, Plugin, Description, Adhoc} }` |
| `roles.psd1` | `{ Name: {Name, Description, Permissions: ["<Plugin>:<Name>"]} }` |
| `groups.psd1` | `{ Name: {Name, Description, Users: [id], Roles: [roleName]} }` |
| `plugins.psd1` | `{ Plugin: { "<version>": {Name, Version, Enabled, ManifestPath, CommandPermissions{cmd:[fullPerm]}, AdhocPermissions[]} } }` |
| `schedules.psd1` | расписания (§8.4) |
| `*.clixml` | stateful data плагинов (`Set-PoshBotStatefulData`, Export-Clixml) |
| `CommandHistory.log`, `PoshBot.log` | логи (JSON-строки: `DataTime, Class, Method, Severity, LogLevel, Message, Data`) |

Для миграции .NET-бота без потери настроек нужен парсер/писатель `.psd1`-литералов (hashtable, массивы, строки, bool, числа, даты). Либо одноразовый конвертер в JSON.

## 10. Контракт бекенда
См. `docs/tutorials/backend-development/*` и CLAUDE.md §4. Для .NET: интерфейс `IChatBackend` с методами `Connect/Disconnect`, `ReceiveMessages()`, `SendResponse(Response)`, `AddReaction/RemoveReaction`, `GetUser/UsernameToUserId/UserIdToUsername/GetUserInfo`, `ChannelIdToName`, `BotId`, `LazyLoadUsers`, `Ping`.

Особенности Slack Socket Mode (SlackAppSM) — по протоколу Slack:
- `apps.connections.open` (xapp-токен) → WebSocket URL; на каждый конверт с `envelope_id` отправить `{"envelope_id": "<id>"}`; `hello` — информационное; `disconnect` (`refresh_requested|warning|link_disabled`) — переподключиться (до 10 одновременных соединений).
- Типы: `events_api` (`payload.event`: `message`, `app_mention`, `reaction_*`, `member_*`, `team_join`…), `slash_commands` (`/cmd text` → команда `!cmd text`), `interactive`.
- Игнорировать `subtype=bot_message`, `message_replied`; сообщения самого бота (`From == BotId`); `message_changed` → автор/текст из вложенного `message`.
- Ответы: `chat.postMessage` (JSON/POST, `thread_ts` = `ts` **родителя**), загрузка файлов `files.getUploadURLExternal` → POST на `upload_url` → `files.completeUploadExternal`; DM — `channel=<userId>` (для файлов `conversations.open`); реакции `reactions.add/remove`.
- Карточки → attachments (`color`, `title`, `title_link`, `text` в тройных бэктиках, `fields` short, `thumb_url`, `image_url`); `AsCode` → тройные бэктики; чанкование по ~3900 символов по границам строк.
- Резолв: `users.list` (с пагинацией), `conversations.list` (пагинация, `types`), кэш с перезагрузкой при промахе.
- Необходимые scopes — в `osp-bot-app-manifest-slack.json` (+ `files:write` для загрузки файлов).

## 11. Встроенные команды (паритет)
Плагин `Builtin`; префикс `!`. «Права» — `Builtin:<perm>`; «—» = доступно всем.

| Функция | Имя / алиасы | Право |
|---|---|---|
| About | `about` | view |
| Get-PoshBotStatus | `status` | view |
| Get-CommandHelp | `man`, `help` | — |
| Get-MyCommands | `mycommands` | — |
| Get-CommandStatus | `getcommandstatus`, `commandstatus` | — |
| Get-CommandHistory | `history` | manage-plugins |
| Get-PendingCommand | `pending`, `pendingcommands` | — |
| Approve-PendingCommand | `ack`, `approve`, `approvecommand` | — (проверка группы approval внутри) |
| Deny-PendingCommand | `deny`, `denycommand` | — (аналогично) |
| Get-Plugin | `gp`, `getplugin` | — |
| Install-Plugin / Update-Plugin / Remove-Plugin | `ip`,`installplugin` / `up`,`updateplugin` / `rp`,`removeplugin` | manage-plugins |
| Enable-Plugin / Disable-Plugin | `enableplugin` / `dp`,`disableplugin` | manage-plugins |
| Find-Plugin | `find-plugin` | manage-plugins |
| Get-Role / New-Role / Remove-Role | `gr`,`getrole` / `nr`,`newrole` / `rr`,`remove-role` | view-role / manage-roles / manage-roles |
| Add-RolePermission / Remove-RolePermission | то же | manage-roles |
| Update-RoleDescription | — | manage-roles |
| Get-Group | `gg`,`getgroup` | view-group |
| New-Group / Remove-Group | `ng`,`newgroup` / `rg`,`removegroup` | manage-groups |
| Add/Remove-GroupUser, Add/Remove-GroupRole, Update-GroupDescription | — | manage-groups |
| Get-Permission | `getpermission` | view |
| New-Permission, Add-CommandPermission | — | manage-permissions |
| New/Get/Set/Remove-ScheduledCommand | `newschedule`/`new-schedule`, `getschedule`/`get-schedule`, `setschedule`/`set-schedule`, `removeschedule`/`remove-schedule` | manage-schedules |
| Enable/Disable-ScheduledCommand | `enableschedule`/`enable-schedule`, `disableschedule` | manage-schedules |
| Slap | `slap` | — |

Для .NET-реализации Builtin-команды нативные (не скриптовые): они работают с внутренним состоянием бота (RoleManager, PluginManager, Scheduler, DeferredContexts). Точные параметры и тексты ответов — `PoshBot/Plugins/Builtin/Public/*.ps1` и `docs/reference/commands/*.md`.

## 12. Подводные камни текущей реализации (не копировать слепо)

1. **Fail-open при неизвестной permission.** Если в `[PoshBot.BotCommand(Permissions='x')]` указана permission, которой нет в `PrivateData.Permissions`, лог говорит «Command will not be added», но на деле используется `continue` во внутреннем цикле — команда **добавляется без этого ограничения** и, если других permissions нет, **доступна всем**. В .NET: при неизвестной permission не регистрировать команду (или делать её недоступной всем) — fail-closed.
2. Права сравниваются по полной строке `"Plugin:Name"`, регистронезависимо.
3. Ad-hoc permissions плагина добавляются **каждой** команде с атрибутом метаданных (а не только выбранной) — наследие upstream; ожидаемое поведение — только перечисленные в `CommandPermissions`.
4. Версии плагинов сравниваются как строки (`'0.9.0' > '0.10.0'`). В .NET — `System.Version`.
5. Коллизии имён команд между плагинами решаются порядком обхода словаря (недетерминированно). В .NET — явный приоритет/ошибка при дубликате.
6. Параметры команды приходят из чата → исполняются как параметры PowerShell-функции; значения не вычисляются (`SafeGetValue`), но валидировать/ограничивать их — задача самой команды.
7. Таймаута выполнения у job нет; зависшая команда висит в `_jobTracker` бесконечно.
8. Объект ответа проходит сериализацию job (`Deserialized.*`), поэтому switch-поля `DM`/`TH` хранятся как `bool` (иначе всегда truthy).
9. `Response.Text` (простой вывод) не умеет `DM`.
10. Slack: `Send-SlackApi` (PSSlack) отправляет параметры в query-строке — для длинного текста лучше POST JSON.

## 13. Рекомендации для .NET (проектные, не часть текущего кода)

**Выполнение PowerShell-плагинов.** Чтобы «точно так же» выполнять существующие плагины, нужен хост PowerShell:
- `Microsoft.PowerShell.SDK` (PowerShell 7) — один процесс, команда в отдельном `Runspace`/`PowerShell` с таймаутом (`CancellationToken`/`BeginStop`); либо отдельный процесс `pwsh` для изоляции (аналог `Start-Job`; ~секунды на старт — можно держать пул прогретых процессов).
- Совместимость: прод сейчас на Windows PowerShell 5.1 — проверьте плагины на 7.x (модули AD, Lotus, Exchange могут быть только для 5.1; тогда нужен процесс `powershell.exe`).
- Контекст: воспроизвести `$global:PoshBotContext` (§5.5) и функции `New-PoshBot*Response`, `Get/Set-PoshBotStatefulData` (достаточно оставить модуль `PoshBot` как «клиентскую» библиотеку для команд, либо реализовать тонкий модуль-совместимость).
- Атрибуты `PoshBot.BotCommand`/`PoshBot.FromConfig` должны быть определены в сессии (см. `PoshBotAttribute.ps1`) — загрузить `Add-Type` перед импортом плагина.

**Обнаружение команд из папки (динамически).** Вариант без выполнения кода при сканировании:
1. Watcher на корневую папку плагинов; плагин = подпапка с `.psd1`.
2. Манифест читать `Import-PowerShellDataFile` / `Parser`; `PrivateData.Permissions` → permissions.
3. Для каждого `Public\**\*.ps1` разобрать AST (`Parser.ParseFile`): найти `FunctionDefinitionAst` → атрибут `PoshBot.BotCommand` (именованные аргументы — константы), блок параметров (`ParamBlockAst`: типы, `Mandatory`, `Position`, `FromConfig`), `.SYNOPSIS` из comment-based help. Это даёт имя, алиасы, права, триггеры, usage и проверку обязательных параметров без запуска функции.
4. Hot-reload: изменился файл → перестроить реестр команд плагина (в PowerShell-версии требуется переустановка/рестарт).
5. Валидация при загрузке: неизвестные permissions → ошибка (см. 12.1), дубликаты команд, неэкспортируемые функции.

**Состояние.** Заменить `.psd1` на JSON/БД, оставив одноразовый импорт старых файлов (§9). Ключи групп — ID бекенда; для нескольких бекендов храните пару `(backend, userId)`.

**Безопасность.** Fail-closed авторизация; секреты — Key Vault/Managed Identity, не в конфиге; не логировать параметры команд с секретами; ограничение каналов (`ChannelRules`) по умолчанию «deny» для AI-команд.

**Тестирование паритета.** Набор golden-тестов: (текст сообщения, пользователь, канал) → ожидаемые `ParsedCommand`, решение авторизации, `Response`. Источники: `Tests/Unit/Classes/*` в репозитории.
