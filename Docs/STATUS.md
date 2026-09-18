# Статус — iOS Termux-style Sandbox

Repo: https://github.com/me7ko-dev/ios-termux-sandbox (private)

## Сесия 2 (2026-09-18, продължение same-day) — NEXT_STEPS т.1

Виж `Docs/NEXT_STEPS.md` т.1 за пълните детайли. Накратко: линкването на
`ios_system` продукта **не е достатъчно** за `man`/`perl`/network командите —
трябва изрично `addCommandList()` с бандлван plist, точно както прави
a-Shell. Добавено:

- Нов dependency **`network_ios`** (dig/ping/nc/telnet/...).
- `Sources/TermuxSandboxApp/Resources/commandDictionary.plist` — 103 команди,
  филтрирани от a-Shell's собствен shipped речник до само frameworks, които
  реално линкваме.
- `ShellEngine.loadBundledCommandDictionary()` — зарежда горния plist при старт.
- Нова диагностична команда **`commands`** — пуска `commandsAsArray()`, за да
  видиш на устройство какво реално се е регистрирало.

Всичко това пак е **некомпилирано** — писано на Windows. `commands` е
именно инструментът да провериш резултата на Mac.

---

# Сесия 1 (2026-09-18)

## Преди да четеш нататък — платформено ограничение

Тази сесия работи на **Windows**, не на Mac. Написах реален Swift код и
архитектурата, но **нищо от това не е компилирано или тествано** — не мога
да пусна Xcode тук. Първата стъпка на Mac трябва да е `swift build` /
отваряне в Xcode, за да хванеш реалните грешки от компилатора. По-долу има
списък с API повиквания, които проверих срещу живия GitHub код на
зависимостите (не по памет), плюс една точка, която нарочно опростих вместо
да гадая — виж "Какво е проверено" по-долу.

## Какво заварих (преди тази сесия)

Претърсих целия ти home directory. Нямаше съществуващ код за тази задача —
само два концептуални guide файла (`Desktop/.../Helper/10_iOS_Terminal_CrossCompile`
и `11_iOS_Ultimate_Terminal_LLM`) с архитектурни бележки и илюстративни
примери, не реален buildable проект. Потвърди ми го изрично — затова
започнах от нула тук, в нова папка на същото ниво като другите ти проекти:

```
Desktop/📁 01. AI & Dev Projects/ios-termux-sandbox/
```

## Избран стек (по твой избор)

- **ios_system** (holzschu/ios_system) — компилира Unix команди (ls, cat,
  grep, tar, curl, ssh_cmd, perl, awk...) статично в приложението и ги
  извиква in-process през `ios_system("команда")`, без `fork()`/`execve()`.
  Точно моделът, който Apple sandbox позволява.
- **SwiftTerm** (migueldeicaza/SwiftTerm) — ANSI/VT100 терминален изглед за
  UIKit.
- **Citadel** (orlandos-nl/Citadel) — чист Swift SSH2 клиент върху
  SwiftNIO, официално поддържа iOS 17+. Избрах го за новата `sshc` команда
  вместо да пипам libssh2 крос-компилация на ръка.

## Какво е готово в тази сесия

```
ios-termux-sandbox/
├── Package.swift
├── Sources/
│   ├── SysInfoCommand/SysInfoCommand.swift      ← нова команда #1
│   ├── SSHClientCommand/SSHClientCommand.swift  ← нова команда #2
│   └── TermuxSandboxApp/
│       ├── App.swift                  (SwiftUI обвивка)
│       ├── TerminalViewController.swift  (UIKit + SwiftTerm)
│       ├── ShellEngine.swift          (in-process dispatch + stdout pipe)
│       ├── CommandRegistry.swift      (регистрира новите команди при старт)
│       ├── CommandsListCommand.swift  (Сесия 2 — `commands` diagnostic)
│       └── Resources/commandDictionary.plist  (Сесия 2 — виж по-долу)
└── Docs/{STATUS.md, NEXT_STEPS.md}
```

### Нова команда 1: `sysinfo`
Нулеви зависимости извън Foundation/UIKit. Единствената ѝ цел е да докаже,
че целият pipeline работи end-to-end, преди да качваме нещо по-тежко:
регистрация през `replaceCommand` → dispatch през `ios_system()` →
stdout пренасочен по pipe → изрисуван в SwiftTerm. Показва device model,
iOS версия, sandbox home directory, свободно място на диска, памет на
процеса.

### Нова команда 2: `sshc`
Модерен SSH2 клиент (парола + remote command execution засега), различен
от вградената `ssh_cmd` (libssh2) на ios_system — регистриран под друго име,
за да съжителстват докато прецениш дали да махнеш старата. Причината да не
презапиша `ssh`: `ssh_cmd` е libssh2-базиран C код, който вече е крос-компилиран
за iOS в самия ios_system repo; `sshc` е чист Swift, по-лесен за поддръжка,
но засега няма интерактивен PTY loop нито key-based auth — вижте NEXT_STEPS.

## Какво е проверено срещу реалния код (не по памет)

По време на писането издърпах живите файлове от GitHub на трите
зависимости, защото два независими опита (README проза срещу header парсинг)
си противоречаха по една сигнатура. Проверих директно:

| API | Проверено като | Резултат |
|---|---|---|
| `replaceCommand` | `ios_system/ios_system.h` @ master | `(NSString* commandName, NSString* functionName, bool)` — приема **име на функция като string** (dlsym), не function pointer. Кодът използва точно това. |
| `ios_setStreams`, `ios_setDirectoryURL`, `ios_setMiniRoot`, `initializeEnvironment` | същия header | Сигнатурите в `ShellEngine.swift` съвпадат точно. |
| `TerminalViewDelegate` протокол | `Sources/SwiftTerm/Apple/TerminalViewDelegate.swift` @ tag `v1.20.0` (резолвва се от `from: "1.2.0"` в Package.swift) | 11 required метода — всичките имплементирани в `TerminalViewController.swift`. |
| `TerminalView` init / `feed()` | `Sources/SwiftTerm/Apple/AppleTerminalView.swift` @ `v1.20.0` | `TerminalView(frame: CGRect)` — **не** parameterless init (го бях сбъркал първия път, оправено). `feed(byteArray:)` и `feed(text:)` съществуват точно както са използвани. |
| `Citadel` platforms/API | `Sources/Citadel/{Client,ClientSession,SSHAuthenticationMethod,SSHConnectionPoolSettings}.swift` @ main | Точната `connect(host:port:authenticationMethod:hostKeyValidator:reconnect:...)` overload, `.passwordBased(username:password:)`, `.acceptAnything()`, `.never` — всички съвпадат буквално. При проверката хванах истински бъг: `client.close()` е `async throws`, а го бях сложил в `defer` (defer тела са синхронни — не компилира). Оправено в `SSHClientCommand.swift` — `close()` сега се вика изрично преди всеки `return`. |

**Съзнателно опростено вместо гадаене:** махнах `ios_switchSession(...)` от
`ShellEngine` — тя очаква стабилен opaque token за разграничаване на
паралелни сесии (табове), а не bridge-нат `Thread` обект. При едно единствено
терминално view това не е нужно; ще влезе с реална multi-tab поддръжка
(NEXT_STEPS т. 4).

## Как да отвориш на Mac

1. `git init` в тази папка (или добави я в съществуващ repo) и commit.
2. `swift build` от терминала — първо ниво проверка на командния слой без
   Xcode UI.
3. За реално iOS приложение: Xcode → File → New → Project → iOS App →
   добави `ios-termux-sandbox` като local Swift Package dependency → във
   вашия `@main App` структура сложи `TermuxSandboxRootView()`.
4. Очаквай компилационни грешки при първия опит — нормално е за код, писан
   без компилатор под ръка. Най-вероятните места: SwiftTerm delegate
   сигнатури, ако версията се е обновила между тази сесия и деня на билда.

## Известни ограничения (не бъгове — записани съзнателно)

- `sshc` поддържа само парола, не SSH ключове.
- `sshc` без команда в края само се свързва и пише съобщение — няма
  интерактивен shell loop.
- Терминалът чете ред по ред (Enter изпраща целия буфер), не байт по байт —
  програми, които четат единични клавиши на живо (nano, python REPL,
  top), няма да работят все още.
