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

## 3. SSH ключове за `sshc` (вместо само парола) — [DONE в Сесия 4, чака build]

`sshc` вече приема `-i <keyfile>` [+ `-kp <passphrase>` за криптирани
ключове]. Реализация в `Sources/SSHClientCommand/SSHClientCommand.swift`:

- `SSHKeyDetection.detectPrivateKeyType(from:)` (публично Citadel API)
  парсва OpenSSH-формата на ключа директно и връща реалния тип
  (`.rsa`/`.ed25519`/...) — не гадаем по разширение на файла.
- За RSA: `Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey:)`.
- За ed25519: `Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey:)`.
- `decryptionKey: Data?` е подвеждащо име в upstream API — това е
  суровият passphrase като UTF-8 bytes, не derive-нат ключ; Citadel сама
  пуска `bcrypt_pbkdf` срещу salt-а, вграден в самия ключ.
- `-i` има приоритет пред `-pw`, ако и двата са подадени.
- `~` в пътя се разширява (`expandingTildeInPath`), за ключове под
  app container-а, напр. `~/Documents/.ssh/id_ed25519`.

**Съзнателно НЕ покрито:** ECDSA (`p256`/`p384`/`p521`) — Citadel го
поддържа със същия модел, но не е честа Termux нужда; тривиално добавяне
по-късно (виж `keyBasedAuthenticationMethod` — просто нов `case` в
switch-а). Няма и UI за генериране/импорт на нов ключ от Files app —
това е т.8 в `ROADMAP.md`.

**Останало за Mac/CI:** build + реален тест срещу сървър с публичния ключ
инсталиран, за да потвърдим, че самият handshake (не само парсването на
файла) минава.

## 4. Multi-tab / множество сесии
`ios_system` поддържа паралелни сесии през `ios_switchSession(sessionid)` —
всяка с отделен working directory и environment. Нарочно не го включих в
Сесия 1 (виж STATUS.md), защото token-ът трябва да е стабилен opaque
идентификатор, не гадан bridge на `Thread`. Правилният подход: генерирай
`UUID` per tab, пази map tab→`UnsafeRawPointer`, подавай го консистентно на
всяко `ios_setDirectoryURL`/`ios_system` повикване за този таб.
**Усилие:** средно. **Стойност:** UX паритет с Termux tabs, не е блокер за
базова функционалност.

## 5. Python (python_ios / embedded CPython)
holzschu поддържа отделен `python_ios` repo (статично компилиран CPython за
iOS) — това е "python via embedded interpreter", за което оригиналният
бриф изрично пита. По-тежко от горните: изисква vendoring на прекомпилиран
`Python.xcframework` (compile-from-source на CPython за iOS от нулата не е
разумно за ръчна поддръжка) и внимание към `pip install` — работят само
чисти Python пакети или такива с precompiled wheels за iOS; нищо с C
extension компилация на място (пак заради sandbox забраната за компилатор
extern процес).
**Усилие:** високо. **Стойност:** висока — това е single biggest "истински
Termux" очакване от потребителите.

## 6. `bc`/`dc` (по избор, малко усилие)
`bc_ios` няма отделен SPM repo, но самият `bc`/`dc` изходен код е обикновен,
преносим C (dc.c/bc от BSD calculator tools) — може да се portne като
собствен малък SPM target по същия модел като `sysinfo`, вместо да чакаме
holzschu да пусне SPM пакет за него. Ниско приоритетно — рядко ползвана
Termux команда.

---

Актуализиран ред на изпълнение: **т.1 done → т.2 → т.5**, защото т.2
отключва интерактивност за всичко останало (включително т.5), а т.3/т.4/т.6
са самостоятелни подобрения, които не блокират нищо друго.
