# План — следващи 3-5 библиотеки/команди

Подредени по това колко реална Termux функционалност добавят спрямо
инженерните усилия.

## 1. Верифицирай вече бандлваните ios_system команди (проверка, не нов код)
Проверих живия `Package.swift` на ios_system: продуктът `"ios_system"`, от
който вече зависи `TermuxSandboxApp`, е дефиниран като
`.library(name: "ios_system", targets: ["ios_system", "awk", "curl_ios",
"files", "shell", "ssh_cmd", "tar", "text", "mandoc", "perl", "perlA",
"perlB"])` — всеки target е прекомпилиран `.xcframework`. С други думи
`ls`/`cat`/`cp` (files), `curl` (curl_ios), `tar`, `grep`/`sed` (text),
`ssh`/`scp`/`sftp` (ssh_cmd), `awk`, `man` (mandoc), `perl` би трябвало да
работят **веднага**, само от съществуващия dependency — не се изисква нов
ред код. Първата задача на Mac не е "добави dependency", а "build + пусни
`commandsAsArray()` в sysinfo-style debug команда, за да потвърдиш кое
реално се е регистрирало" — прекомпилираните xcframeworks понякога изостават
версийно от README-то и си струва да провериш какво точно съдържат.
**Усилие:** много ниско (verification pass). **Стойност:** много висока —
това е 80% от базовия Termux опит, вече изтеглено, само чака build.

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

---

Предложение за ред на изпълнение в Сесия 2: **т.1 → т.2 → т.5**, защото
т.1 е евтина и веднага разширява командния набор, т.2 отключва
интерактивност за всичко останало (включително т.5), а т.3/т.4 са
самостоятелни подобрения, които не блокират нищо друго.
