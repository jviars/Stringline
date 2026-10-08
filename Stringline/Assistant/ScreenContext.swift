import Foundation

/// Describes the screen the person has open, so the assistant knows what "this" means.
@MainActor
enum ScreenContext {
    /// "Maple Ridge Plaza › Estimate › Option A", "Schedule › Week of Oct 19", "Today".
    static func breadcrumb(_ store: AppStore) -> String {
        switch store.selection {
        case .today: return "Today"
        case .pipeline: return "Pipeline"
        case .measure: return "Measure"
        case .jobs: return "Jobs"
        case .schedule:
            return "Schedule › Week of \(Fmt.day(store.visibleScheduleWeek ?? Calendar.current.mondayOfWeek(.now)))"
        case .customers:
            if let id = store.visibleCustomerID, let c = store.customer(id) { return "Customers › \(c.name)" }
            return "Customers"
        case .invoices: return "Invoices"
        case .equipment: return "Equipment"
        case .crew: return "Crews"
        case .documents: return "Documents"
        case .learn: return "Learn Stringline"
        case .settings: return "Settings & rates"
        case .job(let id):
            guard let job = store.job(id) else { return "Jobs" }
            var parts = [job.name, store.jobTab.label]
            if store.jobTab == .estimate, let e = store.estimates[id], let selected = e.selected, e.options.count > 1,
               let i = e.options.firstIndex(where: { $0.id == selected.id }) {
                parts.append("Option \(ToolRunner.letter(i))")
            }
            return parts.joined(separator: " › ")
        }
    }

    /// "today", "schedule", "job:estimate", "settings"… matching HelpArticle.screen.
    static func screenKey(_ store: AppStore) -> String {
        switch store.selection {
        case .today: "today"
        case .pipeline: "pipeline"
        case .measure: "measure"
        case .jobs: "jobs"
        case .schedule: "schedule"
        case .customers: "customers"
        case .invoices: "invoices"
        case .learn: "learn"
        case .settings, .crew: "settings"
        case .equipment: "equipment"
        case .documents: "documents"
        case .job: "job:\(store.jobTab.rawValue)"
        }
    }

    /// Where the person is, for tools like show_me.
    static func runnerContext(_ store: AppStore, panelOpen: Bool) -> RunnerContext {
        var context = RunnerContext()
        context.panelOpen = panelOpen
        let key = screenKey(store)
        if case .job(let id) = store.selection {
            context.screen = "job"
            context.jobID = id
            context.jobTab = store.jobTab.rawValue
        } else {
            context.screen = key
        }
        return context
    }

    static func snapshot(_ store: AppStore, shareContact: Bool, pending: [ProposedChange]) -> JSONValue {
        let reader = ToolRunner(base: store, mode: .chat, areas: [], shareContact: shareContact)
        func tool(_ name: String, _ args: JSONValue) -> JSONValue { reader.run(name: name, arguments: args.compactString).output }
        let today = Date().startOfDay
        var o: [String: JSONValue] = [
            "today": ToolArgs.iso(today),
            "weekday": .string(Fmt.weekday(today)),
            "company": ["name": .string(store.settings.company.name), "home_base": .string(store.settings.company.homeBase)],
            "crews": .array(store.settings.crews.map { ["id": .string($0.id.uuidString), "name": .string($0.name), "kind": .string($0.kind), "people": .number(Double($0.people))] }),
        ]
        let key = screenKey(store)
        let help = key == "settings"
            ? KnowledgeBase.articles.filter { $0.screen?.hasPrefix("settings:") == true }
            : KnowledgeBase.articles(forScreen: key)
        o["screen_key"] = .string(key)
        o["help_for_this_screen"] = .array(help.prefix(6).map { KnowledgeBase.json($0, full: false) })
        if !pending.isEmpty {
            o["changes_waiting_for_apply"] = .array(pending.map { .string("\($0.title)\($0.isOn ? "" : " (unticked)")") })
        }

        switch store.selection {
        case .today:
            o["screen"] = "today"
            o["needs_attention"] = .array(Attention.items(store).prefix(12).map {
                ["title": .string($0.title), "detail": .string($0.detail), "job_id": .string($0.jobID.uuidString)]
            })
            o["schedule_today_and_tomorrow"] = tool("get_schedule", ["start_date": ToolArgs.iso(today), "days": 2])
        case .pipeline:
            o["screen"] = "pipeline"
            o["pipeline"] = tool("list_jobs", ["stage": nil])
        case .schedule:
            o["screen"] = "schedule"
            let week = store.visibleScheduleWeek ?? Calendar.current.mondayOfWeek(.now)
            o["week"] = tool("get_schedule", ["start_date": ToolArgs.iso(week), "days": 6])
            o["won_not_scheduled"] = .array(store.realJobs.filter { $0.stage == .won && $0.completedOn == nil && $0.schedule.isEmpty }.map(reader.jobBrief))
        case .customers:
            o["screen"] = "customers"
            o["customer_count"] = .number(Double(store.customers.count))
            if let id = store.visibleCustomerID { o["selected_customer"] = tool("get_customer", ["customer": .string(id.uuidString)]) }
        case .invoices:
            o["screen"] = "invoices"
            o["invoices"] = tool("get_invoices", [:])
        case .settings, .crew:
            o["screen"] = "settings"
            o["note"] = "Settings & rates: company, rates and markup, weather rules, proposal wording, data and backups, crews, AI assistant."
        case .job(let id):
            o["screen"] = "job"
            o["tab"] = .string(store.jobTab.rawValue)
            o["job"] = tool("get_job", ["job": .string(id.uuidString)])
            switch store.jobTab {
            case .estimate:
                o["estimate_on_screen"] = tool("get_estimate", ["job": .string(id.uuidString), "option": nil])
            case .schedule:
                o["weather_next_days"] = tool("get_weather", ["start_date": ToolArgs.iso(today), "days": 10, "job": .string(id.uuidString)])
            default:
                break
            }
        case .measure, .jobs, .equipment, .documents, .learn:
            o["screen"] = .string(breadcrumb(store).lowercased())
        }

        if case .job = store.selection {} else {
            o["jobs_index"] = .array(store.jobs.prefix(80).map { j in
                ["id": .string(j.id.uuidString), "name": .string(j.name), "stage": .string(j.stage.rawValue), "customer": .string(store.customerName(for: j))]
            })
        }
        return .object(o)
    }
}
