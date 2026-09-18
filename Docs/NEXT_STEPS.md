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

## 2. Интерактивен PTY loop за терминала
В момента `TerminalViewController` изпраща цял ред при Enter. Termux/a-Shell
работят байт по байт: всяка клавишна натиск отива веднага в `thread_stdin`
на текущо изпълняваната команда през входен pipe (огледално на изходния
pipe, който вече имаме в `ShellEngine`). Без това `python3` (REPL), `vim`,
`top`, дори `sshc` в интерактивен режим не могат да работят истински.
**Усилие:** средно. **Блокира:** python REPL, editor команди, interactive ssh.

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
