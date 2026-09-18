# Статус — iOS Termux-style Sandbox

Repo: https://github.com/me7ko-dev/ios-termux-sandbox (private)

## Сесия 4 (2026-09-18, продължение) — git, SSH ключове, network_ios, bc/dc, Python

Разширяване по `Docs/ROADMAP.md` — целта смени обхвата от "верифицирай
съществуващото" към "вкарай максимума реална Termux функционалност,
докато native track-ът продължава да компилира". Пет последователни
commit-а, всеки push-нат и проверен през CI отделно:

1. **SSH ключове за `sshc`** (`-i keyfile [-kp passphrase]`, RSA/ed25519
   през Citadel's `SSHKeyDetection`) — първият push не компилира
   (`Result<_, String>`, String не conform-ва на `Error`), оправено с
   малък `KeyAuthError` wrapper. Виж `NEXT_STEPS.md` т.3.
2. **`git` команда** — нов `GitCommand` target върху
   `joehinkle11/SwiftGit3` (fork на SwiftGit2 с vendor-нати prebuilt
   libgit2/libssh2/openssl xcframeworks, реален `ios-arm64` device slice).
   `clone`/`status`/`add`/`commit`/`log`/`push`. Виж т.3.5.
3. **`network_ios` re-enable** — потвърдих upstream checksum bug-а с
   директен `sha256sum` (не просто "не работи"), после vendor-нах
   xcframework-а локално (`Vendor/network_ios.xcframework`, `path:`
   binaryTarget вместо `url:`+`checksum:`) вместо да чакам upstream
   fix. Отключва `dig`/`ping`/`nc`/`telnet`/... Виж т.3.6.
4. **`bc`/`dc`** — от нулата на чист Swift (не port на GNU C source),
   съзнателно `Double`-precision, не arbitrary-precision. Първият push
   не компилира (`BCParser(trimmed).parseExpression()` — mutating метод
   върху temporary struct стойност), оправено в следващия commit. Виж т.6.
5. **Embedded Python 3.13** — план-ът сочеше `holzschu/python_ios`,
   оказа се негоден при проверка (Python 2.7, без SPM manifest, ръчен
   Xcode build). Вместо това `beeware/Python-Apple-support` (реален,
   поддържан CPython 3.13.15) — vendor-нат `Python.xcframework` +
   изрязан `Lib/` от `python/cpython` tag `v3.13.15` (test/idlelib/
   tkinter/turtledemo/ensurepip изрязани). Нов `CPythonEmbed` C target
   (отделен от Swift, защото `cpython/initconfig.h` е `exclude header`
   в `Python.framework`'s module.modulemap). **Честно документирано
   ограничение:** дали `dlopen()` работи за loose `.so` extension
   modules (не цели frameworks) под iOS code-signing не можа да се
   провери без реално устройство — виж пълните детайли в т.5.

Всеки vendor-нат xcframework следва един и същ модел: изтегли реалния
release asset, провери/сравни sha256 директно вместо да вярваш на
upstream manifest-а, изрежи simulator/dSYM/build-only слоеве, комитни
като локален `path:` binaryTarget. Repo-то порасна с ~90MB vendored
binaries (SwiftGit3-related dependency resolved remotely, не в repo-то;
локално vendor-нати: network_ios 11MB + Python.xcframework 7.7MB +
python-stdlib 24MB).

**Резултат: ✅ и петте commit-а минаха CI** (run
[#11](https://github.com/me7ko-dev/ios-termux-sandbox/actions/runs/35395211070)
SSH ключове+git, run
[#14](https://github.com/me7ko-dev/ios-termux-sandbox/actions/runs/35395598557)
network_ios, run
[#17](https://github.com/me7ko-dev/ios-termux-sandbox/actions/runs/35397272759)
Python — ~4 минути build заради по-голямото repo и нова dependency
resolution). bc/dc-ят first опита (run #16) не компилира заради
mutating-метод върху temporary struct — оправено в следващия push
заедно с Python-а.

Паралелно: `Docs/ROADMAP.md` записва пълния разширен план, включително
честно ограничение, че "буквално всички Termux пакети" не могат да
влязат в native iOS sandbox (няма `fork()`/`exec()`, Apple забранява
динамичен код), плюс отделен по-нисък приоритет "Track B" (браузър/WASM
front-end — xterm.js + isomorphic-git + Pyodide) като fallback, ако
native track-ът някога наистина опре в нещо неразрешимо оттук.

## Сесия 3 (2026-09-18, продължение) — първи реален CI build

Добавен `.github/workflows/ios-build.yml` — build на `macos-15` GitHub
Actions runner, за да хващаме компилационни грешки без физически Mac
(`xcodebuild build -destination 'generic/platform=iOS Simulator'` за
трите library продукта).

Два проблема хванати и оправени в тази сесия:

1. **SSH submodule без CI ключ.** `ios_system`'s `wasm3` submodule е
   регистриран през `git@github.com:...` — runner-ът няма SSH ключ,
   `Permission denied (publickey)`. Оправено с
   `git config --global url."https://github.com/".insteadOf "git@github.com:"`
   като стъпка преди resolve.
2. **`network_ios` checksum mismatch — ъпстрийм бъг, не наш.**
   `swift package resolve` гърми с "checksum of downloaded artifact ...
   does not match checksum specified by the manifest" за
   `network_ios.xcframework.zip`. Проверих кода — `network_ios` се ползва
   само за runtime dlopen през `commandDictionary.plist` (dig/ping/nc/
   telnet/...), няма директни Swift API извиквания в нашия код — затова
   **временно закоментиран** от `Package.swift`, за да не блокира build-а
   на всичко останало. Ефект: тези конкретни мрежови команди няма да
   тръгнат при извикване (dlopen ще fail-не за тях), докато не се оправи
   ъпстрийм или не форкнем `network_ios` с поправен checksum.

**Резултат: ✅ зелен build** (run
[35392184724](https://github.com/me7ko-dev/ios-termux-sandbox/actions/runs/35392184724),
2м15с) — след 6 итерации оправяне на CI/toolchain проблеми (SSH
submodule, счупен `network_ios` checksum, Simulator-несъвместими
`perl*` framework-и, грешна минимална iOS версия, SwiftTerm plugin
validation) стигнахме и до един **реален бъг в кода**:
`TerminalViewController.swift` правеше `if let` върху
`UnicodeScalar(UInt8)`, който е non-failable инициализатор (всеки байт
0...255 мапва към валиден Latin-1 scalar) — не компилираше. Оправено.

Първи път проектът реално компилира от началото на writing-without-Mac
експеримента. Следващата стъпка е т.2 от `NEXT_STEPS.md` (интерактивен
PTY loop), плюс да решим `network_ios` (форк с поправен checksum или
изчакване на ъпстрийм fix).

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

**Поправка:** по-рано тук пишеше "пусни `swift build` от терминала като
първа проверка" — това вероятно **няма да работи** и е подвеждащо. Плейн
`swift build` строи за host платформата (macOS), а `TerminalViewController.swift`
и `App.swift` правят безусловен `import UIKit`, което го няма на чист macOS
build (само на iOS/Catalyst) — плюс ios_system/network_ios/SwiftTerm
xcframeworks вероятно нямат macOS slice изобщо (правени са специално за
iOS терминални апове като a-Shell, който няма Mac версия). Не мога да го
тествам оттук, но не бих разчитал на `swift build` без изричен iOS SDK/target
override — по-простият и сигурен път е директно през Xcode:

1. `git clone https://github.com/me7ko-dev/ios-termux-sandbox.git`
2. Xcode → File → New → Project → iOS → App (SwiftUI, Swift) → кръсти го
   напр. `TermuxSandboxHost`.
3. В новия проект: File → Add Package Dependencies → Add Local... → посочи
   клонираната `ios-termux-sandbox` папка.
4. Линкни и трите library продукта към App таргета: `TermuxSandboxApp`,
   `SysInfoCommand`, `SSHClientCommand` (последните два технически се теглят
   транзитивно през `TermuxSandboxApp`, но добави ги изрично ако Xcode не
   ги añade сам).
5. В генерирания `@main App` файл замени тялото с:
   ```swift
   import SwiftUI
   import TermuxSandboxApp

   @main
   struct TermuxSandboxHostApp: App {
       var body: some Scene {
           WindowGroup { TermuxSandboxRootView() }
       }
   }
   ```
6. Избери iOS Simulator destination (напр. iPhone 15) → Cmd+R.
7. Очаквай компилационни грешки при първия опит — нормално е за код, писан
   без компилатор под ръка. Най-вероятните места: SwiftTerm delegate
   сигнатури, ако версията се е обновила между тази сесия и деня на билда,
   plus каквото Xcode ти покаже за `Bundle.module`/resource bundling.
8. Като заработи, пусни `commands` в терминала — това е verification
   инструментът за NEXT_STEPS т.1 (виж там).

## Известни ограничения (не бъгове — записани съзнателно)

- `sshc` поддържа само парола, не SSH ключове.
- `sshc` без команда в края само се свързва и пише съобщение — няма
  интерактивен shell loop.
- Терминалът чете ред по ред (Enter изпраща целия буфер), не байт по байт —
  програми, които четат единични клавиши на живо (nano, python REPL,
  top), няма да работят все още.
