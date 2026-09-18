# План — следващи 3-5 библиотеки/команди

Подредени по това колко реална Termux функционалност добавят спрямо
инженерните усилия.

## 1. Верифицирай вече бандлваните ios_system команди — [DONE в Сесия 2, чака build]

Първоначалната хипотеза ("линкваш продукта, всичко се регистрира само") се
оказа грешна при проверка на реалния код:

- Изтеглих `Resources/commandDictionary.plist` от `holzschu/ios_system` —
  тя мапва команда → framework за **само 77 команди**, и то `bc_ios` и
  `network_ios` framework-ите, към които сочи, изобщо не са targets в
  `ios_system`'s own `Package.swift` — тоест `bc`/`dc`/`ping`/`dig`/`nc`/... щяха
  да сочат към framework, който не съществува в билда.
- Нито `man`, нито `perl` изобщо присъстват в тази plist — а `mandoc` и
  `perl` targets вече бяха в нашия `Package.swift`. Проверих как реалното
  приложение a-Shell (същия автор) решава това: то **не разчита** само на
  `initializeEnvironment()` — бандлва собствено, по-пълно
  `Resources/commandDictionary.plist` (103+ команди в нашия обхват, 143 общо
  с неща като ffmpeg/vim/ImageMagick, които ние нямаме) и го зарежда изрично
  през `addCommandList(path)` при старт.

Направих същото, стеснено до framework-ите, които реално линкваме:

- Добавих **`network_ios`** като нов package dependency (отделен repo,
  собствен `Package.swift`, target `network_ios`) — отключва
  `dig`/`host`/`ifconfig`/`nc`/`nslookup`/`ping`/`rlogin`/`telnet`/`whois`/`wol`.
- Филтрирах a-Shell's командния речник до **103 команди**, чиито framework
  е точно измежду тези, които вече линкваме (`SELF`, `awk`, `curl_ios`,
  `files`, `network_ios`, `shell`, `ssh_cmd`, `tar`, `text`, `mandoc`,
  `perl`) и го vendor-нах като resource:
  `Sources/TermuxSandboxApp/Resources/commandDictionary.plist`.
- `ShellEngine.start()` вече вика `addCommandList(...)` с този файл (виж
  `loadBundledCommandDictionary()`), а нова диагностична команда `commands`
  (`CommandsListCommand.swift`) пуска `commandsAsArray()` и печата
  всичко регистрирано — това е реалният verification инструмент, пусни го
  на устройство, за да видиш кое точно е хванало.
- **Съзнателно пропуснато:** `bc`/`dc` — `bc_ios` няма собствен SPM repo
  (`holzschu/bc_ios` връща 404), затова не са в обхвата. Ако ти трябват,
  влизат в отделна точка (виж по-долу).

**Останало за Mac:** build + пусни `commands` в терминала. dlopen на липсващ
framework се проваля тихо на ниво **отделна команда** при извикване, не
при регистрация — възможно е списъкът от `commandsAsArray()` да показва
име, което все пак гърми при реално изпълнение, ако framework-ът не се е
embed-нал правилно от Xcode. Това е първото нещо за проверка.

## 2. Интерактивен input за терминала — [DONE в Сесия 3, чака build]

`ShellEngine.run` вече отваря втори `Pipe()` за stdin (огледално на
съществуващия за stdout) и го подава през `ios_setStreams` вместо
процесния `stdin`, който никой не пишеше в него в sandbox-нато приложение —
всяка команда, която извика `read()`/`fgets()`, просто щеше да виси
завинаги. Ново `isRunning` флагче на `ShellEngine` + `sendInput(_:)` метод.

`TerminalViewController.send` вече проверява `shellEngine.isRunning`:
докато тече команда, всеки байт отива направо в `sendInput` (Enter →
`\n` за fgets-style четци), вместо да се буферира ред по ред. Извън
изпълнение — старото поведение (локален line buffer, dispatch на Enter)
си остава, защото `ios_system()` приема цял command line наведнъж, не е
персистиращ shell, който чете произволно от stdin между команди.

**Съзнателно НЕ направено — истинско ограничение, не bug:** няма реален
pty, затова backspace по време на изпълнение стига до командата като
буквален байт `0x7F`, не се интерпретира като "изтрий предходния
символ" (само локалното ехо в терминала визуално го трие). Програми със
собствен readline/raw-mode редактор (истински интерактивен `vim`) няма
да виждат canonical line editing от нас — за това трябва пълен pty
слой, отделна много по-голяма задача.

**Останало за Mac:** build + реален тест с `python3` (ако/когато влезе
т.5) или `sshc` в интерактивен режим — засега само `sysinfo`/`sshc`
some-command съществуват, нито един не чете stdin, така че няма как да
се тества end-to-end преди т.5 или нова тестова команда, която чете ред
от stdin.

## 3. SSH ключове за `sshc` (вместо само парола)
Citadel поддържа `.rsa(...)`/`.ed25519(...)` в `authenticationMethod` —
трябва UI/команден флаг за посочване на private key файл в sandbox-а (напр.
`~/.ssh/id_ed25519` под app container-а) плюс passphrase handling. Реална
Termux паритетна нужда — почти никой не ползва password auth по навик.
**Усилие:** ниско-средно, основно UX за избор на key файл.

## 4. Multi-tab / множество сесии
`ios_system` поддържа паралелни сесии през `ios_switchSession(sessionid)` —
всяка с отделен working directory и environment. Нарочно не го включих в
Сесия 1 (виж STATUS.md), защото token-ът трябва да е стабилен opaque
идентификатор, не гадан bridge на `Thread`. Правилният подход: генерирай
`UUID` per tab, пази map tab→`UnsafeRawPointer`, подавай го консистентно на
всяко `ios_setDirectoryURL`/`ios_system` повикване за този таб.
**Усилие:** средно. **Стойност:** UX паритет с Termux tabs, не е блокер за
базова функционалност.

## 5. Python (python_ios / embedded CPython) — [DONE в Сесия 4, чака build]

Виж `Docs/STATUS.md` Сесия 4 за пълните детайли — `python3_ios` +
bundlнат CPython 3.7.13 stdlib (свален от `python/cpython` @ `v3.7.13`,
подрязан). Останало: реален device тест (`python3 -c "import os, json;
print('ok')"`), `pip install` изобщо не е адресиран (само чисти Python
пакети биха работили — никаква C extension компилация на място), и
оценка дали да мигрираме към по-нов Python (a-Shell вече е на 3.13, но
няма преизползваем SPM пакет за него — би значило vendoring на
собствен prebuilt `Python.xcframework`).

## 6. `bc`/`dc` (по избор, малко усилие)
`bc_ios` няма отделен SPM repo, но самият `bc`/`dc` изходен код е обикновен,
преносим C (dc.c/bc от BSD calculator tools) — може да се portne като
собствен малък SPM target по същия модел като `sysinfo`, вместо да чакаме
holzschu да пусне SPM пакет за него. Ниско приоритетно — рядко ползвана
Termux команда.

## 7. `git` (SwiftGit2) — [DONE в Сесия 4, чака build] с реално ограничение

`Sources/GitCommand/` покрива `init`/`clone`/`status`/`add`/`commit`/`log`/
`fetch` през `light-tech/SwiftGit2`. **Push/pull/merge/branch/checkout не
съществуват в тази библиотека изобщо** — проверено директно в source-а
(`SwiftGit2/Repository.swift`, `Remotes.swift`), не предположено. Единственият
път напред е суров `Clibgit2` C API (`git_remote_push`, `git_push_options`,
refspecs на ръка) — обем, сравним с писането на нов SwiftGit2 модул, и
без нито едно устройство за реален тест на network/auth код от този
калибър. Не пипай това, докато нямаме поне веднъж потвърден работещ
build на реално устройство/Simulator. Друго хванато ограничение:
`commit(message:signature:)` не може да направи самия първи commit в
чисто нов repo (няма public API за zero-parent tree write извън
модула) — работи само след `clone` или следващи commit-и.

---

Актуализиран ред на изпълнение: **т.1, т.2, т.5, т.7 done, чакат build**.
Останало необвързано: т.3 (SSH ключове), т.4 (multi-tab), т.6 (bc/dc) —
самостоятелни подобрения, не блокират нищо друго. Следваща реална
стъпка е device/Simulator тест на всичко натрупано дотук, не поредна
библиотека — купчината неверифицирано (само CI-compiled) вече е
достатъчно голяма.
