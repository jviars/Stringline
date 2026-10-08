import Foundation

/// Sample exports shaped like Zoho CRM's (Setup › Data Administration › Export).
enum ZohoSamples {
    static let accounts = """
    "Record Id","Account Owner","Account Name","Phone","Website","Account Type","Billing Street","Billing City","Billing State","Billing Code","Description"
    "zcrm_4876876000000111","Pat","Ridge Property Group","(614) 555-0100","ridgepg.com","Customer","100 Ridge Rd","Columbus","OH","43215","Manages 12 lots"
    "4876876000000112","Pat","Cedar Lane HOA","614-555-0200","","Homeowners Association","1 Cedar Ln","Dublin","OH","43017",""
    "4876876000000113","Pat","City of Westerville","","","Government","","Westerville","OH","",""
    "4876876000000114","Pat","","555","","","","","","",""
    """

    static let contacts = """
    "Record Id","Contact Owner","First Name","Last Name","Account Name","Account Name.id","Email","Phone","Mobile","Mailing Street","Mailing City","Mailing State","Mailing Zip","Description"
    "4876876000000211","Pat","Dana","Whitfield","Ridge Property Group","4876876000000111","dana@ridgepg.com","","614-555-0101","","","","",""
    "4876876000000212","Pat","Sam","Lee","Ridge Property Group","4876876000000111","sam@ridgepg.com","614-555-0102","","","","","",""
    "4876876000000213","Pat","Jo","Homeowner","","","jo@example.com","614-555-0300","","22 Elm St","Columbus","OH","43210","Wants the driveway sealed"
    "4876876000000214","Pat","Kim","Old","Acme Corp","","kim@acme.com","","","","","","",""
    """

    static let deals = """
    "Record Id","Deal Name","Account Name","Account Name.id","Contact Name","Stage","Closing Date","Amount","Lead Source","Description","Type"
    "4876876000000311","Maple Ridge Plaza mill & overlay","Ridge Property Group","4876876000000111","Dana Whitfield","Proposal/Price Quote","2026-11-15","95,570.69","Referral","Main lot","New Business"
    "4876876000000312","Cedar Lane sealcoat","Cedar Lane HOA","4876876000000112","","Closed Won","10/01/2026","$12,400.00","","",""
    "4876876000000313","Library lot patching","City of Westerville","","","Closed Lost","Sep 12, 2026","8000","Bid board","Lost on price",""
    "4876876000000314","Elm St driveway","","","Jo Homeowner","Qualification","","","","Driveway",""
    ,,,,,,,,,,
    "4876876000000315","","Ridge Property Group","","","Qualification","","","","",""
    """

    static let leads = """
    "Record Id","Lead Owner","Company","First Name","Last Name","Email","Phone","Lead Source","Lead Status","Street","City","State","Zip Code","Description"
    "4876876000000411","Pat","Hillcrest Church","Mary","Ames","mary@hillcrest.org","614-555-0400","Website","Contacted","5 Hill St","Columbus","OH","43221","Church lot, potholes by the doors"
    "4876876000000412","Pat","","Spam","Bot","spam@example.com","","","Junk Lead","","","","",""
    """

    static let notes = """
    "Note Id","Note Title","Note Content","Parent ID","Parent Module"
    "1","Call","Wants it done before Thanksgiving","4876876000000311","Deals"
    "2","","Gate code 1234","4876876000000112","Accounts"
    "3","Orphan","???","999","Accounts"
    """

    static func tables() -> [ZohoImport.Table] {
        [("Accounts_2026.csv", accounts), ("Contacts_2026.csv", contacts), ("Deals_2026.csv", deals),
         ("Leads_2026.csv", leads), ("Notes_2026.csv", notes)].map { ZohoImport.table(fileName: $0.0, data: Data($0.1.utf8)) }
    }
}

func runZohoImportTests() {
    MainActor.assumeIsolated {
        print("\n-- Import from Zoho")
        let grid = ZohoImport.parseCSV("name,notes\r\n\"Smith, Jo\",\"said \"\"hi\"\"\nnext line\"\r\n\r\nx,y")
        check("CSV: quoted commas, doubled quotes, line breaks inside quotes, CRLF and blank lines",
              grid == [["name", "notes"], ["Smith, Jo", "said \"hi\"\nnext line"], ["x", "y"]], "\(grid)")
        let bom = ZohoImport.table(fileName: "Accounts.csv", data: Data([0xEF, 0xBB, 0xBF]) + Data("Account Name;Phone\nRidge;555-0100".utf8))
        check("A byte-order mark and semicolon separators are handled", bom.kind == .accounts && bom.rows.first?.get(["accountname"]) == "Ridge" && bom.rows.first?.get(["phone"]) == "555-0100")
        let utf16 = ZohoImport.table(fileName: "c.csv", data: "First Name,Last Name\nJosé,Núñez".data(using: .utf16)!)
        check("UTF-16 exports read correctly", utf16.kind == .contacts && ZohoImport.fullName(utf16.rows[0]) == "José Núñez")

        let tables = ZohoSamples.tables()
        check("Each export is recognized from its columns: accounts, contacts, deals, leads and notes",
              tables.map(\.kind) == [.accounts, .contacts, .deals, .leads, .notes]
                && ZohoImport.table(fileName: "x.csv", data: Data("foo,bar\n1,2".utf8)).kind == .unknown)
        check("Bigin companies and Zoho Books customers are recognized too",
              ZohoImport.kind(["companyname", "phone"]) == .accounts && ZohoImport.kind(["displayname", "companyname", "firstname", "lastname"]) == .accounts
                && ZohoImport.kind(["firstname", "lastname", "companyname"]) == .contacts)

        check("Zoho stages map to the pipeline",
              ZohoImport.stage("Closed Won") == .won && ZohoImport.stage("Closed Lost to Competition") == .lost && ZohoImport.stage("Proposal/Price Quote") == .sent
                && ZohoImport.stage("Negotiation/Review") == .sent && ZohoImport.stage("Needs Analysis") == .estimating && ZohoImport.stage("Qualification") == .lead
                && ZohoImport.stage(nil) == .lead)
        let iso = ZohoImport.date("2026-11-15"), us = ZohoImport.date("10/01/2026"), word = ZohoImport.date("Sep 12, 2026"), timed = ZohoImport.date("2026-11-15 14:30:00")
        check("Dates read in Zoho's formats", iso != nil && iso == timed && us.map { Calendar.current.component(.month, from: $0) } == 10
              && word.map { Calendar.current.component(.day, from: $0) } == 12 && ZohoImport.date("someday") == nil && ZohoImport.date("01/01/1700") == nil)
        check("Amounts read with dollar signs and commas", ZohoImport.money("$12,400.00") == 12_400 && ZohoImport.money("95,570.69") == 95_570.69)
        check("Services are guessed from the deal name",
              ZohoImport.services("Lot mill & overlay") == [.millOverlay] && ZohoImport.services("Crack seal and sealcoat") == [.sealcoat, .crackSeal]
                && ZohoImport.services("Pothole patching") == [.patching])

        // Someone who already has Ridge Property Group in Stringline.
        var ridge = Customer()
        ridge.name = "Ridge Property Group"
        ridge.contact = "Dana Whitfield"
        ridge.email = "office@ridgepg.com"
        let data = FakeData()
        data.customers = [ridge]
        let plan = ZohoImport.plan(tables, customers: data.customers, jobs: data.jobs)
        let names = Set(plan.newCustomers.map(\.name))
        check("Companies, people without a company, and leads become customers; one you already have isn't added again",
              names == ["Cedar Lane HOA", "City of Westerville", "Jo Homeowner", "Acme Corp", "Hillcrest Church", "Spam Bot"], names.sorted().description)
        let byName = Dictionary(plan.newCustomers.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        check("Customer types come from Zoho's account type", byName["Cedar Lane HOA"]?.type == .hoa && byName["City of Westerville"]?.type == .publicBid
              && byName["Jo Homeowner"]?.type == .residential && byName["Hillcrest Church"]?.type == .commercial)
        check("Contacts become the company's contact person, with phone, email and address",
              byName["Acme Corp"]?.contact == "Kim Old" && byName["Acme Corp"]?.email == "kim@acme.com"
                && byName["Hillcrest Church"]?.contact == "Mary Ames" && byName["Jo Homeowner"]?.address == "22 Elm St, Columbus, OH 43210"
                && byName["Cedar Lane HOA"]?.address == "1 Cedar Ln, Dublin, OH 43017" && (byName["Cedar Lane HOA"]?.notes ?? "").contains("Gate code 1234"))
        let fill = plan.filled.first
        check("The customer you already have only gets its blanks filled: nothing is overwritten",
              plan.matched == 1 && plan.filled.count == 1 && fill?.id == ridge.id && fill?.patch.phone == "(614) 555-0100"
                && fill?.patch.address == "100 Ridge Rd, Columbus, OH 43215" && fill?.patch.email == nil && fill?.patch.contact == nil
                && (fill?.patch.addNote ?? "").contains("Also: Sam Lee"), "\(String(describing: fill?.patch))")

        let jobs = Dictionary(plan.newJobs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let maple = jobs["Maple Ridge Plaza mill & overlay"]
        check("Deals become jobs at the right stage, for the right customer, with the amount and closing date",
              maple?.stage == .sent && maple?.customerID == ridge.id && maple?.bidDue == ZohoImport.date("2026-11-15") && maple?.services == [.millOverlay]
                && (maple?.notes ?? "").contains("Zoho amount: $95,570.69") && (maple?.notes ?? "").contains("Wants it done before Thanksgiving")
                && jobs["Cedar Lane sealcoat"]?.stage == .won && jobs["Cedar Lane sealcoat"]?.customerID == byName["Cedar Lane HOA"]?.id
                && jobs["Library lot patching"]?.stage == .lost && jobs["Library lot patching"]?.services == [.patching],
              plan.newJobs.map { "\($0.name) \($0.stage)" }.description)
        check("A deal with only a contact goes to that person, at their address",
              jobs["Elm St driveway"]?.customerID == byName["Jo Homeowner"]?.id && jobs["Elm St driveway"]?.address == "22 Elm St, Columbus, OH 43210")
        check("Leads become Lead-stage jobs, except junk", jobs["Hillcrest Church"]?.stage == .lead && jobs["Hillcrest Church"]?.address == "5 Hill St, Columbus, OH 43221"
              && jobs["Spam Bot"] == nil && plan.newJobs.count == 5)
        check("Notes land on their customer or job; rows that can't be used are listed with the reason",
              plan.notes == 2 && plan.skipped.contains { $0.contains("no company name") } && plan.skipped.contains { $0.contains("no deal name") }
                && plan.skipped.contains { $0.contains("Junk") } && plan.skipped.contains { $0.contains("isn't in these files") }, plan.skipped.description)

        let fresh = ZohoImport.plan(tables, customers: [], jobs: []).newCustomers.first { $0.name == "Ridge Property Group" }
        check("A company's first contact becomes its contact person; others are noted without taking over its phone or email",
              fresh?.contact == "Dana Whitfield" && fresh?.email == "dana@ridgepg.com" && fresh?.phone == "(614) 555-0100"
                && (fresh?.notes ?? "").contains("Also: Sam Lee · 614-555-0102 · sam@ridgepg.com"), "\(String(describing: fresh))")

        let replay = DraftState.replay(plan.changes.flatMap(\.ops), base: data)
        check("The import replays cleanly as ordinary changes (what Apply runs)", replay.failures.isEmpty && replay.state.newJobs.count == 5)

        // Import, then import the same files again.
        data.customers = replay.state.allCustomers(data)
        data.jobs = replay.state.allJobs(data)
        let again = ZohoImport.plan(tables, customers: data.customers, jobs: data.jobs)
        check("Importing the same files again adds nothing and changes nothing",
              again.newCustomers.isEmpty && again.newJobs.isEmpty && again.filled.isEmpty, "\(again.newCustomers.map(\.name)) \(again.newJobs.map(\.name)) \(again.filled.map(\.name))")

        var renamed = data.customers
        if let i = renamed.firstIndex(where: { $0.name == "Cedar Lane HOA" }) { renamed[i].name = "Cedar Lane Homeowners" }
        check("A customer renamed in Stringline is still recognized, by its Zoho ID",
              !ZohoImport.plan(tables, customers: renamed, jobs: data.jobs).newCustomers.contains { $0.name == "Cedar Lane HOA" })

        var options = ZohoImport.Options()
        options.leadJobs = false
        options.fillMatches = false
        let cautious = ZohoImport.plan(tables, customers: [ridge], jobs: [], options: options)
        check("Options: no jobs from leads, and customers you have left exactly as they are",
              cautious.filled.isEmpty && cautious.matched == 1 && !cautious.newJobs.contains { $0.name == "Hillcrest Church" })

        let questions = ["How do I import my customers from Zoho?", "can I bring my deals over from zoho crm", "move everything from Bigin into stringline",
                         "How do I get my Zoho Books customers in here?", "import contacts csv"]
        let firsts = questions.map { KnowledgeBase.search($0).first?.id ?? "nothing" }
        check("The assistant's help search finds the Zoho import article for the ways people ask", firsts.allSatisfy { $0 == "import-zoho" }, firsts.description)
        check("The help points at both Import from Zoho buttons",
              KnowledgeBase.article("import-zoho")?.spots == ["customers.zohoImport", "settings.zohoImport"]
                && KnowledgeBase.spot("customers.zohoImport") != nil && KnowledgeBase.spot("settings.zohoImport") != nil)

        var rng = SeededRandom(seed: 99)
        let alphabet = Array("ab,\"\n\r;\t é")
        var survived = true
        for _ in 0..<800 {
            let header = ["Account Name", "Deal Name", "First Name", "Note Content", "Stage", "Parent ID", "Record Id"].shuffled(using: &rng).prefix(Int.random(in: 1...7, using: &rng)).joined(separator: ",")
            let body = String((0..<Int.random(in: 0...400, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
            let table = ZohoImport.table(fileName: "fuzz.csv", data: Data((header + "\n" + body).utf8))
            let p = ZohoImport.plan([table], customers: data.customers, jobs: data.jobs)
            if !DraftState.replay(p.changes.flatMap(\.ops), base: data).failures.isEmpty { survived = false }
        }
        check("800 scrambled files: nothing crashes, and every plan still applies cleanly", survived)
    }
}
