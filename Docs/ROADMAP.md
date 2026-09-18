# Разширен roadmap — "супер приложение" с всичко

**Честно ограничение, важно да е записано:** "буквално всички" Termux
пакети (хиляди, много изискващи `fork()`/`exec()`, компилатори на място,
произволни ELF бинарки, `apt` package manager) физически не могат да
влязат в нативен iOS sandbox — Apple забранява динамично изпълним код,
а iOS няма `fork()`. Таванът на **Track A** е: всичко, което `ios_system`/
a-Shell екосистемата вече е портнала като статична библиотека (~140
команди), плюс каквото добавим сами по същия модел (git, ssh с ключове).
За нещата отвъд това (произволни pip/apt пакети, компилатори, нативни
бинарки) единственият реалистичен път е **Track B** (браузър/WASM), където
sandbox ограничението не важи по същия начин. Максимизираме и двата пътя
паралелно, но не обещаваме "100% Termux" в .ipa — само в браузъра това е
реалистично.

Целта смени обхвата спрямо `NEXT_STEPS.md`: не само верифициране на
съществуващи команди, а колкото се може по-пълен Termux паритет
(всички библиотеки, `git`, максимум функционалност), плюс изричното
изискване приложението да е ползваемо **и без компилация в .ipa** — т.е.
паралелен браузър-базиран front-end. Приоритетът остава да продължим
по нативния Swift/CI релс, докато работи — той вече има зелен build.

## Track A — Native iOS (Swift/SwiftPM, приоритет сега)

Изпълнява се последователно, всяка стъпка → commit → push → изчакай
GitHub Actions "iOS Build Check" да светне зелено, преди следваща.

1. ~~Верифицирай бандлваните `ios_system` команди~~ — DONE (Сесия 2).
2. ~~Интерактивен stdin за терминала~~ — DONE (Сесия 3).
3. ~~SSH ключове за `sshc`~~ — DONE (Сесия 4).
4. ~~`git` команда~~ — DONE (Сесия 4, `GitCommand` върху SwiftGit3).
5. ~~`network_ios` re-enable~~ — DONE (Сесия 4, vendor-нат локално).
6. ~~`bc`/`dc`~~ — DONE (Сесия 4, чист Swift, Double-precision).
7. ~~Python (embedded CPython 3.13)~~ — DONE (Сесия 4, beeware/Python-Apple-support).
8. ~~SSH keys довършване: `keygen` команда~~ — DONE (Сесия 4). Генерира
   ed25519 keypair директно в OpenSSH формат (`Curve25519.Signing
   .PrivateKey.makeSSHRepresentation`), веднага съвместим с `sshc -i`/
   `git clone -i`. **Съзнателно НЕ включено:** encrypted private keys
   (`-N passphrase`) — Citadel's публично API за сериализация няма cipher
   опция; импорт от Files app document picker (UI слой, не команда —
   не е блокиращо, `-i <path под sandbox>` вече работи с всеки path,
   включително такъв, копиран ръчно през Files app в app container-а).
9. ~~Multi-tab / много сесии~~ — DONE (Сесия 4, `TabbedTerminalViewController`
   + `ios_switchSession` per `ShellEngine`).
10. Разширяване на бандлвания `commandDictionary.plist` максимално към
    пълния a-Shell списък (143 команди), доколкото framework-ите за тях
    реално се линкват в Package.swift (ffmpeg/vim/ImageMagick са отделни,
    по-тежки vendor-ирания — оценяваме поотделно дали си заслужават).
    Оставащо, ниско приоритетно.

## Track B — Browser/no-compile front-end (паралелно, по-нисък приоритет)

Изискване: същата функционалност да е достъпна и без Xcode build/.ipa —
директно в браузър. Реалистичният път е **отделен, независим уеб проект**,
не re-compile на Swift кода (Swift/ios_system не тръгват в браузър):

- Терминален UI: `xterm.js` (същата библиотека, на която реално стъпва
  и SwiftTerm концептуално) в статична страница/PWA.
- Команден бекенд в браузъра: WASM shell (`busybox.wasm` / `wasm-shell`
  проекти) за базови coreutils (`ls`/`cat`/`grep`/`tar`/...), или
  connect към истински бекенд (напр. лек контейнер/VM в облак) през
  WebSocket за нещата, които WASM не покрива (реален SSH client, `git`
  clone на голям repo, Python с C extensions).
- `git` в браузъра: `isomorphic-git` (чист JS git, работи над `fs`
  abstraction, включително `LightningFS`/IndexedDB) — покрива clone/
  status/commit/push по HTTPS с token, без нужда от нативен код.
- `sshc` в браузъра: SSH през WebSocket е невъзможно директно от чист
  клиент (browser TCP restrictions) — реалистично само през relay/
  gateway сървър, отделна инфраструктурна задача, не просто библиотека.
- Python в браузъра: Pyodide (CPython компилиран за WASM) — по-лесно от
  нативния iOS path, защото няма sandbox ограничение за pip wheels.

Track B е самостоятелен проект (различен tech stack), не блокира и не
се блокира от Track A. Ще го адресираме explicitно, когато Track A
опре в нещо, което наистина изисква Mac/Xcode стъпка, която не можем
да automate-нем оттук (signing, App Store submission) — дотогава A е
приоритет, по изричното решение "opitvame purvo kakto byahme trygnali".

---

Ред на изпълнение в тази сесия: **3 → 4 → 5**, после преоценка на 7 vs 9
спрямо колко CI бюджет/време е останало.
