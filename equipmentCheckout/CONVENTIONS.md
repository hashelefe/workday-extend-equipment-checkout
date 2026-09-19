# Coding conventions

This app is kept clean against **[Arcane Auditor](https://github.com/Developers-and-Dragons/ArcaneAuditor) v1.2.0**
— 42 static-analysis rules for Workday Extend. Current state: **1 finding**, the documented `hrAccess` exception (down from 108 on the
first run).

Run it before every commit and before every upload:

```powershell
.\scripts\Invoke-ArcaneAuditor.ps1
```

Severity is two-tier: **ACTION** (fix now) and **ADVICE** (fix unless you can justify it).
Treat both as blocking here. The app is at one finding, the documented `hrAccess` exception, and should stay there.

---

## The eight rules that actually bit this app

These produced all 108 original findings. Get them right up front.

### 1. Every widget needs an `id` (ACTION — was 52 findings)

Applies to nested widgets too, including the widget inside a grid column's `cellTemplate`.

```jsonc
{ "type": "text", "id": "loanItemCell", "value": "<% loan.item.descriptor %>" }
```

IDs must be lowerCamelCase (`WidgetIdLowerCamelCaseRule`). Exempt types: `footer`, `item`,
`group`, `title`, `pod`, `cardContainer`, `card`, `instanceList`, `taskReference`,
`editTasks`, `multiSelectCalendar`, `bpExtender`, `hub`, and `column` (uses `columnId`).

### 2. Endpoints must fail on **both** 400 and 403 (ACTION — was 16)

400 alone is not enough. Inbound and outbound both.

```jsonc
"failOnStatusCodes": [ { "code": 400 }, { "code": 403 } ]
```

Without it a 403 is swallowed and the page carries on as if the call succeeded.

### 3. No `console` statements (ACTION — was 5)

They leak business logic and PII into production logs. If you add one while debugging,
remove it before committing. In this app it also made the `onSend` blocks pointless — an
`onSend` that only does `return self.data;` is noise, so they were deleted outright.

### 4. Use `const` / `let`, never `var` (ADVICE — was 24)

Including for-each loop variables — the PMD script grammar has an explicit
`for (const x : list)` production, so this is legal:

```javascript
for (const row : rows) { ... }
```

### 5. Keep PMD root sections in order (ADVICE — was 5)

```
id → securityDomains → include → script → endPoints → onSubmit → outboundData → onLoad → presentation
```

`script` comes **before** `endPoints`, which is the one people get wrong.

### 6. No string concatenation in scripts (ADVICE — was 5)

Prefer PMD template literals. Note the docs and the runtime message disagree on the
placeholder form (`{{var}}` vs `{var}`); the verified form, from Workday's own
`tuitionReimbursement` sample, is **double braces inside backticks**:

```javascript
`SELECT x FROM {{appId}}_something WHERE id = '{{eventId}}'`
```

Do not convert a working concatenation just to satisfy this rule unless you can test it.

### 7. No magic numbers (ADVICE — was 1)

```javascript
const validatePurpose = function(field) {
  const maxPurposeLength = 250;   // inside the function, never at script top level
  if (field.value.length() > maxPurposeLength) { ... }
};
```

### 8. Every PMD needs a security domain (ACTION)

Except `errorPage`-style and microConclusion pages. Every page here declares one.

---

## The rest, grouped

### Never hardcode

| Instead of | Use |
| --- | --- |
| `https://*.workday.com/...` | a `dataProvider` + `baseUrlType` (`HardcodedWorkdayAPIRule`, ACTION) |
| a literal `applicationId` | `site.applicationId` (`HardcodedApplicationIdRule`) |
| a literal WID | an app attribute (`HardcodedWidRule`) |
| a base64 image | an external file (`EmbeddedImagesRule`) |

### Endpoint hygiene

- **Never** `isCollection: true` on inbound endpoints (ACTION) — performance.
- **Never** `bestEffort` (`OnlyMaximumEffortRule`, ACTION) — it masks API failures.
- **Never** `variableScope: session` on outboundVariable endpoints (ACTION).
- Endpoint names lowerCamelCase.
- Always reach Workday APIs through a `dataProvider`, never a raw URL.

### Grids

Do not combine paging (`autoPaging` / `pagingInfo`) with `sortableAndFilterable` columns
(ACTION) — Workday then loads the whole dataset client-side, defeating the paging. Pick one.
This app uses `sortableAndFilterable` and no paging, which is why `allEquipment` /
`allRequests` cap at `limit: 100`. If the catalog outgrows that, add paging and **drop the
sortable flags at the same time**.

### Script quality

Max nesting 4 · max cyclomatic complexity 10 · max function length 50 lines · max embedded
script block length · max 4 parameters per function. Prefer `map`/`filter`/`forEach` over
manual loops. No nested array searches (O(n²)). No empty functions, unused functions, unused
parameters, unused variables, or unused includes. Consistent return patterns. Concise boolean
expressions (`if (x)`, not `if (x == true)`). Descriptive array-method parameter names
(single letters allowed only for `a`/`b` in comparators). Never assign a new object to
`self.data` in an `onSend` — property assignment on the existing object is fine.

### Naming and types

- File names lowerCamelCase.
- Variables and function parameters lowerCamelCase.
- Booleans are real booleans, never `"true"` / `"false"` strings (`StringBooleanRule`).
- Footers should use pod structure (`FooterPodRequiredRule`).

---

## Three deliberate deviations

All are intentional. Don't "fix" them without reading the reasoning.

**1. `script` blocks contain raw newlines inside JSON strings.** Strict JSON forbids this;
the Workday PMD parser accepts it and every official Workday sample relies on it. This keeps
script blocks readable. `scripts/validate.py` parses those files in a tolerant mode and
reports how many needed it (currently 13 of 37).

**2. Status filtering happens in page script, not in the GraphQL `where` clause.** No app in
Workday's public sample catalog filters a plain TEXT field, so the criteria operator is
unverified. Filtering on instance references (`requester`) *is* verified and is done
server-side. See the README for how to push the rest down once you can inspect the generated
`_Criteria` type.

**3. `home.pmd`'s `hrAccess` endpoint fails on 400 only, not 403.** Arcane Auditor reports this as the
one expected finding (`EndpointFailOnStatusCodesRule`), and it has no way to suppress it. PMD cannot read a
user's security groups, so the home page tells HR partners apart by reading `hrPartnerAccess`, an
empty object secured only by `HR Partner: Equipment Checkout`. A 403 there means "not an HR partner"
and must not fail the page. The HR pages themselves are secured by page security, so this only
decides whether the buttons are shown. Keep the exception to this one endpoint.

---

## Platform rules neither check catches

Both of these passed `validate.py` and Arcane Auditor, then failed on Workday.

| Rule | Failure | Fix |
| --- | --- | --- |
| A page `script` may contain **only function definitions** | Runtime: "Page script validation fails - only function definition is allowed in page script." | Put constants inside the function that uses them |
| An `app` outbound endpoint that uses `self.data` needs its form fields bound with `"valueOutBinding": "<endpointName>.<field>"`; matching widget ids are **not** mapped automatically | Runtime: "Property Error found: .data" in `onSend` | Add `valueOutBinding` to each input widget |
| An orchestration launched from a page must list a security domain, and that domain's `.securitydomain` needs `"enabledForOrchestrationSecurity": true` | Without the flag the build fails with "An invalid security domain was used"; with no domain at all the page got a 404 on `…/orchestrations/<name>/launch` and the orchestration never ran (suspected cause, pending confirmation on the tenant) | Set both, as `ManageEquipment` / `importEquipmentItems` do |
| An orchestration can have only **one** security domain | Build: "Only one security domain can be defined for an orchestration" | Pick the single domain that should run it; users who launch it from other pages need that domain too |
| An `instanceList` widget's `instanceList` must be a literal JSON array; only the fields inside each `{type: instance, id, descriptor, wid}` may be expressions | Build: "Cannot deserialize value of type ArrayList<Instance> from String value" | Write the one-item array literally and hide the cell with `render` when there is nothing to link, as the process-reference columns do |
| A `.script` include must end with an object literal mapping the functions it exports (`{ "eventId": eventId }`) | Arcane: "neither exported nor used internally"; pages cannot call unexported functions | Follow `scripts/bpRefs.script` and Workday's `dates.script` |
| `.wdignore` patterns match at any depth unless anchored with a leading `/` | `scripts/` also dropped `presentation/scripts/`: build said "Ensure that you include script modules that exist" | Anchor root-only folders (`/scripts/`) and check with `wdcli app upload . --dry-run -o x.zip` |
| No `for (const x : list)` loops | Build: "Parsing Error" in `Pmd:script`, then every function counts as undefined | Use `list.filter(x => {...})` / `.map(...)` / `.forEach(...)` |
| WQL text, id and date values in `WHERE` must be quoted: `WHERE workdayID = '<% eventId %>'` | Runtime 400: "text or date target values must be in single or double quotes" | Wrap every `<% %>` value in single quotes, as Workday's `tuitionReimbursement` sample does |
| Update `EquipmentItem` through the `updateItem` GraphQL mutation, not a REST `PATCH equipmentItems/{id}` | REST PATCH returned 400 "unrecognized field: status" (2026-09-19), although the same field worked over GraphQL and REST PATCH worked on the other two objects. Cause not known | Use `updateItem`, as `acknowledge.pmd` and `returnHandoff.pmd` do |
| A BP action step or revise page must finish its own step: POST `eventSteps/{eventStepId}/submit` on the `workday-bp` provider with `stepAction.id` = `d9e4223e446c11de98360015c5e6daf6` (Arcane Auditor allowlists this WID) | Nothing errors; the step just never completes and the BP sits in the inbox | Resolve the target with `eventSteps/{id}` → `events/{event.id}` → `for.id`, as `returnHandoff.pmd` does |

Orchestration files also fail at build if `defaultLocale` is not a real `Locale`,
`defaultWorkdayCredentialRef` is empty, or a step reads `body` from a Workday API
call (the output is named `response`).

---

## Checklist before upload

```powershell
python scripts\validate.py            # structure, labels, references, placeholders
.\scripts\Invoke-ArcaneAuditor.ps1    # 42 rules — expect exactly 1 finding: hrAccess in home.pmd
```

`validate.py` covers what Arcane Auditor does not: label coverage, task/query reference
resolution, business-process route wiring, and unreplaced `__APPID__` placeholders.
