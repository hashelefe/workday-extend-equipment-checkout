# Equipment Checkout

A Workday Extend app for lending IT equipment. Employees browse a pool of laptops,
monitors, phones and headsets, request one with a return date, and it routes through a real
Workday business process: manager approval, then the payroll partner for their supervisory
organization, then back to the employee to confirm collection. Items are checked out against
the borrower and flip back to available when returned.

Built to exercise the full Extend stack end to end: two custom business objects with a
reference between them, a business process with approval and action steps, a scheduled
orchestration, the GraphQL and REST data APIs, WQL, PMD pages with grids, forms, validation
and conditional rendering, PMD scripting, and domain-based security separating self-service
from administration.

Code style is enforced by [Arcane Auditor](https://github.com/Developers-and-Dragons/ArcaneAuditor)
(42 rules) — currently **0 findings**. See [CONVENTIONS.md](CONVENTIONS.md).

## Layout

```
equipmentCheckout/
  appManifest.json                     app reference id and display name
  CONVENTIONS.md                       coding rules enforced by Arcane Auditor
  model/
    EquipmentItem.businessobject       the asset catalog
    CheckoutRequest.businessobject     a loan record, references EquipmentItem + WORKER
    EquipmentCheckoutApproval.businessprocess   manager -> payroll partner -> acknowledgement
    ManageEquipment.securitydomain     administrators
    RequestEquipment.securitydomain    employee self-service
    AllEquipment.report                admin report over the catalog
    AllCheckouts.report                admin report over every request
    EquipmentCheckout.task             tenant entry point
  presentation/
    equipmentCheckout.amd              tasks, routes, data providers
    equipmentCheckout.smd              site, auth scheme, error page routing
    home.pmd                           what you have on loan, what is pending
    browse.pmd                         available catalog, request action
    request.pmd                        create a request and launch the business process
    myRequests.pmd                     full personal request history
    manage.pmd                         admin view of the queue and outstanding loans
    approve.pmd                        BP approval step (manager and payroll partner)
    acknowledge.pmd                    BP action step - employee confirms collection
    revise.pmd                         BP send-back step
    viewRequest.pmd                    BP details page
    returnItem.pmd                     admin records a return
    addItem.pmd                        add an asset to the catalog
    errorPage.pmd                      401 / 404 / 500 / 503
    cards/AppLinks.card                reusable navigation card
    graphQueries/*.graphquery          5 reads, 4 mutations
    wqlQueries/*.wqlquery              event resolution + overdue detection
    presentationLabels/en-US.properties  every user-facing string
  orchestration/
    notifyOverdueLoans.orchestration   scheduled overdue reminder fan-out
  scripts/
    Set-AppId.ps1                      stamps the deployed app id into the queries
    Invoke-ArcaneAuditor.ps1           runs the 42-rule static analyser
    validate.py                        pre-upload checks
```

## Data model

`EquipmentItem` is the physical asset. `assetTag` is the reference id and display field,
and `status` moves between `AVAILABLE`, `CHECKED_OUT`, `MAINTENANCE` and `RETIRED`.
A derived field, `displayLabel`, joins the tag and name for dropdowns and grids.

`CheckoutRequest` is one loan, referencing an `EquipmentItem` and two workers (the
`requester` and, once decided, the `approver`). Its `status` runs
`PENDING -> APPROVED -> RETURNED`, or `PENDING -> REJECTED`.

`requester` sets `secureByTarget: true`, so a worker holding only the self-service domain
sees their own requests rather than everyone's. The admin domain sees the whole table.

## Getting it running

1. **Install the CLI.** Sign in at <https://developer.workday.com/downloads>, download the
   Windows installer for the Workday Developer CLI, run it, then confirm with `wdcli version`.
   It is a native installer, not an npm package.

2. **Authenticate.**

   ```
   wdcli auth login
   wdcli tenant list
   wdcli tenant login <your-tenant-alias>
   ```

3. **Create the app** so App Hub assigns it an id:

   ```
   wdcli app create equipmentCheckout
   wdcli app info equipmentCheckout
   ```

4. **Stamp the app id into the queries.** Workday derives the GraphQL schema names from
   the assigned id, which is not knowable in advance, so the queries ship with
   `__APPID__` and `__APPIDPASCAL__` placeholders:

   ```powershell
   .\scripts\Set-AppId.ps1 -AppId equipmentCheckout_ab12cd
   ```

   Use `-WhatIf` first to preview, and `-OldId` later if the id ever changes.

5. **Validate**, which catches bad JSON, missing labels, dangling task references and
   leftover placeholders:

   ```
   python scripts/validate.py
   ```

6. **Upload and deploy.**

   ```
   wdcli app upload
   wdcli app deploy equipmentCheckout --tenant-alias <alias> --version <version>
   ```

7. **Wire up security in the tenant.** Add `Manage: Equipment Checkout` and
   `Self-Service: Equipment Checkout` to the appropriate security groups, then run
   *Activate Pending Security Policy Changes*. Until you do, the pages return 401 and you
   will land on the error page.

8. **Configure the business process in the tenant.** The app declares the BP type and its
   pages; Workday owns the routing. Create the definition for *Equipment Checkout Approval*
   with four steps:

   | # | Step | Type | Routes to |
   | - | ---- | ---- | --------- |
   | 1 | Request initiated | Initiation | Employee, via the app's Request page |
   | 2 | Manager approval | Approval | Manager of the requester |
   | 3 | Payroll partner approval | Approval | Payroll Partner for the requester's supervisory organization |
   | 4 | Employee acknowledgement | Action step `EmployeeAcknowledgement` | The original requester |

9. **Schedule the orchestration** (optional). `notifyOverdueLoans` does not schedule itself;
   set a cadence in the tenant once you have built its `sendOverdueReminder` sub-flow.

10. **Seed the catalog.** Open the app, go to Manage Requests, and use Add Catalog Item.
    Asset tags follow `LAP-0042` — two to four capital letters, a hyphen, three to five digits.

Before any upload, run both checks:

```powershell
python scriptsalidate.py
.\scripts\Invoke-ArcaneAuditor.ps1
```

## The approval business process

Approvals are a real Workday business process, so they arrive in each approver's Workday
inbox rather than in a custom page inside the app.

```
request initiated  ->  manager approval  ->  payroll partner approval  ->  employee acknowledgement
   (request.pmd)        (approve.pmd)          (approve.pmd)                  (acknowledge.pmd)
```

`model/EquipmentCheckoutApproval.businessprocess` declares the BP *type* and which page each
kind of step renders. **The ordering and the routing are tenant configuration, not source** —
build the four steps in the Workday BP definition and point step 2 at the requester's manager
and step 3 at the Payroll Partner for their supervisory organization. Both are Approval steps
and both render the same `/approve/{eventId}` page.

Two details worth knowing:

- **`approve.pmd` has no Approve or Deny buttons.** Workday renders those around the page.
  The page's only job is to show the request. This mirrors Workday's `workFromAlmostAnywhere`
  sample; adding your own buttons would duplicate the BP's own controls.
- **BP pages receive an `eventId`, not a record id.** The two queries in
  `presentation/wqlQueries/` resolve an event back to the `CheckoutRequest` it targets.

Launching the BP is two calls in `request.pmd`: POST the record to `checkoutRequests`, then
POST to `equipmentCheckoutApprovalEvents` with `businessProcessTarget.id`. That path uses the
REST `app` data provider rather than GraphQL because it is the only BP-launch pattern
demonstrated in Workday's public samples.

The item flips to `CHECKED_OUT` at **acknowledgement**, not at approval — that is when the
borrower physically has it.

### Known gap: denied requests

A denial is recorded by the BP but is not mirrored onto the `CheckoutRequest`, so the record
stays `PENDING` and the item never returns to `AVAILABLE`. Closing this needs a BP-triggered
orchestration (`.maya.FlowBusinessProcessTriggered`) that writes the outcome back. It was left
out rather than guessed at.

## The overdue reminder orchestration

`orchestration/notifyOverdueLoans.orchestration` reads outstanding loans, iterates the ones
not yet returned, and hands each to a `sendOverdueReminder` sub-flow.

**Read this before using it.** `.orchestration` files are normally produced by Orchestration
Builder, not written by hand. This one was generated to be field-for-field structurally
identical to a verified Workday sample (`deleteCases.orchestration`) — same flow, loop, group
and request field sets, same `flowVersion` and `mayaVersion`, confirmed by diff. The
*structure* is verified; the Maya *expression strings* inside it are not. Open it in
Orchestration Builder before trusting it.

Two things are deliberately not in it:

- **`sendOverdueReminder` does not exist yet.** No app in Workday's public catalog calls a
  notification API, so there was no verified pattern to copy. Build that sub-flow in
  Orchestration Builder — it owns the due-date comparison and the notification channel.
- **Scheduling.** Nothing in the file schedules it; set the cadence in the tenant.

If the file misbehaves, `presentation/wqlQueries/overdueLoans.wqlquery` performs the overdue
detection declaratively in plain, verified WQL — build the flow around that instead.

## Design decisions worth knowing

**Filtering choices.** Status narrowing happens in PMD script rather than in the GraphQL
`where` clause. Across every app in Workday's official sample catalog, the only criteria
shape that appears is `in:` against instance references and `workdayID` — there is no
example of filtering a plain `TEXT` field, and guessing the operator would have produced
queries that fail at runtime. So `myRequests` filters server-side on `requester`, which
follows the proven pattern, while `AVAILABLE` / `PENDING` / `APPROVED` narrowing happens
in page script over a bounded result set. Once you can see your tenant's generated schema
in App Builder's GraphQL explorer, check the `_Criteria` input type for the `status` field
and push that filter down into the query — it is the single best first optimisation here,
and the page scripts that do the filtering are small and isolated.

**Pagination.** `allEquipment` and `allRequests` request `limit: 100`. Fine for a demo
catalog, not for a real fleet. Both queries already declare `$limit` and `$offset`, so
adding paging controls is a presentation change, not a query rewrite.

**Multi-line script blocks.** The `script` and `onChange` blocks contain raw newlines
inside JSON strings. Strict JSON forbids that, but the Workday PMD parser accepts it and
every official Workday sample relies on it. `validate.py` parses those files in a
tolerant mode for exactly this reason, and reports how many files needed it.

**Approve and check out are two mutations.** `decide.pmd` fires `updateRequest` always,
plus `checkOutItem` or `returnItem` depending on the decision, each gated by an `exclude`
expression. Extend has no cross-endpoint transaction, so a failure in the second call
leaves the request decided but the item status stale. For a portfolio app that is an
acceptable, documented trade-off; a production version would move this into an
orchestration with compensation.

## Verify these in your tenant

Two things could not be confirmed against the public sample catalog and are worth testing
on your first deploy:

- **Clearing an instance reference.** `returnItem` sets `currentHolder` to `null` to
  release the item. If your tenant rejects a null instance reference, drop the field from
  that mutation and rely on `status` alone to signal availability.
- **Nested selections on a custom BO reference.** Queries read `item { descriptor }`
  rather than reaching through to `item { assetTag }`. If the generated schema exposes the
  target's own fields, selecting them directly removes a lookup in the grids.

## Where to take it next

- Push status filtering into the GraphQL `where` clause once you confirm the criteria type.
- Add an orchestration that emails borrowers a few days before `dueDate` and flags overdue
  loans — `manage.pmd` already computes overdue state in `isOverdue()`.
- Replace the approval page with a real Workday business process so decisions land in the
  approver's Workday inbox instead of a custom page.
- Add a `MAINTENANCE` flow so admins can pull an item out of circulation without retiring it.
