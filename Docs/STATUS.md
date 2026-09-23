# Статус — iOS Termux-style Sandbox

Repo: https://github.com/me7ko-dev/ios-termux-sandbox (private)

## Сесия 6 (2026-09-23) — снапшот при излизане + десктоп (iPhone 13 Pro Max)

**Снапшот / продължаване оттам, докъдето е стигнало.** Нов
`LinuxVMController` (общ за всички табове) + `QMPClient`:
- приложението отива във фонов режим → QMP `stop` + `savevm ios-autosave`
  (вътрешен qcow2 снапшот: RAM, CPU, устройства, диск) в background task,
  после записва `snapshot.json` (cpu/RAM конфигурацията, с която е правен);
- връщане → `cont` + сверяване на часовника + автоматично ново SSH/VNC;
- ако iOS е убил приложението → следващото стартиране пуска QEMU с
  `-loadvm ios-autosave` вместо boot;
- чист `poweroff` в госта → маркерът се трие, следващият старт е нормален
  boot (и `delvm` освобождава мястото на стария снапшот).

Измерено тук (qemu 8.2, същите аргументи): `savevm` 2.9 s (само
терминал) / 7.7 s (с пуснат XFCE); `-loadvm` → SSH вход 8.4 s, → работещ
VNC десктоп 5.5 s; нов boot е ~2.5 мин. Проверено, че съдържанието е
точно от момента на снапшота (файл, записан след него, го няма).

**Десктоп таб.** XFCE в госта, показан през VNC:
- `VNCClient.swift` — собствен RFB 3.8 клиент (VNC auth с DES от
  CommonCrypto, BGRX пиксели, Raw/CopyRect/DesktopSize — без компресия,
  защото „мрежата“ е memcpy в телефона, а компресията би струвала
  емулиран CPU в госта). Протоколът е проверен с Python копие стъпка по
  стъпка срещу истинския TigerVNC 1.12 в госта: auth OK, грешна парола →
  отказ, 1616×744, updates идват.
- `DesktopViewController.swift` — тап = ляв клик, влачене = влачене,
  задържане = десен клик, 2 пръста = scroll (или местене при zoom),
  pinch = zoom; лента: клавиатура, Esc, Tab, Ctrl/Alt (sticky), стрелки.
- Инсталира се при поискване (`desktop-install.sh`, ~250 MB пакети,
  `--no-install-recommends`): отне 13.5 мин под x86 TCG тук. Без
  compositor, Xft DPI 120, тъмна тема, без screensaver/locker. VNC парола —
  случайна, пази се в приложението.
- Снимка на екрана от госта е проверена: панел, часовник, dock, работен плот.

**Профил за iPhone 13 Pro Max** (`DeviceProfile.swift`, `iPhone14,3`):
4 vCPU, 2560 MiB RAM, 256 MiB TCG кеш, десктоп 1616×744 (landscape
екранът × 1.75, кратно на 8). Други устройства — изчислява се.

**Оптимизации на госта** (`guest-tune.sh`, при всяко свързване): махнати
update-motd скриптовете (всеки SSH вход пускаше `apt-check`, което
натоварваше един vCPU с минути под TCG), изключени apt-daily/
unattended-upgrades (заключват dpkg и биха провалили инсталацията на
десктопа).

**Хванати бъгове:** `sudo` трие `DEBIAN_FRONTEND` (env_reset) → debconf
се опитваше да пита интерактивно; сега се подава през `sudo VAR=...`.

**Ограничения:** Firefox в 22.04 е snap, а snapd е изключен за скорост —
браузър трябва да се сложи друг начин (напр. Mozilla PPA като .deb).
Снапшотът изисква същата машинна конфигурация: не пипай `-device`
списъка във `VMConfiguration` без да трием снапшота. Ако iOS прекъсне
приложението по време на `savevm` (>~30 s), снапшотът не се маркира и
следващият старт е нормален boot.


## Сесия 5 (2026-09-23) — пълен Ubuntu 22.04 като VM в приложението

**Цел:** вместо само in-process `ios_system` команди — истински Linux
(Ubuntu 22.04, собствено ядро, systemd, apt, gcc, всичко) вътре в нашето
native приложение, с максималната скорост, която iOS изобщо позволява.

**Какво е реално възможно на iOS (без jailbreak/експлойти):**

| Път | Статус |
|---|---|
| Hypervisor.framework (хардуерна виртуализация) | ❌ изисква частен entitlement `com.apple.private.hypervisor` — само jailbreak/TrollStore |
| proot / chroot / fork+exec на Linux binaries | ❌ няма ptrace, fork/exec, а unsigned код не може да се изпълнява |
| **QEMU TCG с JIT** | ✅ **най-бързото възможно** — изисква JIT: sideload (SideStore/AltStore) + StikDebug, или стартиране от Xcode |
| QEMU TCTI (интерпретатор, UTM SE) | ✅ работи навсякъде без JIT, няколко пъти по-бавно |

Затова: пълна системна VM (aarch64 гост на aarch64 iPhone), приложението
само избира JIT build-а, когато JIT е включен (`csops` → `CS_DEBUGGED`),
иначе TCTI. Това не е "фалшива" VM с орязани команди — гостът е
немодифициран Ubuntu cloud image с истинско ядро 5.15.

**Архитектура (нов код):**

- `Sources/CQEMUBootstrap/` — C: `dlopen` на `qemu-aarch64-softmmu.framework`,
  `qemu_init`/`qemu_main_loop`/`qemu_cleanup` на отделна pthread (8 MB стек);
  `exit()` на QEMU се хваща с `atexit` + `pthread_exit`, за да не убие
  приложението. Същите entry points и трик като UTM
  (`Services/UTMProcess.m`, `UTMQemuSystem.m` — прочетени в source-а, не по памет).
- `Sources/LinuxVM/UbuntuRelease.swift` — закован release
  `release-20260913` (не `release/`, който се мести), SHA-256 от официалните
  SHA256SUMS, проверени срещу реално сваляне.
- `ImageStore.swift` — сваля ядро + initrd + qcow2 (~750 MB) в
  Application Support (изключено от iCloud backup), проверява SHA-256.
- `QCOW2.swift` — разширява виртуалния размер на диска от 2.2 GB на 32 GB
  чрез редакция на qcow2 header-а (няма qemu-img на iOS). Алгоритъмът е
  тестван върху реалния image: `qemu-img check` → „No errors“, в госта
  `df -h /` → 31G.
- `VMConfiguration.swift` — QEMU аргументите: `virt`, `cortex-a72`, MTTCG,
  direct kernel boot, virtio-blk/net/rng, user-mode мрежа с
  `127.0.0.1:2222 → :22`, серийна конзола на `127.0.0.1:45022`. RAM ≈
  половината от `os_proc_available_memory()` (768 MB–4 GB), до 4 vCPU.
- `SerialConsole.swift` — показва boot лога; резервен терминал.
- `SSHTerminalSession.swift` — Citadel `withPTY`: истински PTY, resize
  събития (vim/htop/tmux работят правилно). API-то проверено в Citadel
  0.12.1 и Wellz26/swift-nio-ssh source-а.
- `LinuxTerminalViewController.swift` — целият поток в терминала:
  сваляне → boot (сериен лог) → при маркера `IOS-VM-READY` превключва на SSH.
- `Guest/cloud-init/` + `Scripts/make-seed-iso.py` → `Resources/seed.iso`:
  user `ubuntu` / парола `ubuntu`, sudo без парола, autologin на серийната
  конзола, growpart, маркер за готовност, синхронизация на часовника.
- Root view-ът вече е tab bar: **Ubuntu** (VM) и **iOS shell** (стария ios_system).

**Верифицирано реално (qemu-system-aarch64 8.2, TCG, същите аргументи):**
Ubuntu 22.04.5, ядро 5.15.0-191 aarch64, cloud-init `done`, SSH вход с
парола, PTY resize (100x30 → 120x40 видян от `stty size`), autologin на
серийната конзола, `sudo`, 31 GB root, `apt-get install htop
build-essential`, `gcc` компилира и пуска C програма, рестарт на госта →
пак стига до `IOS-VM-READY`. Първи boot (с cloud-init) ≈ 2.5 мин под TCG на
4-ядрен x86 сървър.

**Хванат и оправен реален бъг:** ядрото на cloud image-а няма драйвер за
RTC-то на `virt` (`rtc-pl031` е в `linux-modules-extra`), а NTP може да е
недостъпен → гостът тръгва с часовник на датата на build-а и `apt update`
отказва всички repo-та („not valid yet“). Поправка: приложението подава
`ios.epoch=<unix time>` на kernel cmdline, `ios-clock.service` сверява
часовника рано при всеки boot, а при всяко SSH свързване приложението
изпълнява `sudo date -s @now` (покрива времето, докато iOS е държал
приложението suspend-нато).

**QEMU за iOS:** не се build-ва от source (това е 1–2 часа
`build_dependencies.sh` на UTM) — `Scripts/fetch-qemu-frameworks.sh`
вади от официалните `UTM.ipa` (JIT) и `UTM-SE.ipa` (TCTI) само
`qemu-aarch64-softmmu` и транзитивните му `@rpath` зависимости (`otool -L`),
преименува TCTI варианта на `qemu-aarch64-softmmu-tcti.framework` и
проверява с `nm`, че `qemu_init`/`qemu_main_loop`/`qemu_cleanup` са
експортирани. **Лиценз:** QEMU е GPLv2 — ако разпространяваш приложението,
то трябва да е под GPL-съвместими условия.

**Инсталируемо приложение:** `App/project.yml` (XcodeGen) + нов CI job
`package-ipa` → artifact `UbuntuTerminal-ipa` (ldid fake-sign с
`increased-memory-limit` + `extended-virtual-addressing`, като UTM).
Инсталиране: SideStore/AltStore → после StikDebug за JIT.

**CI резултат: ✅ зелен** (run
[35823397466](https://github.com/me7ko-dev/ios-termux-sandbox/actions/runs/35823397466)):
`LinuxVM` компилира за iOS, приложението се link-ва, `package-ipa` вади
QEMU от UTM (проверката с `nm` за `qemu_init`/`qemu_main_loop`/`qemu_cleanup`
мина и за двата варианта), artifact `UbuntuTerminal-ipa` ≈ 79 MB. В
`Frameworks/` са `qemu-aarch64-softmmu` (JIT), `qemu-aarch64-softmmu-tcti`
и зависимостите им (glib, gio, slirp, pixman, spice-server, virglrenderer,
zstd…). По пътя хванати два реални проблема: `libgit2` изисква `libiconv`
(никога не е било link-вано в истинско приложение досега) и
`codesign --remove-signature` чупеше ldid подписа на 10 framework-а
(грешката се губеше в `find -exec`, сега CI гърми при такава).

**НЕ е верифицирано:** стартиране на реално iPhone/iPad — нямам устройство.
Първото нещо за проверка: инсталирай IPA-то, отвори таба Ubuntu.

**Известни ограничения (реални, не пропуски):**
- QEMU може да се стартира само веднъж на процес — след `poweroff` в госта
  приложението трябва да се рестартира.
- iOS suspend-ва приложението във фон → VM-ът замръзва, докато не се върнеш
  (SSH сесията може да падне; Enter отваря нова).
- iOS 26 устройства с TXM: JIT през дебъгер работи по друг начин;
  QEMU build-ът на UTM съдържа нужното съдействие, но на такова устройство
  още не е тестван. Без JIT → TCTI (работи, по-бавно).
- snapd е маскиран през kernel cmdline (seed-ването на snaps отнема минути
  под емулация); `VMConfiguration.disableSnapd = false` го връща.
- `ping` не работи (QEMU user networking не пренася ICMP); TCP/UDP работят.


## Сесия 4 (2026-09-18, продължение) — Python, Lua, git, network_ios

Четири нови "библиотеки" добавени наведнъж, всяка верифицирана срещу
реалните upstream файлове (headers/binary symbols/checksums свалени и
проверени на ръка), не по памет:

**Python 3.7.13** (`python3_ios` + `pythonA-E` binary targets). Открих
чрез сваляне и разглеждане на реалния xcframework, че framework-ът е
`python3_ios.framework`, функцията — `python_main` (потвърдено от
header-а), **не** `Python.framework/Py_BytesMain`, както е в текущия
a-Shell plist — a-Shell вече е мигрирал към много по-нов, различно
пакетиран Python 3.13, който не е достъпен като преизползваем SPM пакет.
По-важно: тези binary targets **не носят никакъв `.py` файл** — чист
интерпретатор без стандартна библиотека, `import os` би гръмнал веднага.
Добавих `Sources/TermuxSandboxApp/Resources/PythonHome/lib/python3.7/`
— истинска, изтеглена (sparse git clone на `python/cpython` @ `v3.7.13`,
същата версия) стандартна библиотека, подрязана от 42MB/1635 файла до
17MB/620 (маха `test/`, `idlelib/`, `turtledemo/` — GUI/тестови неща без
стойност в терминал). `ShellEngine.configurePythonEnvironment()` сочи
`PYTHONHOME` към нея при старт. PSF лиценз копиран до нея.

**Lua** (`lua_ios`). Символите `lua_main`/`luac_main` потвърдени с груб
strings-еквивалент върху сваления binary (нямаше `nm`/`strings`/`objdump`
на разположение тук — написах Python regex вариант). a-Shell-ският plist
запис за lua излезе точен, преизползван директно.

**`network_ios` — възстановен.** Форкнах в
`me7ko-dev/network_ios`, поправих единствено checksum-а в `Package.swift`
(реалният sha256 на v0.2 асета е `18e96112...`, не `89a465b3...`, каквото
пише upstream) — `.zip`-ът пак идва от оригиналния holzschu release URL,
форкът само коригира едно число. (Страничен ефект: `git checkout` на
форка се спъна в няколко Windows-невалидни имена на файлове от
vendored bind9 source tree и в крайна сметка commit-на само поправения
`Package.swift` — безобидно, SPM никога не чете тези C-файлове за
`.binaryTarget`.)

**`git`** — ново, писано от нулата, `Sources/GitCommand/`, върху
`light-tech/SwiftGit2` (`spm` branch — единствената, некотвена версия с
изобщо SPM поддръжка) + транзитивен `Clibgit2` (прекомпилиран libgit2,
checksum проверен на ръка). Поддържа: `init`, `clone` (с опционална
HTTPS token автентикация през `GIT_USERNAME`/`GIT_TOKEN` env vars),
`status`, `add`, `commit`, `log`, `fetch` (само публични repo-та).
**Съзнателно НЕ поддържа `push`/`pull`/`merge`/`branch`/`checkout`** —
проверих директно в SwiftGit2 source-а: тази библиотека изобщо няма
Swift API за push или merge, само суровия `Clibgit2` C API го има, а
писане на собствени bindings за push/refspecs без нито едно устройство
за тест е риск, който съзнателно не поемам тук. Друго реално
ограничение, хванато при четене на кода: `commit(message:signature:)`
изисква вече съществуващ HEAD/parent — не може да направи самия първи
commit в чисто нов repo (нужният `unsafeIndex()`/tree-writing API не е
public извън SwiftGit2 модула). И двете — записани в кода, не догадки.

**Резултат: ✅ зелен build** (run
[35395454328](https://github.com/me7ko-dev/ios-termux-sandbox/actions/runs/35395454328),
3м8с), след една допълнителна поправка: `python3_ios`/`lua_ios` също се
оказаха със същия проблем като по-рано `network_ios` — единственият им
git tag (`v1.0`/`1.0`) е отпреди `Package.swift` изобщо да съществува в
тези repo-та, `swift package resolve` гърмеше с "`/Package.swift`
doesn't exist". Сменени на `branch: "master"`, оттам всичко мина накуп.

Всичките четири нови "библиотеки" (Python, Lua, `git`, `network_ios`) +
всичко от предните сесии сега компилират заедно в едно приложение.
Първи път проектът има реален, макар и неверифициран на устройство,
build с почти пълния планиран команден набор.

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
