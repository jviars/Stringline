import Foundation

/// Moves customers and deals in from Zoho. Reads the CSV files Zoho exports: Zoho CRM's Accounts, Contacts, Leads,
/// Deals and Notes; Bigin's Companies, Contacts and Deals; and Zoho Books or Invoice customers. It plans Stringline
/// customers and jobs. Nothing is written here: the plan is ordinary change operations, applied (and undone) the same
/// way as the assistant's, after the owner has seen the preview.
enum ZohoImport {

    // MARK: Files

    enum Kind: String, CaseIterable, Comparable {
        case accounts, contacts, leads, deals, notes, unknown

        var label: String {
            switch self {
            case .accounts: "Companies (Accounts)"
            case .contacts: "Contacts"
            case .leads: "Leads"
            case .deals: "Deals"
            case .notes: "Notes"
            case .unknown: "Not a Zoho export Stringline knows"
            }
        }

        /// Companies first, so contacts and deals find the company they belong to.
        static func < (a: Kind, b: Kind) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    /// One row, read by Zoho's column names in any spelling ("Account Name", "account_name", "ACCOUNT NAME").
    struct Row: Hashable {
        let values: [String: String]

        func get(_ keys: [String]) -> String? {
            for key in keys { if let v = values[key], !v.isEmpty { return v } }
            return nil
        }
    }

    struct Table: Identifiable, Hashable {
        let id = UUID()
        let fileName: String
        let kind: Kind
        let rows: [Row]
    }

    /// Files picked for one import, shown in the Import from Zoho window.
    struct Session: Identifiable {
        let id = UUID()
        var tables: [Table]
        /// Files that couldn't be read at all.
        var problems: [String] = []
    }

    static func normalize(_ header: String) -> String { header.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Text from an exported file: UTF-8 (with or without a byte-order mark), UTF-16, or Windows Latin.
    static func text(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        return String(data: data, encoding: .windowsCP1252)
    }

    /// The separator a file uses: a comma, unless its header line clearly uses semicolons or tabs.
    static func delimiter(_ text: String) -> Unicode.Scalar {
        let header = text.prefix { $0 != "\n" && $0 != "\r" }
        let counts: [(Unicode.Scalar, Int)] = [(",", header.filter { $0 == "," }.count), (";", header.filter { $0 == ";" }.count), ("\t", header.filter { $0 == "\t" }.count)]
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// Splits CSV text into rows of fields. Quoted fields may hold separators, doubled quotes and line breaks.
    static func parseCSV(_ text: String, delimiter: Unicode.Scalar = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var atFieldStart = true
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            atFieldStart = true
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
            row = []
        }
        while i < scalars.count {
            let c = scalars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && atFieldStart {
                quoted = true
                atFieldStart = false
            } else if c == delimiter {
                endField()
            } else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.append(c)
                atFieldStart = false
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Reads one exported file and works out which part of Zoho it came from.
    static func table(fileName: String, data: Data) -> Table {
        guard let text = text(data) else { return Table(fileName: fileName, kind: .unknown, rows: []) }
        let grid = parseCSV(text, delimiter: delimiter(text))
        guard let header = grid.first else { return Table(fileName: fileName, kind: .unknown, rows: []) }
        let keys = header.map(normalize)
        let rows: [Row] = grid.dropFirst().prefix(50_000).map { cells in
            var values: [String: String] = [:]
            for (i, key) in keys.enumerated() where i < cells.count && !key.isEmpty && values[key] == nil {
                let v = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { values[key] = String(v.prefix(4000)) }
            }
            return Row(values: values)
        }
        .filter { !$0.values.isEmpty }
        return Table(fileName: fileName, kind: kind(Set(keys)), rows: rows)
    }

    static func kind(_ h: Set<String>) -> Kind {
        if h.contains("notecontent") || (h.contains("notetitle") && h.contains("parentid")) { return .notes }
        if !h.isDisjoint(with: ["dealname", "potentialname", "opportunityname"]) { return .deals }
        if !h.isDisjoint(with: ["leadstatus", "leadowner", "leadid"]) { return .leads }
        // Zoho Books and Invoice list each customer with a display name, plus a contact person's name.
        if h.contains("displayname") || h.contains("customername") { return .accounts }
        if !h.isDisjoint(with: ["firstname", "lastname", "fullname", "contactowner"]) { return .contacts }
        if !h.isDisjoint(with: ["accountname", "companyname"]) { return .accounts }
        return .unknown
    }

    // MARK: Fields

    private static let phoneKeys = ["phone", "workphone", "officephone", "businessphone", "phonenumber", "mobile", "mobilephone", "cellphone", "homephone", "otherphone"]
    private static let emailKeys = ["email", "emailid", "emailaddress", "primaryemail", "workemail", "secondaryemail"]
    private static let accountLinkIDs = ["accountnameid", "accountid", "companynameid", "companyid"]
    private static let accountLinkNames = ["accountname", "companyname", "company"]

    static func fullName(_ row: Row) -> String {
        let joined = [row.get(["firstname"]), row.get(["lastname"])].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? row.get(["fullname", "contactname", "contactperson", "name"]) ?? "" : joined
    }

    /// "Street, City, ST 12345" from the first set of address columns that has anything.
    static func address(_ row: Row, prefixes: [String]) -> String? {
        for p in prefixes {
            let street = row.get([p + "street", p + "address", p + "streetaddress", p + "address1", p + "addressline1"])
            let city = row.get([p + "city"])
            guard street != nil || city != nil else { continue }
            let state = row.get([p + "state", p + "statecode", p + "province"])
            let zip = row.get(p.isEmpty ? ["zip", "zipcode", "postalcode"] : [p + "code", p + "zip", p + "zipcode", p + "postalcode"])
            let region = [state, zip].compactMap { $0 }.joined(separator: " ")
            return [street, city, region.isEmpty ? nil : region].compactMap { $0 }.joined(separator: ", ")
        }
        return nil
    }

    static func customerType(_ text: String?, name: String) -> CustomerType {
        let t = ((text ?? "") + " " + name).lowercased()
        if t.contains("hoa") || t.contains("association") || t.contains("condominium") { return .hoa }
        if ["government", "municipal", "public", "city of", "county", "township", "village of", "school", "state of", "department"].contains(where: t.contains) { return .publicBid }
        if ["residential", "homeowner", "individual", "residence"].contains(where: t.contains) { return .residential }
        return .commercial
    }

    /// Zoho's deal stages, read loosely, as Stringline's pipeline stages.
    static func stage(_ text: String?) -> Stage {
        let t = (text ?? "").lowercased()
        if t.contains("won") { return .won }
        if t.contains("lost") || t.contains("dead") || t.contains("cancel") || t.contains("declin") { return .lost }
        if ["proposal", "quote", "negotiat", "review", "sent", "bid submitted"].contains(where: t.contains) { return .sent }
        if ["site", "visit", "walk", "meeting", "appointment"].contains(where: t.contains) { return .siteVisit }
        if ["estimat", "needs analysis", "value proposition", "decision", "perception"].contains(where: t.contains) { return .estimating }
        return .lead
    }

    static func services(_ text: String) -> [Service] {
        let t = text.lowercased()
        var out: [Service] = []
        if t.contains("mill") || t.contains("overlay") || t.contains("resurfac") { out.append(.millOverlay) }
        if (t.contains("pave") || t.contains("paving") || t.contains("asphalt")) && !out.contains(.millOverlay) { out.append(.newPaving) }
        if t.contains("patch") || t.contains("pothole") { out.append(.patching) }
        if t.contains("sealcoat") || t.contains("seal coat") || (t.contains("seal") && !t.contains("crack seal")) { out.append(.sealcoat) }
        if t.contains("crack") { out.append(.crackSeal) }
        if t.contains("strip") || t.contains("line paint") { out.append(.striping) }
        if t.contains("concrete") || t.contains("curb") || t.contains("sidewalk") { out.append(.concrete) }
        if t.contains("grading") || t.contains("gravel") { out.append(.grading) }
        return out
    }

    static func date(_ text: String?) -> Date? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "MMM d, yyyy", "MMM dd, yyyy", "dd-MMM-yyyy", "dd MMM yyyy", "MM-dd-yyyy", "dd/MM/yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        // Zoho may add a time ("2026-10-08 14:30:00" or "2026-10-08T14:30:00-04:00"); the day is all that matters.
        var candidates = [raw]
        if let day = raw.split(separator: "T").first, raw.contains("T"), day.contains("-") { candidates.append(String(day)) }
        if let day = raw.split(separator: " ").first, raw.contains(":"), day.contains("-") || day.contains("/") { candidates.append(String(day)) }
        for format in formats {
            formatter.dateFormat = format
            for candidate in candidates {
                if let d = formatter.date(from: candidate) {
                    let year = Calendar.current.component(.year, from: d)
                    if (1990...2100).contains(year) { return d.startOfDay }
                }
            }
        }
        return nil
    }

    static func money(_ text: String?) -> Double? {
        guard let t = text else { return nil }
        let cleaned = t.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(cleaned).flatMap { $0.isFinite ? $0 : nil }
    }

    // MARK: Matching

    static func nameKey(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func phoneKey(_ s: String?) -> String? {
        let digits = (s ?? "").filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    static func emailKey(_ s: String?) -> String? {
        guard let e = s?.trimmingCharacters(in: .whitespaces).lowercased(), e.contains("@") else { return nil }
        return e
    }

    /// Zoho record ids, with or without the old "zcrm_" prefix.
    static func idKey(_ s: String?) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.lowercased().hasPrefix("zcrm_") { t = String(t.dropFirst(5)) }
        return t.isEmpty ? nil : t
    }

    /// The line Stringline adds to imported records, so importing again finds them even after a rename.
    static func marker(_ id: String) -> String { "From Zoho, ID \(id)" }

    static func markedIDs(in notes: String) -> [String] {
        notes.components(separatedBy: "From Zoho, ID ").dropFirst().compactMap { rest in
            rest.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "," }).first.map(String.init)
        }
    }

    // MARK: Planning

    struct Options: Hashable {
        /// Zoho leads also become jobs at the Lead stage, not only customers.
        var leadJobs = true
        /// Customers already in Stringline get their blank fields filled in. Nothing they have is ever overwritten.
        var fillMatches = true
    }

    struct Plan {
        var newCustomers: [Customer] = []
        var filled: [(id: UUID, name: String, patch: CustomerPatch)] = []
        var matched = 0
        var newJobs: [Job] = []
        var notes = 0
        var skipped: [String] = []

        var isEmpty: Bool { newCustomers.isEmpty && filled.isEmpty && newJobs.isEmpty }

        var jobsByStage: [(Stage, Int)] {
            Stage.allCases.compactMap { stage in
                let n = newJobs.filter { $0.stage == stage }.count
                return n > 0 ? (stage, n) : nil
            }
        }

        /// The import as change operations, one per record, in an order that always works:
        /// customers before the jobs that point at them.
        var changes: [ProposedChange] {
            newCustomers.map { ProposedChange([.createCustomer($0)], title: "Customer: \($0.name)", detail: "From Zoho") }
                + filled.map { ProposedChange([.updateCustomer($0.id, $0.patch)], title: "Fill in: \($0.name)", detail: "Blank fields from Zoho") }
                + newJobs.map { ProposedChange([.createJob($0)], title: "Job: \($0.name)", detail: "From Zoho") }
        }
    }

    static func plan(_ tables: [Table], customers existing: [Customer], jobs existingJobs: [Job], options: Options = Options(), today: Date = Date()) -> Plan {
        var builder = Builder(existing: existing, existingJobs: existingJobs, options: options, today: today.startOfDay)
        for table in tables.sorted(by: { $0.kind < $1.kind }) {
            for (n, row) in table.rows.enumerated() {
                let place = "\(table.fileName), row \(n + 2)"
                switch table.kind {
                case .accounts: builder.account(row, place)
                case .contacts: builder.contact(row, place)
                case .leads: builder.lead(row, place)
                case .deals: builder.deal(row, place)
                case .notes: builder.note(row, place)
                case .unknown: break
                }
            }
            if table.kind == .unknown {
                builder.plan.skipped.append("\(table.fileName): not a Zoho export Stringline knows (it looks for columns like Account Name, Last Name or Deal Name).")
            }
        }
        return builder.finish()
    }

    /// Builds a plan one row at a time, matching each person or company to one already found.
    private struct Builder {
        enum Ref: Hashable { case new(Int), existing(UUID) }

        var plan = Plan()
        let existing: [Customer]
        let existingJobs: [Job]
        let options: Options
        let today: Date

        var byID: [String: Ref] = [:]
        var byEmail: [String: Ref] = [:]
        var byPhone: [String: Ref] = [:]
        var byName: [String: Ref] = [:]
        var patches: [UUID: CustomerPatch] = [:]
        var patchOrder: [UUID] = []
        var touched: Set<UUID> = []
        var jobByID: [String: Int] = [:]
        var existingJobIDs: Set<String> = []

        init(existing: [Customer], existingJobs: [Job], options: Options, today: Date) {
            self.existing = existing
            self.existingJobs = existingJobs
            self.options = options
            self.today = today
            for c in existing {
                let ref = Ref.existing(c.id)
                for id in ZohoImport.markedIDs(in: c.notes) { byID[id] = ref }
                if let e = ZohoImport.emailKey(c.email) { byEmail[e] = byEmail[e] ?? ref }
                if let p = ZohoImport.phoneKey(c.phone) { byPhone[p] = byPhone[p] ?? ref }
                let n = ZohoImport.nameKey(c.name)
                if !n.isEmpty { byName[n] = byName[n] ?? ref }
            }
            for j in existingJobs { existingJobIDs.formUnion(ZohoImport.markedIDs(in: j.notes)) }
        }

        func find(id: String?, email: String?, phone: String?, name: String?) -> Ref? {
            if let id, let r = byID[id] { return r }
            if let e = ZohoImport.emailKey(email), let r = byEmail[e] { return r }
            if let p = ZohoImport.phoneKey(phone), let r = byPhone[p] { return r }
            if let n = name.map(ZohoImport.nameKey), !n.isEmpty, let r = byName[n] { return r }
            return nil
        }

        mutating func remember(_ ref: Ref, id: String?, email: String?, phone: String?, name: String?) {
            if let id { byID[id] = ref }
            if let e = ZohoImport.emailKey(email), byEmail[e] == nil { byEmail[e] = ref }
            if let p = ZohoImport.phoneKey(phone), byPhone[p] == nil { byPhone[p] = ref }
            if let n = name.map(ZohoImport.nameKey), !n.isEmpty, byName[n] == nil { byName[n] = ref }
        }

        mutating func create(_ c: Customer, id: String?) -> Ref {
            var c = c
            if let id { c.notes = Self.join(c.notes, ZohoImport.marker(id)) }
            plan.newCustomers.append(c)
            let ref = Ref.new(plan.newCustomers.count - 1)
            remember(ref, id: id, email: c.email, phone: c.phone, name: c.name)
            return ref
        }

        static func join(_ a: String, _ b: String) -> String {
            let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !b.isEmpty else { return a }
            return a.isEmpty ? b : a + "\n\n" + b
        }

        func customer(_ ref: Ref) -> Customer? {
            switch ref {
            case .new(let i): return plan.newCustomers[i]
            case .existing(let id):
                guard var c = existing.first(where: { $0.id == id }) else { return nil }
                if let p = patches[id] {
                    if let v = p.contact { c.contact = v }
                    if let v = p.phone { c.phone = v }
                    if let v = p.email { c.email = v }
                    if let v = p.address { c.address = v }
                    if let v = p.addNote { c.notes = Self.join(c.notes, v) }
                }
                return c
            }
        }

        /// Fills only what's blank. An existing customer's own details are never replaced.
        mutating func fill(_ ref: Ref, contact: String? = nil, phone: String? = nil, email: String? = nil, address: String? = nil, note: String? = nil) {
            func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
            switch ref {
            case .new(let i):
                var c = plan.newCustomers[i]
                if let v = contact, blank(c.contact) { c.contact = v }
                if let v = phone, blank(c.phone) { c.phone = v }
                if let v = email, blank(c.email) { c.email = v }
                if let v = address, blank(c.address) { c.address = v }
                if let v = note, !c.notes.contains(v) { c.notes = Self.join(c.notes, v) }
                plan.newCustomers[i] = c
            case .existing(let id):
                if !touched.contains(id) {
                    touched.insert(id)
                    plan.matched += 1
                }
                guard options.fillMatches, let current = customer(ref) else { return }
                var p = patches[id] ?? CustomerPatch()
                if let v = contact, blank(current.contact) { p.contact = v }
                if let v = phone, blank(current.phone) { p.phone = v }
                if let v = email, blank(current.email) { p.email = v }
                if let v = address, blank(current.address) { p.address = v }
                if let v = note, !current.notes.contains(v) { p.addNote = Self.join(p.addNote ?? "", v) }
                if p != CustomerPatch() {
                    if patches[id] == nil { patchOrder.append(id) }
                    patches[id] = p
                }
            }
        }

        func customerID(_ ref: Ref?) -> UUID? {
            switch ref {
            case .new(let i): plan.newCustomers[i].id
            case .existing(let id): id
            case nil: nil
            }
        }

        // MARK: Rows

        mutating func account(_ row: Row, _ place: String) {
            guard let name = row.get(["accountname", "companyname", "displayname", "customername", "name"]) else {
                plan.skipped.append("\(place): no company name.")
                return
            }
            if let type = row.get(["contacttype"])?.lowercased(), type.contains("vendor") {
                plan.skipped.append("\(place): \(name) is a vendor, not a customer.")
                return
            }
            let id = ZohoImport.idKey(row.get(["recordid", "id", "accountid", "companyid", "customerid", "contactid"]))
            let person = ZohoImport.fullName(row)
            let phone = row.get(ZohoImport.phoneKeys), email = row.get(ZohoImport.emailKeys)
            let address = ZohoImport.address(row, prefixes: ["billing", "mailing", "shipping", ""])
            let website = row.get(["website"]).map { "Website: \($0)" }
            let note = [row.get(["description", "notes"]), website].compactMap { $0 }.joined(separator: "\n")
            if let ref = find(id: id, email: email, phone: phone, name: name) {
                fill(ref, contact: person.isEmpty ? nil : person, phone: phone, email: email, address: address, note: note.isEmpty ? nil : note)
                remember(ref, id: id, email: email, phone: phone, name: name)
                return
            }
            var c = Customer()
            c.name = name
            c.contact = person == name ? "" : person
            c.phone = phone ?? ""
            c.email = email ?? ""
            c.address = address ?? ""
            c.type = ZohoImport.customerType(row.get(["accounttype", "type", "industry", "customertype", "customersubtype"]), name: name)
            c.notes = note
            _ = create(c, id: id)
        }

        mutating func contact(_ row: Row, _ place: String) {
            let person = ZohoImport.fullName(row)
            let phone = row.get(ZohoImport.phoneKeys), email = row.get(ZohoImport.emailKeys)
            guard !person.isEmpty || email != nil else {
                plan.skipped.append("\(place): no name or email.")
                return
            }
            let id = ZohoImport.idKey(row.get(["recordid", "id", "contactid"]))
            let address = ZohoImport.address(row, prefixes: ["mailing", "billing", "other", ""])
            let description = row.get(["description"])
            let companyID = ZohoImport.idKey(row.get(ZohoImport.accountLinkIDs))
            let companyName = row.get(ZohoImport.accountLinkNames)
            if companyID != nil || companyName != nil {
                var ref = companyID.flatMap { byID[$0] } ?? find(id: nil, email: nil, phone: nil, name: companyName)
                if ref == nil, let companyName {
                    var c = Customer()
                    c.name = companyName
                    c.type = ZohoImport.customerType(nil, name: companyName)
                    ref = create(c, id: companyID)
                }
                if let ref {
                    let current = customer(ref)
                    let hasContact = !(current?.contact.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                    if !hasContact || current?.contact == person {
                        fill(ref, contact: person.isEmpty ? nil : person, phone: phone, email: email, address: address, note: description)
                    } else {
                        // Someone else at the company: noted, but their phone and email don't become the company's.
                        let line = "Also: " + [person, phone, email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        fill(ref, note: line)
                    }
                    if let id { byID[id] = ref }
                    return
                }
            }
            if let ref = find(id: id, email: email, phone: phone, name: person) {
                fill(ref, phone: phone, email: email, address: address, note: description)
                remember(ref, id: id, email: email, phone: phone, name: person)
                return
            }
            var c = Customer()
            c.name = person.isEmpty ? (email ?? "Zoho contact") : person
            c.type = .residential
            c.phone = phone ?? ""
            c.email = email ?? ""
            c.address = address ?? ""
            c.notes = description ?? ""
            _ = create(c, id: id)
        }

        mutating func lead(_ row: Row, _ place: String) {
            let company = row.get(["company", "companyname"])
            let person = ZohoImport.fullName(row)
            let name = company ?? person
            guard !name.isEmpty else {
                plan.skipped.append("\(place): no name or company.")
                return
            }
            let id = ZohoImport.idKey(row.get(["recordid", "id", "leadid"]))
            let phone = row.get(ZohoImport.phoneKeys), email = row.get(ZohoImport.emailKeys)
            let address = ZohoImport.address(row, prefixes: ["", "mailing", "billing"])
            let status = row.get(["leadstatus", "status"])
            let source = row.get(["leadsource", "source"])
            let summary = ["Zoho lead", status.map { "status: \($0)" }, source.map { "source: \($0)" }].compactMap { $0 }.joined(separator: " · ")
            let ref: Ref
            if let found = find(id: id, email: email, phone: phone, name: name) {
                fill(found, contact: company != nil && !person.isEmpty ? person : nil, phone: phone, email: email, address: address, note: summary)
                remember(found, id: id, email: email, phone: phone, name: name)
                ref = found
            } else {
                var c = Customer()
                c.name = name
                c.contact = company != nil ? person : ""
                c.type = company != nil ? ZohoImport.customerType(row.get(["industry"]), name: name) : .residential
                c.phone = phone ?? ""
                c.email = email ?? ""
                c.address = address ?? ""
                c.notes = Self.join(summary, row.get(["description"]) ?? "")
                ref = create(c, id: id)
            }
            guard options.leadJobs else { return }
            let s = (status ?? "").lowercased()
            if s.contains("junk") || s.contains("lost") || s.contains("not qualified") {
                plan.skipped.append("\(place): \(name) is marked \(status ?? "") in Zoho, so no job was made.")
                return
            }
            if let id, existingJobIDs.contains(id) { return }
            var job = Job()
            job.name = name
            job.customerID = customerID(ref)
            job.address = address ?? ""
            job.type = customer(ref)?.type ?? .commercial
            job.stage = .lead
            job.source = source ?? "Zoho"
            job.services = ZohoImport.services([name, row.get(["description"]) ?? ""].joined(separator: " "))
            job.notes = Self.join(row.get(["description"]) ?? "", id.map(ZohoImport.marker) ?? "")
            guard !alreadyHas(job) else { return }
            plan.newJobs.append(job)
            if let id { jobByID[id] = plan.newJobs.count - 1 }
        }

        mutating func deal(_ row: Row, _ place: String) {
            guard let name = row.get(["dealname", "potentialname", "opportunityname"]) else {
                plan.skipped.append("\(place): no deal name.")
                return
            }
            let id = ZohoImport.idKey(row.get(["recordid", "id", "dealid", "potentialid"]))
            if let id, existingJobIDs.contains(id) {
                plan.skipped.append("\(place): \(name) is already in Stringline.")
                return
            }
            var ref: Ref?
            let companyID = ZohoImport.idKey(row.get(ZohoImport.accountLinkIDs))
            let companyName = row.get(ZohoImport.accountLinkNames)
            ref = companyID.flatMap { byID[$0] } ?? companyName.flatMap { find(id: nil, email: nil, phone: nil, name: $0) }
            if ref == nil {
                let contactID = ZohoImport.idKey(row.get(["contactnameid", "contactid"]))
                let contactName = row.get(["contactname", "contact"])
                ref = contactID.flatMap { byID[$0] } ?? contactName.flatMap { find(id: nil, email: nil, phone: nil, name: $0) }
                if ref == nil, let contactName {
                    var c = Customer()
                    c.name = contactName
                    c.type = .residential
                    ref = create(c, id: contactID)
                }
            }
            if ref == nil, let companyName {
                var c = Customer()
                c.name = companyName
                c.type = ZohoImport.customerType(nil, name: companyName)
                ref = create(c, id: companyID)
            }
            let stage = ZohoImport.stage(row.get(["stage", "dealstage", "pipelinestage", "status"]))
            let closing = ZohoImport.date(row.get(["closingdate", "closedate", "expectedclosedate", "expectedclosingdate"]))
            let amount = ZohoImport.money(row.get(["amount", "dealamount", "expectedrevenue", "value"]))
            let description = row.get(["description"])
            var job = Job()
            job.name = name
            job.customerID = customerID(ref)
            let owner = ref.flatMap(customer)
            job.type = owner?.type ?? .commercial
            job.address = ZohoImport.address(row, prefixes: ["site", "job", "property", "", "shipping"])
                ?? (owner?.type == .residential ? owner?.address ?? "" : "")
            job.stage = stage
            job.source = row.get(["leadsource", "source"]) ?? "Zoho"
            job.services = ZohoImport.services([name, description ?? "", row.get(["type", "dealtype"]) ?? ""].joined(separator: " "))
            if let closing, stage != .won, stage != .lost { job.bidDue = closing }
            if stage == .lost { job.lostReason = row.get(["reasonforloss", "lossreason", "lostreason"]) ?? "" }
            let amountLine = amount.map { "Zoho amount: " + Fmt.dollars(Int(($0 * 100).rounded())) }
            let closingLine = closing.flatMap { d in stage == .won || stage == .lost ? "Closed in Zoho: \(Fmt.dayYear(d))" : nil }
            job.notes = [description, amountLine, closingLine, id.map(ZohoImport.marker)].compactMap { $0 }.joined(separator: "\n")
            guard !alreadyHas(job) else {
                plan.skipped.append("\(place): \(name) is already in Stringline.")
                return
            }
            plan.newJobs.append(job)
            if let id { jobByID[id] = plan.newJobs.count - 1 }
        }

        /// A job with the same name for the same customer is already there (or already planned).
        func alreadyHas(_ job: Job) -> Bool {
            let key = ZohoImport.nameKey(job.name)
            let same = { (other: Job) in ZohoImport.nameKey(other.name) == key && other.customerID == job.customerID }
            return existingJobs.contains(where: same) || plan.newJobs.contains(where: same)
        }

        mutating func note(_ row: Row, _ place: String) {
            let content = row.get(["notecontent", "content", "note", "notes"])
            let title = row.get(["notetitle", "title"])
            guard content != nil || title != nil else {
                plan.skipped.append("\(place): an empty note.")
                return
            }
            let text = String([title, content].compactMap { $0 }.joined(separator: ": ").prefix(3000))
            let parent = ZohoImport.idKey(row.get(["parentid", "parentidid", "relatedtoid", "parentrecordid"]))
            let parentName = row.get(["parentname", "relatedto", "parent"])
            if let parent, let j = jobByID[parent] {
                plan.newJobs[j].notes = Self.join(plan.newJobs[j].notes, text)
            } else if let parent, let ref = byID[parent] {
                fill(ref, note: text)
            } else if let parentName, let j = plan.newJobs.firstIndex(where: { ZohoImport.nameKey($0.name) == ZohoImport.nameKey(parentName) }) {
                plan.newJobs[j].notes = Self.join(plan.newJobs[j].notes, text)
            } else if let parentName, let ref = find(id: nil, email: nil, phone: nil, name: parentName) {
                fill(ref, note: text)
            } else {
                plan.skipped.append("\(place): a note for a record that isn't in these files.")
                return
            }
            plan.notes += 1
        }

        mutating func finish() -> Plan {
            plan.filled = patchOrder.compactMap { id in
                guard let p = patches[id], let c = existing.first(where: { $0.id == id }) else { return nil }
                return (id, c.name, p)
            }
            return plan
        }
    }
}
