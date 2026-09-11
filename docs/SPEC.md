# BookTrans — iOS-читалка FB2/EPUB с переводом EN→RU через web-сессию Gemini

Slug: `booktrans-ios-reader`

## 1. Контекст

iPhone 16, iOS 26.5, аккаунт в РФ, платного Apple Developer ($99/год) нет. Нужно приложение-читалка (FB2 + EPUB), которое:

- импортирует книгу, режет её на батчи ≈5 % объёма и последовательно переводит EN→RU, сохраняя результат по мере готовности батчей;
- даёт читать уже переведённую часть, пока переводится остальное; показывает оригинал по переключателю;
- ведёт глоссарий терминов, который подставляется в каждый промпт (единообразие терминологии), и позволяет править термины вручную с пере-переводом затронутых батчей;
- использует лимиты подписки Google через web-сессию `gemini.google.com` (никаких API-ключей). Риски приняты: это нарушение ToS, возможны ограничение/блокировка аккаунта и поломка неофициального протокола;
- собирается с Windows 11 и живёт на устройстве на free Apple ID с пере-подписью раз в 7 дней.

Только тёмная тема. Языковая пара фиксирована: английский → русский. Про «Gemini 3.8 flash»: такого имени не существует; в UI будет выбор из списка моделей, который реально отдаёт аккаунт, по умолчанию — Flash-вариант тира аккаунта.

## 2. Зафиксированные решения

| Область | Решение |
|---|---|
| UI | SwiftUI, deployment target **iOS 26.0**, `UIUserInterfaceStyle = Dark`, портрет |
| Проект | **XcodeGen** (`project.yml`), `.xcodeproj` в git не хранится |
| Ядро | SPM-пакет `Packages/BookTransCore`, только Foundation, собирается и тестируется на Linux в WSL |
| Сборка | GitHub Actions, `runs-on: macos-26` (Xcode 26.6, iOS SDK 26.5, симулятор «iPhone 17 / iOS 26.5»), **публичный** репозиторий → macOS-минуты бесплатны |
| Артефакт | unsigned `BookTrans.ipa` → artifact GitHub Actions → скачивается на Windows |
| Установка/подпись | **iloader** (Windows) ставит IPA и SideStore; **SideStore** (on-device, через StosVPN/LocalDevVPN) пере-подписывает приложения каждые ~7 дней без ПК |
| Ограничения free Apple ID | 3 приложения на устройстве, 10 App ID в неделю, сертификат 7 дней |
| AI-транспорт | Web-сессия `gemini.google.com` через скрытый `WKWebView` + `fetch` внутри страницы; API-ключи не используются |
| Форматы | FB2 (XML, включая windows-1251), EPUB 2/3 (ZIP + OPF + spine) |
| Ридер | Вертикальный скролл, тёмная тема, блоки-абзацы со стабильными id |
| Батчи | ≈5 % книги, выравнивание по границам глав, сплит слишком длинных блоков |
| Глоссарий | видимый и редактируемый; lookahead-извлечение терминов перед переводом каждого батча |
| Идентичность | display name **BookTrans**, bundle id **com.gennadiy.booktrans** |
| Прозрачность | Сеть наружу — только `gemini.google.com` / `accounts.google.com` (плюс скачивание не требуется ничего) |

## 3. Риски и что из них следует в коде

**R1. Неофициальный протокол ломается.** Все параметры (endpoints, rpcid, model header, ключи WIZ) живут в `Resources/gemini-web.json`; файл можно переопределить, положив свой в `Documents/Config/gemini-web.json` (без пересборки приложения). Есть Debug-экран с сырыми запросами/ответами и процедура пере-захвата `docs/GEMINI-CAPTURE.md`.

**R2. Лимиты и блокировки аккаунта.** Классификация ошибок: `1037` usage limit, `1060` IP/регион, `1013` временная, `1052/1050` неверный model header, reject code `7` в batchexecute = не авторизован. Состояние очереди переходит в `waitingQuota` / `waitingAuth` с сообщением в UI. Тир и остаток лимитов показываются из RPC `jSf9Qc`.

**R3. Перевод идёт только пока приложение активно.** iOS усыпляет приложение; BGTask для WKWebView-перевода не используем. Отсюда: детерминированный resume из `state.json`, пауза на `scenePhase != .active` после завершения текущего запроса, опция «не гасить экран во время перевода» (`isIdleTimerDisabled`, по умолчанию включена).

**R4. Локально нет macOS.** Обратная связь по iOS-коду — только CI. Поэтому логика, которую можно проверить без iOS (парсеры, чанкер, промпты, разбор ответа, глоссарий, схема файлов), выносится в `BookTransCore` и проверяется `swift test` в WSL; CI гоняется на каждый push.

**R5. РФ.** `gemini.google.com` требует VPN на устройстве; при ошибке 1060 показываем «Gemini недоступен — включите VPN».

## 4. Шаг 0 — предполётная проверка (выполнить до написания кода)

Каждый пункт: подтвердить фактом, при ином результате — действие в скобках.

1. GitHub: аккаунт есть, `gh auth status` проходит (`gh auth login`, scope `repo`). [Иначе — создать PAT и использовать `https://<token>@github.com/...`.]
2. Репозиторий: `gh repo create booktrans --public --source . --remote origin` в текущей папке (папка = корень репо, `git init` при необходимости).
3. WSL: `swift --version`. [Если нет — поставить Swift 6.x для Ubuntu по инструкции swift.org в `~/swift`; если установка невозможна — Core проверяется только в CI (`swift test --package-path Packages/BookTransCore` на macOS-раннере).]
4. iPhone: iOS 26.5, включён режим разработчика (Настройки → Конфиденциальность и безопасность → Режим разработчика; включается при первой установке сайдлоада).
5. Windows: iTunes **с сайта Apple** (не из Microsoft Store) установлен — он даёт usbmuxd-драйверы; `iloader` (github.com/nab138/iloader/releases, Windows-сборка) скачан.
6. App Store: приложение-туннель (LocalDevVPN `id6755608044` либо StosVPN `id6744003051` — актуальный указан в docs.sidestore.io/docs/installation/prerequisites) доступно аккаунту. [Если в РФ-сторе недоступно — создать второй Apple ID с регионом, где доступно, и ставить сайдлоад этим аккаунтом.]
7. iPhone: `gemini.google.com` открывается в Safari и логин проходит (при необходимости — VPN включён).
8. Проверить актуальность ссылок: docs.sidestore.io (prereq/install), github.com/actions/runner-images (образ `macos-26`).

## 5. Структура репозитория

```
project.yml                       # XcodeGen: app target BookTrans + unit tests
.github/workflows/ios.yml         # swift test (Core) + xcodebuild test + сборка IPA + artifact
Packages/BookTransCore/
  Package.swift                   # platforms: [.macOS(.v13), .iOS(.v16)]; зависимости: ZIPFoundation
  Sources/BookTransCore/
    Model/BookModels.swift        # BookMeta, Chapter, Block, Unit, BatchPlan, BatchResult, GlossaryTerm
    Store/FileStore.swift         # атомарная запись JSON (write→.tmp→rename), чтение, пустые/битые файлы
    Store/LibraryStore.swift      # library.json
    Store/BookStore.swift         # Books/{id}/…: meta, chapters, plan, batches, glossary, state, progress
    Import/EncodingDetect.swift   # определение кодировки из XML-пролога + карта имён кодировок
    Import/FB2Parser.swift        # XMLParser → Chapter/Block + binary-изображения
    Import/EPUBUnpacker.swift     # ZIPFoundation: unzip в каталог
    Import/EPUBParser.swift       # container.xml → OPF → metadata/manifest/spine/nav
    Import/HTMLBlockExtractor.swift # XHTML → [Block] (детерминированный, токенизатор)
    Plan/Chunker.swift            # units + батчи ≈5 %
    Plan/PromptBuilder.swift      # тексты промптов + блок глоссария + усечение
    Plan/ResponseParser.swift     # разбор ответа модели (JSON-лестница)
    Plan/GlossaryStore.swift      # merge-правила, поиск затронутых батчей
    Net/GeminiProtocol.swift      # литералы: endpoints, rpcid, индексы payload, model header
    Net/GeminiResponse.swift      # разбор batchexecute и StreamGenerate (фреймы, тексты, коды ошибок)
  Tests/BookTransCoreTests/       # fixtures + тесты (см. §10)
App/
  BookTransApp.swift, AppState.swift
  Library/LibraryView.swift, BookCardView.swift, ImportCoordinator.swift
  Book/BookView.swift, BatchListView.swift, GlossaryView.swift
  Reader/ReaderView.swift, ReaderHTMLBuilder.swift, ReaderWebView.swift, ReaderTheme.swift
  Translation/GeminiWebTransport.swift   # WKWebView + JS-мост
  Translation/GeminiSession.swift        # логин, WIZ-параметры, cookies-статус
  Translation/TranslationQueue.swift     # состояние, ретраи, пауза/резюм
  Settings/SettingsView.swift, UsageView.swift
  Debug/DebugView.swift, LogStore.swift
  Resources/gemini-web.json, Assets.xcassets
docs/SPEC.md                      # этот план целиком (шаг 7)
docs/SIGNING.md                   # установка/refresh на Windows+iOS (шаг 7)
docs/GEMINI-CAPTURE.md            # пере-захват параметров протокола (шаг 7)
```

Зависимости: `ZIPFoundation` (MIT, SPM, поддержка Linux) — единственная внешняя. Ничего другого не добавлять.

## 6. Данные на устройстве

Всё в песочнице приложения (`Documents/`), включены `UIFileSharingEnabled` и `LSSupportsOpeningDocumentsInPlace` — папку видно в Files.

```
Documents/
  library.json
  Books/{bookId}/
    book.json            # мета + счётчики
    original.fb2|.epub
    parsed/chapters.json # блоки (единственный источник текста для перевода)
    parsed/images/*.jpg  # обложка, картинки (FB2 base64 → файл, EPUB — копии)
    reader.html          # генерируется перед каждой отрисовкой главы
    translation/plan.json
    translation/batches/000.json …
    translation/glossary.json
    translation/state.json
    progress.json
  Config/gemini-web.json # опциональный оверрайд (если есть — заменяет bundled)
  Logs/gemini.log        # JSONL, без at-токена и значений cookies
```

Схемы (ключи обязательны, порядок не важен):

```json
// book.json
{"id":"<uuid>","title":"…","author":"…","format":"fb2|epub","sourceLang":"en","targetLang":"ru",
 "charCount":412345,"chapterCount":24,"batchCount":20,"coverPath":"parsed/images/cover.jpg",
 "createdAt":"2026-09-11T10:00:00Z","schemaVersion":1}

// parsed/chapters.json  — массив глав
[{"index":0,"title":"Chapter 1","docHref":"OEBPS/ch1.xhtml","blocks":[
  {"id":0,"kind":"heading|paragraph|listItem|blockquote|note|table|image|hr",
   "text":"плоский текст (для перевода)","html":"inline-HTML (для отрисовки оригинала)",
   "rawHTML":"<table>…</table> (только для kind=table)","imageRef":"images/abc.jpg"}]}]

// translation/plan.json  (units — то, что реально уходит в модель; 1 unit = 1 строка ответа)
{"target":14000,"totalChars":412345,
 "batches":[{"index":0,"chars":13810,"status":"pending|running|done|failed",
   "attempts":0,"error":null,"finishedAt":null,
   "units":[{"block":0,"part":0,"text":"…"},{"block":37,"part":0,"text":"…"}]}]}

// translation/batches/000.json
{"index":0,"createdAt":"…","modelId":"56fdd199312815e2",
 "translations":["…","…"],           // ровно столько же строк, сколько units
 "glossaryAdditions":[{"term":"ROI","translation":"рентабельность инвестиций (ROI)","note":""}],
 "rawChars":15320}

// translation/glossary.json
{"version":1,"terms":[{"key":"roi","term":"ROI","translation":"рентабельность инвестиций (ROI)",
  "note":"","kind":"term|abbr|name","source":"auto|user","count":7,"firstBlock":120,
  "updatedAt":"…"}]}

// translation/state.json
{"status":"idle|running|paused|waitingQuota|waitingAuth|failed","bookId":"<uuid>",
 "currentBatch":3,"message":null,"updatedAt":"…"}

// progress.json
{"chapterIndex":4,"blockId":812,"dy":240,"updatedAt":"…"}

// library.json — массив
[{"id":"<uuid>","title":"…","author":"…","coverPath":"…","batchesDone":7,"batchesTotal":20,
  "status":"running","lastOpenedAt":"…"}]
```

Правила: запись любого JSON — через `FileStore.writeAtomic` (tmp + `rename`); отсутствующий/битый файл трактуется как «пусто» и пересоздаётся, ошибка пишется в лог, но импорт/чтение не падают.

Кука и токен Gemini **не дублируются в файлы** — они живут только в `WKWebsiteDataStore.default()` (логин-сессия WebView), что заодно снимает вопрос хранения секретов.

## 7. Протокол Gemini — точные литералы

Всё ниже проверено по работающей обратной реализации (HanaokaYuzu/Gemini-API, AGPL — **код не копировать**, используем только факты о протоколе) и упаковывается в `gemini-web.json`:

```json
{"init":"https://gemini.google.com/app",
 "generate":"https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate",
 "batchexecute":"https://gemini.google.com/_/BardChatUi/data/batchexecute",
 "rotateCookies":"https://accounts.google.com/RotateCookies",
 "rpc":{"status":"otAQ7b","usage":"jSf9Qc","quota":"qpEbW"},
 "wizKeys":{"at":"SNlM0e","build":"cfb2h","session":"FdrFJe","lang":"TuX5cc"},
 "models":[
   {"id":"56fdd199312815e2","label":"Flash (подписка)","capacity":4,"number":1},
   {"id":"e6fa609c3fa255c0","label":"Pro (подписка)","capacity":4,"number":3},
   {"id":"8c46e95b1a07cecc","label":"Flash Lite (подписка)","capacity":4,"number":6},
   {"id":"fbb127bbb056c959","label":"Flash (free)","capacity":1,"number":1}],
 "defaultModel":"56fdd199312815e2",
 "prompts":{"version":1}}
```

`capacity`/`number`/`id` могут устареть — источником истины является список, полученный RPC `status` (см. ниже); пресеты нужны как стартовые и как ручной оверрайд.

### 7.1 Инициализация сессии

`GET https://gemini.google.com/app` внутри WKWebView. Из `window.WIZ_global_data` (или из HTML регулярками `"SNlM0e":"…"`, `"cfb2h":"…"`, `"FdrFJe":"…"`, `"TuX5cc":"…"`) берём `at`, `bl`, `f.sid`, `hl`. Нет `SNlM0e` → состояние «требуется вход», показываем WebView для логина.

Параметры запроса: `hl=ru`, `_reqid` (стартовое случайное 10000…99999, каждый следующий запрос **+100000**), `rt=c`, `bl`, `f.sid`.
`source-path` для batchexecute: `/app` (статус/модели) либо `/usage` (лимиты).
Перед отправкой счётчика `_reqid` берётся текущее значение, счётчик увеличивается на 100000.

### 7.2 Генерация (`StreamGenerate`)

Заголовки:
```
Content-Type: application/x-www-form-urlencoded;charset=utf-8
Origin: https://gemini.google.com      Referer: https://gemini.google.com/
X-Same-Domain: 1
x-goog-ext-525001261-jspb: [1,null,null,null,"<modelId>",null,null,0,[4,5,6,8],null,null,<capacity>,null,null,<number>,1,"<SESSION_UUID>"]
x-goog-ext-525005358-jspb: ["<SESSION_UUID>",1]
x-goog-ext-73010989-jspb: [0]
x-goog-ext-73010990-jspb: [0,0,0]
```
`SESSION_UUID` — `crypto.randomUUID().toUpperCase()`, один на запрос, он же кладётся в payload в индекс 59.

Тело (form-urlencoded):
```
at=<at>&f.req=<urlencode(JSON.stringify([null, JSON.stringify(inner)]))>
```
`inner` — массив ровно из 81 элемента, всё не перечисленное = `null`:
```
[0]  = [<prompt>, 0, null, null, null, null, 0]
[1]  = ["ru"]
[2]  = ["","","",null,null,null,null,null,null,""]
[6]  = [1]
[7]  = 1            // streaming
[10] = 1
[11] = 0
[17] = [[0]]
[18] = 0
[27] = 1
[30] = [4]
[41] = [1]
[53] = 0
[59] = "<SESSION_UUID>"
[61] = []
[68] = 1
[79] = <number>     // из model header
[80] = 1            // 1 = без extended thinking (нужно для скорости)
```

Промпт — одна пользовательская реплика, новой беседы (никаких продолжений: каждый запрос — свежий чат, `[2]` = пустые метаданные).

### 7.3 batchexecute (статус/модели, лимиты)

```
POST https://gemini.google.com/_/BardChatUi/data/batchexecute
   ?rpcids=<id>&source-path=< /app | /usage >&hl=ru&_reqid=<int>&rt=c&bl=<bl>&f.sid=<f.sid>
заголовки: те же + x-goog-ext-525001261-jspb: [1,null,null,null,null,null,null,null,[4,5,6,8],null,null,null,null,null,null,null,"<SESSION_UUID>"]
тело: at=<at>&f.req=<urlencode(JSON.stringify([[[" <rpcid> ", "<payload>", null, "generic"]]]))>
```
RPC:
- `otAQ7b`, payload `[]`, source-path `/app` — статус аккаунта и список моделей;
- `jSf9Qc`, payload `[]`, source-path `/usage` — тир и расход лимитов (5-часовое и недельное окно);
- `qpEbW`, payload `[[[1,11],[2,11],[6,11]]]` (Flash) и `[[[1,4],[6,6],[1,15]]]` (Pro) — счётчики лимитов.

### 7.4 Разбор ответов

- Тело начинается с `)]}'` — отбросить.
- Дальше фреймы: `<длина>\n<JSON>\n`, где длина — **в единицах UTF-16** (в JS это `String.length`, поэтому парсер держим в JS).
- Каждый фрейм — массив частей. Часть: `part[1]` = rpcid, `part[2]` = JSON-строка полезной нагрузки, `part[5][0] == 7` → запрос отклонён (нет авторизации).
- `batchexecute`: `body = JSON.parse(part[2])`; `otAQ7b` → `body[14]` = код статуса (1000 — ok, 1016 — не авторизован, 1060 — регион), `body[15]` = список моделей, `body[16]`/`body[17]` = tier/capability флаги для вычисления `capacity` (поле capacity читается из модели, по умолчанию 12); `jSf9Qc` → тир (1 FREE / 2 PRO / 3 ULTRA / 4 PLUS) и доли использования окон.
- `StreamGenerate`: `body = JSON.parse(part[2])`; `body[1]` = `[cid, rid]`; кандидаты — `body[4]`; **текст = последний кандидат последнего фрейма: `candidate[1][0]`**; `candidate[37][0][0]` = рассуждения (нам не нужны, но логируем факт наличия).
- Коды ошибок: `part[5][2][0][1][0]` ∈ {1013 временная, 1037 лимит исчерпан, 1050 модель не соответствует чату, 1052 неверный model header, 1060 IP/регион заблокированы}; неизвестный код — в лог и `failed` с текстом.
- Формат ответа модели (JSON-объект из §8.4) разбирается уже в Swift.

### 7.5 Поддержание сессии

После каждого успешного запроса проверяем возраст cookie `__Secure-1PSIDTS`: если старше 20 минут — `POST https://accounts.google.com/RotateCookies` с `Content-Type: application/json`, `Origin: https://accounts.google.com`, телом `[000,"-0000000000000000000"]`, из `fetch` внутри страницы (так куки ставит сам WebKit). Раз в 15 минут при активном переводе делаем `location.reload()`-эквивалент: повторный `GET /app` в том же WKWebView и обновление `at`/`bl`/`f.sid`.

### 7.6 Транспорт в приложении

`GeminiWebTransport` держит один `WKWebView` (конфигурация `.default()`, JS включён) в 1×1-контейнере в корне UI-иерархии. Все сетевые вызовы — `evaluateJavaScript`/`callAsyncJavaScript` с `fetch(...)` из контекста страницы `gemini.google.com` (same-origin → нет CORS/preflight, куки и ротация — забота WebKit, TLS-отпечаток совпадает с браузером).

JS-функция приёма (эскиз, полные литералы — из §7.2):
```js
async function btGenerate(prompt, modelHeader, at, bl, sid, reqid, uuid) {
  const inner = new Array(81).fill(null);
  inner[0] = [prompt, 0, null, null, null, null, 0];
  inner[1] = ["ru"]; inner[2] = ["","","",null,null,null,null,null,null,""];
  inner[6] = [1]; inner[7] = 1; inner[10] = 1; inner[11] = 0; inner[17] = [[0]];
  inner[18] = 0; inner[27] = 1; inner[30] = [4]; inner[41] = [1]; inner[53] = 0;
  inner[59] = uuid; inner[61] = []; inner[68] = 1; inner[79] = modelHeader.number; inner[80] = 1;
  const url = "/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate"
    + `?hl=ru&_reqid=${reqid}&rt=c&bl=${encodeURIComponent(bl)}&f.sid=${encodeURIComponent(sid)}`;
  const body = new URLSearchParams({ at, "f.req": JSON.stringify([null, JSON.stringify(inner)]) });
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), BT_TIMEOUT_MS);
  try {
    const r = await fetch(url, { method: "POST", credentials: "include", signal: ctrl.signal,
      headers: { "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
        "X-Same-Domain": "1", "x-goog-ext-525001261-jspb": JSON.stringify(modelHeader.jp),
        "x-goog-ext-525005358-jspb": JSON.stringify([uuid, 1]),
        "x-goog-ext-73010989-jspb": "[0]", "x-goog-ext-73010990-jspb": "[0,0,0]" },
      body });
    const raw = await r.text();
    return { status: r.status, text: btExtractText(raw), error: btExtractError(raw), rawLen: raw.length };
  } finally { clearTimeout(t); }
}
```
Как парсер фреймов, так и сборка ответа живут в JS (см. §7.4); в Swift уходит `{status, text, errorCode, rawLen}` плюс при ошибке — первые 4 КБ сырого ответа в лог. Таймаут запроса — 180 с.

**Запасной вариант, если `fetch` из страницы не сработает** (CSP, блокировка, редирект на логин): читать куки через `WKWebsiteDataStore.httpCookieStore.getAllCookies()`, собирать `Cookie`-заголовок и делать запросы через `URLSession` с `User-Agent`, совпадающим с WebView, и `RotateCookies` тем же способом. Решение о переключении принимается в шаге 2 по факту.

## 8. Алгоритмы

### 8.1 Импорт FB2

1. Прочитать файл как `Data`; кодировка — из пролога `<?xml … encoding="…"?>` (regexp по первым 200 байтам, ASCII-safe). Карта имён: `utf-8`, `windows-1251`, `koi8-r`, `iso-8859-1`, `iso-8859-5`, `windows-1252`, `utf-16`, `utf-16le`, `utf-16be`; неизвестное имя → `utf-8`; битые байты → `windows-1251` (второй проход). Реализация через `String.Encoding(rawValue:)` со статической картой (на Linux `CFString…` недоступен).
2. Разбор `XMLParser` (в Core через `#if canImport(FoundationXML) import FoundationXML #endif`), потоково, в две структуры: `description` (book-title, first/last-name, lang, coverpage) и `body`.
3. Главы: каждый `<section>` верхнего уровня в `<body>` — глава; `<title>` первого уровня внутри — заголовок главы и блок `heading`; вложенные `<section>` не создают глав, их `<title>` — блоки `heading` внутри родительской главы. `<body name="notes">` → отдельная глава «Примечания» в конце.
4. Блоки: `p`, `subtitle`, `v`(стих), `cite`, `td/th` (внутри `table` → один блок `table` с `rawHTML` и **без перевода**), `empty-line` → пропуск. `image` → блок `image`; `a type="note"` → инлайновая ссылка, остаётся в `html`.
5. `text` блока — плоский текст с декодированными сущностями и схлопнутыми пробелами; `html` — инлайновая разметка (`emphasis`→`<em>`, `strong`→`<strong>`, `strikethrough`→`<s>`, `code`→`<code>`, `sup`/`sub`, `a`→`<a>`), с экранированием `<`, `>`, `&`.
6. `<binary id="…" content-type="image/…">BASE64</binary>` → Core возвращает словарь `id → (contentType, base64)`; приложение декодирует, при стороне > 1600 px уменьшает (ImageIO) и пишет JPEG в `parsed/images/{id}.jpg`; `imageRef` в блоках указывает на этот файл. Пропавшая по ссылке картинка → блок `image` без `imageRef` (рендерится как пропуск), в лог строка `missing image <id>`.
7. Книга без `<body>`/глав → один раздел `Без названия`; ошибка парсинга XML → импорт отклоняется с сообщением (файл не удаляем), в лог — позиция ошибки.

### 8.2 Импорт EPUB

1. Unzip в `Books/{id}/epub/` (ZIPFoundation). Обязателен `META-INF/container.xml`; нет — ошибка импорта.
2. `rootfile@full-path` → OPF. Из OPF: `dc:title`, `dc:creator`, `dc:language`, `meta[name=cover]`, `manifest`, `spine`. Регистр тегов не важен, пространства имён игнорируются (сравнение по локальному имени).
3. Главы: элементы `spine/itemref` по порядку → `manifest@href`, путь относительно каталога OPF. Заголовки — из EPUB3 `nav` (`properties="nav"`) или `toc.ncx`; сопоставление по пути без фрагмента. Нет оглавления → заголовок = первый `h1/h2` документа, иначе `Глава N`.
4. Каждый XHTML → `[Block]` через `HTMLBlockExtractor`:
   - режем по блочным тегам: `p, div, h1..h6, li, blockquote, dd, dt, pre, figcaption, section, article, aside, header, footer, td, th, figure`;
   - текст на нулевом уровне (прямо в `body`) — отдельный блок `paragraph`;
   - `img` → блок `image` (`imageRef` — копия файла в `parsed/images/`, имя = sha1 относительного пути + расширение); файл отсутствует → блок пропускается с записью в лог;
   - `table` → блок `table` с `rawHTML` (содержимое захватывается с учётом вложенности), не переводится;
   - `hr` → блок `hr` (не переводится, не учитывается в объёме);
   - `<script>`/`<style>`/`<head>` отбрасываются целиком;
   - сущности декодируются (`&amp; &lt; &gt; &quot; &#39; &nbsp;` + числовые), `text` — плоский текст, `html` — инлайновая разметка (`em,i,strong,b,s,del,code,sup,sub,a`).
5. Обложка: из `meta[name=cover]` → копия в `parsed/images/cover.jpg`; нет — первая картинка книги; нет — плейсхолдер не создаём (в UI — серый прямоугольник).
6. Документ, который не парсится как XHTML, обрабатывается тем же токенизатором как обычный текст (токенизатор не требует валидного XML).

### 8.3 План батчей (≈5 % книги)

Порядок вычислений строго такой:

1. `totalChars` = сумма длин `text` всех блоков с `kind ∈ {heading, paragraph, listItem, blockquote, note}` (то есть всё, кроме `image`, `hr`, `table`) по всей книге.
2. `target = clamp(Int(0.05 * totalChars), 4000, 14000)`.
3. Units: для каждого транслируемого блока с непустым текстом:
   - `text.count <= 1.5 * target` → один unit `{block, part: 0, text}`;
   - иначе режем по границам предложений на куски `<= target` (если отдельное предложение длиннее `target` — по границам слов) → units `{block, part: 0..k}`.
4. Батчи (обход глав по порядку, внутри главы — по units):
   - добавляем unit в текущий батч, накапливаем `chars`;
   - если `chars >= target` → закрываем батч (правило A: держим ~5 %);
   - на границе главы: если `chars >= 0.75 * target` → закрываем батч (правило B), иначе батч продолжается следующей главой;
   - в конце — закрываем остаток.
5. `plan.json` пишется атомарно целиком (units включены), `book.json.batchCount` обновляется.

Инварианты (проверяются тестами): каждый unit ровно в одном батче; порядок units = порядок блоков; ни один батч, кроме последнего, не короче `0.75 * target`; батчи не пересекают границу главы, если глава целиком влезает в `target`.

Рендер частичного блока: блок считается переведённым, только если переведены **все** его units; иначе блок показывается оригиналом. Полностью переведённый блок собирается как `units.joined(separator: " ")` (parts в порядке `part`).

### 8.4 Промпты

Перевод батча — один запрос, текст (строки `\n`):

```
[ИНСТРУКЦИЯ]
Ты профессиональный переводчик деловой и нон-фикшн литературы. Переводишь с английского на русский.

Правила:
1. Переводи смысл, а не слова; предложения должны звучать естественно по-русски.
2. Термины, аббревиатуры, названия методологий переводи строго так, как указано в ГЛОССАРИИ ниже. Если термин есть в глоссарии — используй ровно его перевод, без синонимов.
3. Собственные имена, названия компаний и продуктов не переводи; при первом упоминании можно оставить оригинал в скобках.
4. Числа, даты, единицы измерения, ссылки и обозначения сохраняй без изменений.
5. Сохраняй разметку внутри блока: **жирный**, *курсив*, `код`, HTML-теги.
6. Не добавляй пояснений, заголовков, вступлений, комментариев, маркеров «Перевод:».
7. Регистр деловой, без обращения «ты».

[ГЛОССАРИЙ]
<term> → <translation>
…по одной паре на строку ("" → пустой раздел)…

[ЗАДАЧА]
Переведи N блоков ниже. Верни ровно один JSON-объект, без markdown-обрамления и без текста вокруг:
{"translations": ["<перевод блока 1>", "<перевод блока 2>", …], "glossary": [{"term": "<термин>", "translation": "<перевод>", "note": "<необязательно>"}]}

Требования:
- В translations ровно N строк, порядок совпадает с порядком входных блоков.
- Перенос строки внутри блока экранируй как \n, кавычки — как \".
- Пустой блок переводи как пустую строку.
- glossary: только новые термины, аббревиатуры, названия методологий и устойчивые словосочетания из этих блоков, которых нет в глоссарии выше; максимум 15 записей; если новых нет — [].

[БЛОКИ]
["<блок 1>", "<блок 2>", …]
```

Извлечение терминов (lookahead, выполняется перед переводом батча, если для него ещё нет терминов):

```
[ИНСТРУКЦИЯ]
Ты терминологический редактор деловой литературы. Из фрагмента книги ниже выдели термины, аббревиатуры, названия методологий, метрик и устойчивых словосочетаний, для которых важно единообразие перевода на русский.

[ЗАДАЧА]
Верни ровно один JSON-объект, без markdown-обрамления:
{"glossary": [{"term": "<термин>", "translation": "<рекомендуемый перевод>", "note": "<необязательно>"}]}

Требования:
- 10–25 записей, отсортированных по важности.
- Только значимые для деловой литературы термины; бытовые слова не включай.
- Перевод — в той форме, в которой он должен стоять в тексте.

[ФРАГМЕНТ]
<текст units батча, разделитель "\n\n">
```

Усечение глоссария: если текст блока `[ГЛОССАРИЙ]` > 20 000 символов — включаем только термины, встречающиеся в units текущего батча или предыдущего, отсортированные по `count` убыв., максимум 800.

Retry-добавка при неразобранном ответе (одна попытка):
`\n\n[ВАЖНО]\nВерни ТОЛЬКО корректный JSON без комментариев, без markdown, без переносов строк вне строковых значений.`

### 8.5 Разбор ответа модели

`ResponseParser.parse(raw, expectedCount) -> Result{translations, glossary}`:

1. Обрезать пробелы; снять ограждение ```` ```json … ``` ````.
2. Найти первый `{` и последний `}` → декодировать объект `{translations:[String], glossary:[{term,translation,note}]}`; проверить `translations.count == expectedCount` → успех.
3. Иначе: найти первый `[` и парный `]` (сканирование с учётом строк и экранирования) → декодировать `[String]` при совпадении количества → успех, глоссарий не обновляется.
4. Иначе — ошибка: одна повторная попытка с retry-добавкой; если снова ошибка — батч `failed`, `error = "unparsable response"`, сырой ответ (первые 8 КБ) в `Logs/gemini.log`.

### 8.6 Глоссарий

- Ключ записи — `term.lowercased()`; при merge запись с `source == "user"` **никогда** не перезаписывается автоматикой; при коллизии авто-записей новая добавляется только если `key` отсутствует, иначе увеличивается `count` и обновляется `updatedAt`.
- Порядок: lookahead-извлечение → merge → перевод с полным глоссарием → merge `glossaryAdditions` из ответа перевода.
- Правка термина пользователем: запись помечается `source="user"`; затем `GlossaryStore.affectedBatches(term)` ищет слово (без учёта регистра, по границе слова) в `units[].text` всех батчей и возвращает их индексы. UI предлагает «Перевести заново батчи: 3, 7, 12» — по нажатию эти батчи сбрасываются в `pending`, их `batch/*.json` удаляются, глоссарий не трогается.
- Удаление термина — только пользователем; авто-merge удалять не умеет.

### 8.7 Отрисовка и JS-мост

`ReaderHTMLBuilder` собирает `reader.html` для главы:
```
<html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>:root{--fs:19px;--lh:1.55;--mx:20px}
html,body{background:#111214;color:#e9e7e3;margin:0;padding:0}
article{max-width:780px;margin:0 auto;padding:24px var(--mx) 96px;font:var(--fs)/var(--lh) ui-serif,"New York",Georgia,serif}
h1,h2,h3{font-family:-apple-system,sans-serif;line-height:1.25;margin:1.6em 0 .6em}
p,.b{margin:0 0 1em}
.b[data-kind="blockquote"]{margin:1em 0;padding-left:14px;border-left:3px solid #3a3d42;color:#c9c6c0}
.b[data-kind="image"] img{max-width:100%;height:auto;border-radius:6px}
.untranslated{border-top:1px dashed #3a3d42;margin:28px 0 16px;padding-top:10px;color:#8b8f96;font-size:.8em;font-family:-apple-system,sans-serif}
</style></head><body><article id="book">{blocks}</article><script>{js}</script></body></html>
```
Блок → `<div class="b" id="b{id}" data-kind="{kind}">{content}</div>`; в режиме «перевод» для неполностью переведённых блоков контент — оригинал, а перед первым непереведённым блоком каждого непрерывного участка вставляется `<div class="untranslated">далее — оригинал</div>`; `table` рендерится `rawHTML` в обоих режимах; `image` — `<img src="{imageRef}">`.

Загрузка: `loadFileURL(Books/{id}/reader.html, allowingReadAccessTo: Books/{id})` (картинки — относительными путями `parsed/images/…`).

JS-мост (инжектится в `reader.html`):
```js
window.Reader = {
  position() {                                  // {block, dy, progress}
    const bs = document.querySelectorAll('.b');
    const y = window.scrollY;
    let cur = bs[0], dy = 0;
    for (const b of bs) {
      const top = b.getBoundingClientRect().top + window.scrollY;
      if (top <= y + 8) { cur = b; dy = Math.round(y - top); } else break;   // последний блок, начавшийся выше экрана
    }
    const max = document.documentElement.scrollHeight - window.innerHeight;
    return JSON.stringify({ block: Number(cur.id.slice(1)), dy,
                            progress: max > 0 ? Math.min(1, window.scrollY / max) : 0 });
  },
  restore(block, dy) { const el = document.getElementById('b' + block); if (el) window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY + dy); },
  style(fs, lh, mx) { document.documentElement.style.setProperty('--fs', fs + 'px');
                      document.documentElement.style.setProperty('--lh', lh);
                      document.documentElement.style.setProperty('--mx', mx + 'px'); }
};
```
Вызовы: `callAsyncJavaScript("return Reader.position()")`, `…("return Reader.restore(b, dy)", arguments: ["b": blockId, "dy": dy])`, `…("return Reader.style(fs, lh, mx)", …)`.

Перерисовка при готовности батча, затронувшего текущую главу: сохранить `position()` → перегенерировать HTML → `loadFileURL` → в `didFinish` вызвать `restore`. Позиция хранится в блоках, а не в пикселях, поэтому переходы не «прыгают».

Тумблер «Оригинал/Перевод» = перерисовка с другим режимом и восстановление позиции; значение хранится в `progress.json` вместе с позицией экрана (не в `book.json`).

### 8.8 Очередь перевода

`TranslationQueue` (единственный экземпляр, `@MainActor`):

- Состояния: `idle`, `running`, `paused`, `waitingAuth`, `waitingQuota`, `failed`.
- Одновременно: одна книга, один запрос в полёте.
- Шаг для батча: (1) если для батча нет записей глоссария — запрос извлечения терминов и merge; (2) запрос перевода; (3) запись `batches/NNN.json`, merge, `status = done`, обновление `state.json` и `library.json`; (4) уведомление UI.
- Ошибки: `attempts += 1`; задержки 15 с / 60 с / 300 с; после 3 попыток батч → `failed`, очередь идёт дальше (книга не блокируется); кнопка «перевести заново» сбрасывает `attempts`.
- `1037` (лимит) → `waitingQuota`: сообщение «Лимит Gemini исчерпан, продолжаем автоматически», повтор через 30 мин, пока приложение активно; при запуске — попытка сразу.
- reject code `7`, HTTP 401/403, отсутствие `SNlM0e` → `waitingAuth`: баннер «Нужно войти в Gemini» с кнопкой открытия логин-WebView.
- `1060` → `waitingQuota` с сообщением «Gemini недоступен: включите VPN».
- Пауза пользователем → после завершения текущего запроса; на `scenePhase != .active` — то же самое (новые запросы не стартуют).
- При старте приложения: прочитать `state.json`; если статус был `running` — продолжить с `currentBatch`, если батч уже `done` — со следующего.

## 9. Порядок работ

Шаги выполняются по порядку; после каждого дерево собирается (CI зелёный), приложение запускается на устройстве.

### Шаг 1. Репозиторий, CI, пустое приложение на телефоне (де-риск подписи)
- `project.yml`: target `BookTrans` (bundle id `com.gennadiy.booktrans`, `SWIFT_VERSION 5.0`, `TARGETED_DEVICE_FAMILY 1`, `UIUserInterfaceStyle Dark`, `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, портрет), `CFBundleDocumentTypes` + `UTImportedTypeDeclarations` для EPUB (`org.idpf.epub-container`) и FB2 (UTI `com.gennadiy.booktrans.fb2`, расширение `fb2`, conforms to `public.xml`); зависимость на локальный пакет `BookTransCore`; target тестов `BookTransTests`.
- `.github/workflows/ios.yml`: job `core` (`swift test --package-path Packages/BookTransCore`), job `ios` (`brew install xcodegen` → `xcodegen generate` → `xcodebuild test -project BookTrans.xcodeproj -scheme BookTrans -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' CODE_SIGNING_ALLOWED=NO` → `xcodebuild -project BookTrans.xcodeproj -scheme BookTrans -configuration Release -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` → `mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/BookTrans.app Payload/ && zip -qry BookTrans.ipa Payload` → `actions/upload-artifact@v4` с `name: BookTrans-ipa`, `retention-days: 14`). Триггеры: `push: main`, `workflow_dispatch`.
- Приложение: `BookTransApp.swift` + экран «Библиотека пуста» (только тёмная тема).
- Установка на телефон: iTunes → iloader → «Install SideStore» → на iPhone доверие профилю, «Режим разработчика», туннель (LocalDevVPN/StosVPN) → в SideStore вход и refresh → скачать IPA из Actions → `iloader` → Import IPA на подключённом телефоне. Зафиксировать результат в `docs/SIGNING.md`.
- Приёмка: IPA из CI запускается на iPhone; в Files видна папка BookTrans.

### Шаг 2. Gemini-транспорт и Debug-экран (главный технический риск — вперёд)
- `GeminiProtocol` (литералы §7), `GeminiResponse` (фреймы, тексты, коды), `GeminiSession` (WIZ-параметры, статус логина, `RotateCookies`), `GeminiWebTransport` (WKWebView + JS-мост), `LogStore`.
- `DebugView`: значения WIZ (маскированные), статус cookie (имена и возраст), тир и лимиты из `jSf9Qc`/`qpEbW`, список моделей из `otAQ7b`, кнопки «Перечитать параметры», «Тест: перевести 1 абзац», «Показать сырой ответ», «Скопировать лог».
- Приёмка на устройстве: логин проходит; тестовый абзац возвращает русский перевод; в Debug видны тир аккаунта и остаток лимитов; при выключенном VPN — понятная ошибка `1060`.
- Если `fetch` из страницы не работает (CSP/редирект), переключиться на схему с `URLSession` + cookies (§7.6) и записать это решение в `docs/SPEC.md`.

### Шаг 3. Ядро: парсеры, план батчей, промпты, разбор ответов (Linux-тесты)
- Всё из `Packages/BookTransCore` (§5) + тесты (§10).
- Приёмка: `swift test` в WSL зелёный; тесты покрывают FB2 (UTF-8 и windows-1251), EPUB (фикстура), инварианты чанкера, промпт-билдер, разбор ответа (5 видов), merge глоссария.

### Шаг 4. Библиотека, импорт, ридер (без Gemini — на моках)
- `LibraryView`, импорт через `.fileImporter` и `.onOpenURL`, `ImportCoordinator` (копирование оригинала, парсинг, запись `chapters.json`, картинок, плана, автостарт очереди).
- `ReaderView` + `ReaderHTMLBuilder` + `ReaderWebView` + тумблер «Оригинал/Перевод» + TOC + размер шрифта + сохранение/восстановление позиции.
- Мок-провайдер переводов (детерминированный, `[перевод] <текст>`), включается тумблером в Debug — чтобы проверять ридер без Gemini и без лимитов.
- Приёмка на устройстве: импорт реального FB2 и EPUB; чтение; переключение на оригинал; позиция восстанавливается после перезапуска; мок-перевод отображается поблочно.

### Шаг 5. Очередь перевода, глоссарий, прогресс
- `TranslationQueue` (§8.8), привязка к `GeminiWebTransport`, `GlossaryView` (список, поиск, правка, «перевести заново затронутые батчи»), `BatchListView` (статусы, ручной перезапуск), панель прогресса в `BookView`.
- Приёмка на устройстве: книга 1–2 МБ начинает переводиться; первые батчи читаются; глоссарий растёт; правка термина предлагает пере-перевод нужных батчей; перезапуск приложения продолжает перевод с текущего батча; исчерпание лимита показывает баннер и возобновляется автоматически.

### Шаг 6. Полировка
- `SettingsView` (вход/выход Gemini, модель + «обновить список», «не гасить экран», шрифт/интерлиньяж/поля, лимиты, размер данных), обработка ошибок во всех точках, лог-ротация (2 МБ), `scenePhase`-пауза, `isIdleTimerDisabled`.
- Приёмка: настройки сохраняются между запусками; смена модели применяется к следующим батчам; выход из аккаунта чистит `WKWebsiteDataStore` и переводит очередь в `waitingAuth`.

### Шаг 7. Документы и приёмочный прогон
- `docs/SPEC.md` (этот план целиком + зафиксированные по факту отклонения), `docs/SIGNING.md`, `docs/GEMINI-CAPTURE.md` (Chrome DevTools → Network → скопировать запрос StreamGenerate как cURL; выписать `bl`, `f.sid`, rpcid, model header, индексы payload; обновить `gemini-web.json` и положить его в `Documents/Config/`).
- Приёмочный прогон §10.3 целиком.

## 10. Верификация

### 10.1 Локально (WSL)
```
swift test --package-path Packages/BookTransCore
```
Проверки (все — на фикстурах в коде, без сети):
- FB2: UTF-8 и windows-1251 (байтовые литералы), главы/заголовки/блоки, `<binary>` → base64, `<empty-line>` не создаёт блок, экранирование `<>&` в `html`;
- EPUB: OPF/spine/nav на собранной в тесте папке, `HTMLBlockExtractor` на 6 фрагментах (вложенные `div`, `table`, `img`, `script`, inline-теги, сущности);
- Chunker: `target` из clamp, инварианты §8.3, сплит длинного блока по предложениям, сборка частичного блока;
- PromptBuilder: N блоков в JSON, отсутствие глоссария, усечение при >20 000 символов;
- ResponseParser: чистый JSON, ```-ограждение, текст вокруг JSON, только массив, мусор → ошибка;
- GlossaryStore: user-запись не перезаписывается, `count` инкрементится, `affectedBatches` находит батчи по границе слова.

### 10.2 CI
`gh run watch` после push: зелёные `core` и `ios`; артефакт `BookTrans-ipa` скачивается.

### 10.3 Чек-лист на устройстве (приёмка проекта)
1. IPA установлен через iloader; приложение открывается; тема тёмная.
2. Импорт FB2 (русский windows-1251) и EPUB (английский) — открываются, текст читается, обложки и картинки на месте.
3. Вход в Gemini, Debug показывает тир и остаток лимитов.
4. Запуск перевода: прогресс растёт батчами; после 2–3 батчей начало книги читается по-русски.
5. В середине перевода чтение не мешает переводу; подгрузка нового батча не сбрасывает позицию чтения.
6. Тумблер «Оригинал» показывает исходный текст на той же позиции; в режиме перевода непереведённый хвост помечен «далее — оригинал».
7. Глоссарий наполняется; правка термина предлагает пере-перевод затронутых батчей; после пере-перевода новый термин виден в тексте.
8. Kill + запуск приложения: перевод продолжается с текущего батча, позиция чтения сохранена.
9. Выключить VPN → понятная ошибка и автоматическое продолжение после включения.
10. Дождаться лимита (или эмулировать в Debug) → баннер «лимит исчерпан», повтор через 30 минут.
11. Через 7 дней без ручных действий: SideStore пере-подписал приложение (таймер в SideStore уменьшился), приложение запускается.

## 11. Допущения и запасные варианты

- **Список моделей.** `56fdd199312815e2` и прочие id из §7 могут устареть; истина — ответ `otAQ7b`. Если `otAQ7b` даёт пустой список, остаются пресеты из `gemini-web.json` + поле ручного model header в настройках.
- **ZIPFoundation в Linux.** Если `swift build` на Linux падает — unzip переносится в app-слой (`EPUBUnpacker` принимает уже распакованный каталог), тесты EPUB работают на каталоге-фикстуре. Парсинг OPF остаётся в Core.
- **`fetch` из WKWebView не работает.** Fallback: cookies из `WKWebsiteDataStore` + `URLSession` (§7.6).
- **Туннель в App Store недоступен для РФ-аккаунта.** Второй Apple ID с регионом, где LocalDevVPN/StosVPN доступны; сайдлоад идёт этим аккаунтом (3-приложечный лимит общий для устройства).
- **Сертификат истёк (>7 дней без refresh).** SideStore на устройстве обновляет приложение, пока сам SideStore жив; если истёк и он — подключить iPhone к ПК и повторить установку через iloader, данные приложения сохраняются (тот же bundle id).
- **Аккаунт Google ограничен.** Действие: пауза очереди, показ ошибки; для продолжения — сменить аккаунт в настройках или дождаться снятия ограничения; код при этом не меняется.
- **Батч не разбирается после 2 попыток.** Батч помечается `failed`, книга продолжает переводиться; ретрай — вручную кнопкой.

## 12. Ключевые файлы-опоры

| Файл | Почему важно |
|---|---|
| `Packages/BookTransCore/Sources/BookTransCore/Net/GeminiProtocol.swift` | Единственное место с литералами протокола; при поломке Gemini правится здесь (+ `gemini-web.json`) |
| `Packages/BookTransCore/Sources/BookTransCore/Plan/Chunker.swift` | Инварианты 5 %-батчей и частичных блоков — от него зависит корректность чтения во время перевода |
| `App/Translation/GeminiWebTransport.swift` | WKWebView-мост: логин, WIZ-параметры, `fetch` внутри страницы, таймауты |
| `App/Translation/TranslationQueue.swift` | Состояния, ретраи, пауза/резюм, устойчивость к закрытию приложения |
| `App/Reader/ReaderHTMLBuilder.swift` | Режимы «перевод/оригинал», вставка «далее — оригинал», стабильные id блоков для восстановления позиции |

---

## 13. Отклонения, зафиксированные по факту (обновляется по ходу работы)

Всё ниже — то, что отличается от текста выше, с причиной. Остальное выполнено
как написано.

### 13.1 Протокол Gemini

|Что|Как в плане|Как сделано|Почему|
|---|---|---|---|
|Сборка запросов|JS собирает `inner[81]`, заголовки и тело|Собирается в Swift (`GeminiRequestBuilder`), в JS остаётся только `fetch`|Позиционные массивы и заголовки становятся тестируемыми на Linux; в JS остаётся ровно то, что требует контекста страницы|
|Разбор ответа|§7.4: парсер фреймов в JS («длина — в единицах UTF-16, в JS это `String.length`»)|Парсер в Swift, длина считается через `String.utf16.count`|То же самое измерение (в Swift 6.3 это property есть всегда), но разбор покрыт `GeminiResponseTests`|
|`gemini-web.json`|`App/Resources/gemini-web.json`|`Packages/BookTransCore/Sources/BookTransCore/Resources/gemini-web.json`|Один источник истины: файл читается из Core и там же тестируется|
|Запасной конфиг|—|`GeminiConfig.lastResort` в Core + тест `testLastResortLiteralMatchesTheBundledResource`|Литерал нужен, если ресурс недоступен; тест не даёт ему разойтись с JSON|
|Список моделей|§7.4: `body[15]` — список моделей|Обход дерева: любой массив с 16-hex id считается записью модели; `label` берётся из RPC, `capacity`/`number` — из пресета|Точная форма `body[15]` не подтверждена ни одним захватом; позиционные поля нельзя угадать, а имя модели из RPC — то, что аккаунт реально использует|
|Дробные числа|—|`JSONValue` получил `case double` и `case object`|Без `.double` доли расхода лимитов и сырой ответ в Debug превращались в `null`; без `.object` — любой объектный payload|

### 13.2 Ядро и импорт

|Что|Как в плане|Как сделано|Почему|
|---|---|---|---|
|Разбор FB2|`XMLParser`|Собственный толерантный токенизатор (`MarkupTokenizer`)|Реальные FB2 постоянно не-well-formed (сырой `&`, незакрытые теги, windows-1251 под видом UTF-8); `XMLParser` отклоняет их целиком. Валидируется структура: файл без главы с переводимым текстом отклоняется как «не FB2»|
|Имя типа юнита|`Unit`|`PlanUnit`|`Unit` конфликтует с `Foundation.Unit`; в JSON имя не попадает, схема не изменилась|
|Связка план+результаты|не описана|`TranslationMap`|Правило «блок переведён, только если переведены все его части» живёт в одном месте и покрыто тестами|
|Схема `plan.json`|фиксированный набор ключей|добавлен `lookaheadDone: Bool` (по умолчанию `false`)|Без флага неудачное извлечение терминов стоило бы отдельного запроса при каждой повторной попытке батча|
|Схема `progress.json`|`chapterIndex`, `blockId`, `dy`|плюс `showTranslation`|§8.7 требует хранить тумблер там же, где позицию|
|Обложка EPUB|копия в `parsed/images/cover.jpg`|имя сохраняет исходное расширение (`cover.png`)|Расширение `.jpg` для PNG — ложь о формате; значение `coverPath` всё равно непрозрачно для UI|
|Уменьшение картинок|декодировать и писать JPEG|уменьшается, формат сохраняется|Имена файлов (а значит и `imageRef` блоков) вычислены до записи байтов; смена формата сломала бы все ссылки|
|`SHA1`|предполагался системный|реализация в репозитории (`Import/SHA1.swift`)|Единственная внешняя зависимость — ZIPFoundation; `CryptoKit` на Linux отсутствует, а тесты ядра идут на Linux|
|Читатель|`App/Reader/ReaderHTMLBuilder.swift`|`Core/Reader/ReaderHTMLBuilder.swift`|Чистая сборка строк; две ошибки в ней (частичный блок, маркер «далее — оригинал») дорого отлаживать на устройстве|
|CSS заголовков|`h1,h2,h3`|`.b[data-kind="heading"]`|Блоки — это `<div>` с `data-kind`, селектор `h1` не совпал бы никогда|

### 13.3 Окружение и сборка

|Что|Как в плане|Как сделано|Почему|
|---|---|---|---|
|Локальный Swift в WSL|§11: «если установка невозможна — Core проверяется только в CI»|`tools/setup-local-swift.sh`: тулчейн 6.3.3 в `~/swift`, dev-пакеты glibc/gcc/zlib распакованы в `~/.local/sysroot`, поверх реальных путей — overlay в непривилегированном mount namespace|Локальный `swift test` (227 тестов) вместо ожидания CI; на хосте нет libc6-dev и нет root|
|Проверка app-слоя|—|`tools/check-app-syntax.sh` + CI|iOS-SDK локально нет, типы проверяет только CI; синтаксис ловится за секунду|
|CI, Linux-джоб|`swift-actions/setup-swift@v2`|контейнер `swift:6.3.3`|Официальный образ, без сторонних действий и без зависимости от рантайма Node|
|CI, версии действий|`checkout@v4`, `upload-artifact@v4`|`@v7`|Node 20 удалён с раннеров 2026-09-23, действия на нём перестанут запускаться|
|`Package.resolved`|в `.gitignore`|закоммичен|CI должен резолвить ту же ревизию ZIPFoundation, а не ту, что вышла сегодня|
|Сидлоад|`iloader` + SideStore, туннель `LocalDevVPN` или `StosVPN`|только `LocalDevVPN`|StosVPN удалён из App Store (страница 404, lookup API возвращает 0); SideStore docs прямо просят перейти на LocalDevVPN|
|Диспетчер оставшихся данных|—|`spine/itemref` берутся все, включая `linear="no"`|План говорит «элементы spine/itemref по порядку» без исключений|

### 13.4 Что осталось непроверенным

- **Живой протокол Gemini.** Ни один запрос не был отправлен: проверены литералы,
  сборка запросов и разбор ответов на синтетических данных. Первый реальный
  запрос — шаг «Тест: перевести 1 абзац» в Debug.
- **App-слой не запускался.** Компилируется в CI и разобран ревью, но ни один
  экран не открывался на устройстве. Найденное ревью (и исправленное) стоит
  отдельного упоминания, потому что это класс ошибок, который CI не ловит:
  `callAsyncJavaScript` привязывает ключи словаря аргументов как **именованные**
  параметры, а не позиционные, поэтому чтение WIZ-параметров через
  `arguments[0]` не могло работать никогда — перевод не запустился бы вообще.
  Тот же аудит дал: остановку очереди при удалении книги, разделение «нет связи»
  и «ошибка протокола» (иначе выключенный VPN сжигал попытки и навсегда помечал
  батчи как failed), защиту от перезаписи состояния воркера отменённой задачей,
  импорт вне главного актора и поддержку `.fb2.zip`.
- **Список моделей и `qpEbW`.** Форма ответов не подтверждена; сырые payload’ы
  показываются в Debug и «Лимитах» как есть, чтобы их можно было переписать в
  `gemini-web.json` без пересборки.
- **Тир и остаток лимитов.** Вычисляются эвристически из `jSf9Qc`; в UI видно
  сырые значения.
- **Устройство.** Ни импорт, ни чтение, ни перевод на iPhone не запускались:
  macOS и устройства в этой среде нет. Проверено: 227 тестов ядра, сборка IPA в
  CI, синтаксис app-слоя.
