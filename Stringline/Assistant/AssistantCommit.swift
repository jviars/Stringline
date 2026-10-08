import Foundation

/// A record's value before and after the assistant's changes were applied.
struct ValueChange<T: Equatable>: Equatable {
    var before: T?
    var after: T?
}

extension Takeoff {
    /// The measurements without where the map happens to be pointed, which changes just by looking.
    var withoutView: Takeoff {
        var t = self
        t.center = nil
        t.spanMeters = nil
        return t
    }

    /// `other`'s measurements, keeping this takeoff's map view.
    func keepingView(of current: Takeoff?) -> Takeoff {
        var t = self
        if let current {
            t.center = current.center
            t.spanMeters = current.spanMeters
        }
        return t
    }
}

extension AppSettings {
    /// The part of settings the assistant can change. Counters and dates Stringline keeps up on its own
    /// (next invoice number, last backup) are left out, so they never block an undo.
    var editable: AppSettings {
        var s = AppSettings()
        s.company = company
        s.weather = weather
        s.proposal = proposal
        s.crews = crews
        s.backupNightly = backupNightly
        s.sealcoatCycleYears = sealcoatCycleYears
        return s
    }

    /// These settings with `other`'s editable part.
    func takingEditable(of other: AppSettings) -> AppSettings {
        var s = self
        s.company = other.company
        s.weather = other.weather
        s.proposal = other.proposal
        s.crews = other.crews
        s.backupNightly = other.backupNightly
        s.sealcoatCycleYears = other.sealcoatCycleYears
        return s
    }
}

/// A job the assistant created, with everything that goes with it, so undo and redo can remove and restore it.
struct CreatedJob: Equatable {
    var job: Job
    var takeoff: Takeoff
    var estimate: Estimate
    var logs: JobLogs
    var invoice: Invoice?
}

/// Everything one Apply changed. Undo restores a record only if it still holds what the assistant wrote,
/// so anything the owner edited afterwards is never overwritten.
struct UndoRecord: Equatable {
    var jobs: [UUID: ValueChange<Job>] = [:]
    var createdJobs: [UUID: CreatedJob] = [:]
    var customers: [UUID: ValueChange<Customer>] = [:]
    var createdCustomers: [UUID: Customer] = [:]
    var estimates: [UUID: ValueChange<Estimate>] = [:]
    var takeoffs: [UUID: ValueChange<Takeoff>] = [:]
    var logs: [UUID: ValueChange<JobLogs>] = [:]
    var invoices: [UUID: ValueChange<Invoice>] = [:]
    var rates: ValueChange<Rates>?
    var settings: ValueChange<AppSettings>?
}

/// What Apply does outside Stringline. The self-test swaps in a recorder so no app opens.
@MainActor
protocol CommitSideEffects {
    func mail(to: String?, subject: String, body: String)
    func text(to: String?, body: String)
    func calendar(_ items: [(job: Job, entry: ScheduleEntry, crew: Crew?)], name: String) throws
}

@MainActor
struct AppleSideEffects: CommitSideEffects {
    func mail(to: String?, subject: String, body: String) { Mailer.compose(to: to, subject: subject, body: body) }
    func text(to: String?, body: String) { MessagesDraft.compose(to: to, body: body) }
    func calendar(_ items: [(job: Job, entry: ScheduleEntry, crew: Crew?)], name: String) throws { try CalendarExport.open(items, name: name) }
}

@MainActor
enum AssistantCommit {
    static var sideEffects: CommitSideEffects = AppleSideEffects()

    struct Outcome {
        var record: UndoRecord
        var applied: [ProposedChange]
        var skipped: [String]
        var highlights: Set<UUID>
        var mailDrafts: Int
    }

    struct Refusal: Error {
        let message: String
    }

    /// Applies the ticked changes to the real data, in order, after checking that every file
    /// involved can be saved. Nothing is written if any of them can't.
    static func commit(_ changes: [ProposedChange], store: AppStore) -> Result<Outcome, Refusal> {
        guard store.dataFolder != nil else { return .failure(Refusal(message: "Open your PavingData folder first.")) }
        if let other = store.savingPaused {
            return .failure(Refusal(message: "Saving is paused because Stringline is open on \(other.machineName). Press Use This Mac at the bottom of the window, then Apply."))
        }

        var state = DraftState()
        var skipped: [String] = []
        var applied: [ProposedChange] = []
        for change in changes {
            var trial = state
            do {
                for op in change.ops { try trial.apply(op, base: store) }
                state = trial
                applied.append(change)
            } catch {
                skipped.append("\(change.title): \(error.localizedDescription)")
            }
        }
        guard !state.isEmpty else { return .failure(Refusal(message: skipped.first ?? "There was nothing to apply.")) }

        // Every existing file this would write must be readable and not waiting on a conflict.
        let newJobs = Set(state.newJobs)
        var keys: [SaveKey] = []
        keys += state.jobs.keys.filter { !newJobs.contains($0) }.map { .job($0) }
        keys += state.estimates.keys.filter { !newJobs.contains($0) }.map { .estimate($0) }
        keys += state.takeoffs.keys.filter { !newJobs.contains($0) }.map { .takeoff($0) }
        keys += state.logs.keys.filter { !newJobs.contains($0) }.map { .logs($0) }
        keys += state.invoices.keys.filter { !newJobs.contains($0) }.map { .invoice($0) }
        keys += state.customers.keys.filter { !state.newCustomers.contains($0) }.map { .customer($0) }
        if state.rates != nil { keys.append(.rates) }
        if state.settings != nil { keys.append(.settings) }
        for key in keys {
            guard let file = store.file(for: key) else { continue }
            if let issue = store.unavailable[file.path] {
                return .failure(Refusal(message: "\(store.label(for: file)) can't be changed right now: it's \(issue.short). Nothing was applied."))
            }
            if store.conflicts.contains(where: { $0.path == file.path }) {
                return .failure(Refusal(message: "\(store.label(for: file)) has two versions waiting for you to choose between. Nothing was applied."))
            }
        }

        var record = UndoRecord()
        var highlights = Set<UUID>()

        for id in state.newCustomers {
            guard let c = state.customers[id] else { continue }
            store.customers.append(c)
            store.markDirty(.customer(id))
            record.createdCustomers[id] = c
        }
        for (id, c) in state.customers where !state.newCustomers.contains(id) {
            guard let i = store.customers.firstIndex(where: { $0.id == id }) else { continue }
            record.customers[id] = ValueChange(before: store.customers[i], after: c)
            store.customers[i] = c
            store.markDirty(.customer(id))
        }
        store.customers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        for id in state.newJobs {
            guard let draftJob = state.jobs[id] else { continue }
            let bundle = CreatedJob(job: draftJob, takeoff: state.takeoffs[id] ?? Takeoff(), estimate: state.estimates[id] ?? Estimate(),
                                    logs: state.logs[id] ?? JobLogs(), invoice: state.invoices[id])
            record.createdJobs[id] = insert(bundle, store: store)
            highlights.insert(id)
        }

        for (id, j) in state.jobs where !newJobs.contains(id) {
            guard let i = store.jobs.firstIndex(where: { $0.id == id }) else { continue }
            let before = store.jobs[i]
            record.jobs[id] = ValueChange(before: before, after: j)
            store.jobs[i] = j
            store.markDirty(.job(id))
            let old = Set(before.schedule.map(\.id))
            highlights.formUnion(j.schedule.map(\.id).filter { !old.contains($0) })
            if before.stage != j.stage { highlights.insert(id) }
        }
        for (id, e) in state.estimates where !newJobs.contains(id) {
            let before = store.estimates[id]
            record.estimates[id] = ValueChange(before: before, after: e)
            store.estimates[id] = e
            store.markDirty(.estimate(id))
            let oldLines = Set((before?.options ?? []).flatMap(\.items))
            highlights.formUnion(e.options.flatMap(\.items).filter { !oldLines.contains($0) }.map(\.id))
        }
        for (id, t) in state.takeoffs where !newJobs.contains(id) {
            record.takeoffs[id] = ValueChange(before: store.takeoffs[id], after: t)
            store.takeoffs[id] = t
            store.markDirty(.takeoff(id))
        }
        for (id, l) in state.logs where !newJobs.contains(id) {
            record.logs[id] = ValueChange(before: store.logs[id], after: l)
            store.logs[id] = l
            store.markDirty(.logs(id))
        }
        for (id, invoice) in state.invoices where !newJobs.contains(id) {
            var inv = invoice
            if inv.number.isEmpty { inv.number = store.nextInvoiceNumber() }
            record.invoices[id] = ValueChange(before: store.invoices[id], after: inv)
            store.invoices[id] = inv
            store.markDirty(.invoice(id))
        }
        if let r = state.rates {
            record.rates = ValueChange(before: store.rates, after: r)
            store.rates = r
            store.markDirty(.rates)
        }
        if let s = state.settings {
            record.settings = ValueChange(before: store.settings.editable, after: s.editable)
            store.settings = store.settings.takingEditable(of: s)
            store.markDirty(.settings)
        }

        // Apple apps last, once everything else is in place. Mail and Messages open drafts the owner sends;
        // Calendar asks which calendar to add the days to.
        for draft in state.mail {
            sideEffects.mail(to: store.customer(draft.customerID)?.email, subject: draft.subject, body: draft.body)
        }
        for text in state.texts {
            sideEffects.text(to: store.customer(text.customerID)?.phone, body: text.body)
        }
        for request in state.calendar {
            let items = store.jobs.filter { request.jobIDs.contains($0.id) }.flatMap { job in
                job.schedule.filter { $0.day >= request.from && $0.day < request.to }.map { (job: job, entry: $0, crew: store.crew($0.crewID)) }
            }
            do {
                try sideEffects.calendar(items, name: "Stringline \(Fmt.day(request.from))")
            } catch {
                skipped.append("Apple Calendar: \(error.localizedDescription)")
            }
        }
        return .success(Outcome(record: record, applied: applied, skipped: skipped, highlights: highlights,
                                mailDrafts: state.mail.count + state.texts.count + state.calendar.count))
    }

    /// Adds a created job and its files. Returns the bundle as saved (with its job number and folder).
    private static func insert(_ bundle: CreatedJob, store: AppStore) -> CreatedJob {
        let j = bundle.job
        let created = store.createJob(name: j.name, customerID: j.customerID, address: j.address, type: j.type, services: j.services,
                                      stage: j.stage, source: j.source, id: j.id)
        var job = j
        job.number = created.number
        job.folderName = created.folderName
        job.created = created.created
        job.updated = created.updated
        job.stageChanged = created.stageChanged
        if let i = store.jobs.firstIndex(where: { $0.id == j.id }) { store.jobs[i] = job }
        store.takeoffs[j.id] = bundle.takeoff
        store.estimates[j.id] = bundle.estimate
        store.logs[j.id] = bundle.logs
        var invoice = bundle.invoice
        if var inv = invoice, inv.number.isEmpty {
            inv.number = store.nextInvoiceNumber()
            invoice = inv
        }
        store.invoices[j.id] = invoice
        for key in [SaveKey.job(j.id), .takeoff(j.id), .estimate(j.id), .logs(j.id)] { store.markDirty(key) }
        if invoice != nil { store.markDirty(.invoice(j.id)) }
        return CreatedJob(job: job, takeoff: bundle.takeoff, estimate: bundle.estimate, logs: bundle.logs, invoice: invoice)
    }

    // MARK: - Undo and redo

    /// Puts back what was there before. Returns notes about anything left alone.
    static func undo(_ r: UndoRecord, store: AppStore) -> [String] {
        var kept: [String] = []
        func restore<T: Equatable>(_ changes: [UUID: ValueChange<T>], current: (UUID) -> T?, set: (UUID, T?) -> Void, key: (UUID) -> SaveKey, name: (UUID) -> String) {
            for (id, change) in changes {
                if current(id) == change.after {
                    set(id, change.before)
                    store.markDirty(key(id))
                } else {
                    kept.append("\(name(id)) changed after the assistant's edit, so it was left as it is.")
                }
            }
        }
        let jobName = { (id: UUID) in store.job(id)?.name ?? "A job" }
        restore(r.estimates, current: { store.estimates[$0] }, set: { store.estimates[$0] = $1 }, key: { .estimate($0) }, name: { "\(jobName($0))'s estimate" })
        restore(r.takeoffs.mapValues { ValueChange(before: $0.before?.withoutView, after: $0.after?.withoutView) },
                current: { store.takeoffs[$0]?.withoutView },
                set: { id, value in store.takeoffs[id] = value?.keepingView(of: store.takeoffs[id]) },
                key: { .takeoff($0) }, name: { "\(jobName($0))'s measurements" })
        restore(r.logs, current: { store.logs[$0] }, set: { store.logs[$0] = $1 }, key: { .logs($0) }, name: { "\(jobName($0))'s daily logs" })
        restore(r.invoices, current: { store.invoices[$0] }, set: { store.invoices[$0] = $1 }, key: { .invoice($0) }, name: { "\(jobName($0))'s invoice" })
        restore(r.jobs, current: { store.job($0) }, set: { id, value in
            if let value, let i = store.jobs.firstIndex(where: { $0.id == id }) { store.jobs[i] = value }
        }, key: { .job($0) }, name: jobName)
        restore(r.customers, current: { id in store.customers.first { $0.id == id } }, set: { id, value in
            if let value, let i = store.customers.firstIndex(where: { $0.id == id }) { store.customers[i] = value }
        }, key: { .customer($0) }, name: { id in store.customer(id)?.name ?? "A customer" })
        if let rates = r.rates {
            if store.rates == rates.after, let before = rates.before {
                store.rates = before
                store.markDirty(.rates)
            } else {
                kept.append("Your rates changed after the assistant's edit, so they were left as they are.")
            }
        }
        if let settings = r.settings {
            if store.settings.editable == settings.after, let before = settings.before {
                store.settings = store.settings.takingEditable(of: before)
                store.markDirty(.settings)
            } else {
                kept.append("Your settings changed after the assistant's edit, so they were left as they are.")
            }
        }
        for (id, created) in r.createdJobs {
            guard let job = store.job(id) else { continue }
            if job == created.job && store.estimates[id] == created.estimate && store.takeoffs[id]?.withoutView == created.takeoff.withoutView && store.logs[id] == created.logs {
                store.deleteJob(id)
            } else {
                kept.append("\(job.name) was kept because it was changed after the assistant added it.")
            }
        }
        for (id, created) in r.createdCustomers {
            guard let current = store.customers.first(where: { $0.id == id }) else { continue }
            if current == created && !store.jobs.contains(where: { $0.customerID == id }) {
                store.deleteCustomer(id)
            } else {
                kept.append("\(current.name) was kept because it was changed or has jobs now.")
            }
        }
        return kept
    }

    /// Applies the same changes again after an undo. Returns the record as it now stands.
    static func redo(_ r: UndoRecord, store: AppStore) -> (record: UndoRecord, kept: [String]) {
        var record = r
        var kept: [String] = []
        func reapply<T: Equatable>(_ changes: [UUID: ValueChange<T>], current: (UUID) -> T?, set: (UUID, T?) -> Void, key: (UUID) -> SaveKey) {
            for (id, change) in changes {
                if current(id) == change.before {
                    set(id, change.after)
                    store.markDirty(key(id))
                } else {
                    kept.append("Something changed in the meantime, so part of it wasn't redone.")
                }
            }
        }
        for (id, customer) in r.createdCustomers where !store.customers.contains(where: { $0.id == id }) {
            store.customers.append(customer)
            store.markDirty(.customer(id))
        }
        reapply(r.customers, current: { id in store.customers.first { $0.id == id } }, set: { id, value in
            if let value, let i = store.customers.firstIndex(where: { $0.id == id }) { store.customers[i] = value }
        }, key: { .customer($0) })
        store.customers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for (id, created) in r.createdJobs where store.job(id) == nil {
            record.createdJobs[id] = insert(created, store: store)
        }
        reapply(r.jobs, current: { store.job($0) }, set: { id, value in
            if let value, let i = store.jobs.firstIndex(where: { $0.id == id }) { store.jobs[i] = value }
        }, key: { .job($0) })
        reapply(r.estimates, current: { store.estimates[$0] }, set: { store.estimates[$0] = $1 }, key: { .estimate($0) })
        reapply(r.takeoffs.mapValues { ValueChange(before: $0.before?.withoutView, after: $0.after?.withoutView) },
                current: { store.takeoffs[$0]?.withoutView },
                set: { id, value in store.takeoffs[id] = value?.keepingView(of: store.takeoffs[id]) },
                key: { .takeoff($0) })
        reapply(r.logs, current: { store.logs[$0] }, set: { store.logs[$0] = $1 }, key: { .logs($0) })
        reapply(r.invoices, current: { store.invoices[$0] }, set: { store.invoices[$0] = $1 }, key: { .invoice($0) })
        if let rates = r.rates {
            if store.rates == rates.before, let after = rates.after {
                store.rates = after
                store.markDirty(.rates)
            } else {
                kept.append("Your rates changed in the meantime, so they weren't redone.")
            }
        }
        if let settings = r.settings {
            if store.settings.editable == settings.before, let after = settings.after {
                store.settings = store.settings.takingEditable(of: after)
                store.markDirty(.settings)
            } else {
                kept.append("Your settings changed in the meantime, so they weren't redone.")
            }
        }
        return (record, Array(Set(kept)))
    }
}
