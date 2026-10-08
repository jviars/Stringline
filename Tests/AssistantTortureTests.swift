import Foundation
import Security

func runAssistantTortureTests() {
    print("\n-- Assistant: knowledge base")
    let ids = KnowledgeBase.articles.map(\.id)
    check("Help articles have unique ids", Set(ids).count == ids.count)
    let validScreens: Set<String> = ["today", "pipeline", "measure", "jobs", "schedule", "customers", "invoices", "learn"]
    let badArticles = KnowledgeBase.articles.filter { a in
        let screenOK = a.screen.map { s in validScreens.contains(s) || s.hasPrefix("job:") || s.hasPrefix("settings:") } ?? true
        return a.steps.count < 2 || a.summary.isEmpty || a.keywords.isEmpty || !screenOK || a.spots.contains { KnowledgeBase.spot($0) == nil }
    }
    check("Every help article has steps, keywords, a real screen and real spots", badArticles.isEmpty, badArticles.map(\.id).description)
    let sections: Set<String> = ["company", "rates", "weather", "proposal", "data", "crews", "assistant"]
    let tabs: Set<String> = ["overview", "measure", "estimate", "schedule", "logs", "photos", "invoice"]
    let badTargets = KnowledgeBase.articles.compactMap(\.screen).filter { s in
        (s.hasPrefix("settings:") && !sections.contains(String(s.dropFirst(9)))) || (s.hasPrefix("job:") && !tabs.contains(String(s.dropFirst(4))))
    }
    check("Every help article's Take me there points at a real tab or Settings section", badTargets.isEmpty, badTargets.description)
    let unusedSpots = KnowledgeBase.spots.filter { spot in !KnowledgeBase.articles.contains { $0.spots.contains(spot.id) } && !spot.id.hasPrefix("sidebar.") }
    check("Every on-screen spot is used by a help article", unusedSpots.isEmpty, unusedSpots.map(\.id).description)

    // Every spot the help can point at is really marked in the app's views, and the other way round.
    let viewsFolder = URL(fileURLWithPath: "Stringline/Views")
    var marked = Set<String>()
    if let files = FileManager.default.enumerator(at: viewsFolder, includingPropertiesForKeys: nil) {
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let regex = try! NSRegularExpression(pattern: #"helpSpot\("([^"]+)"\)"#)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range(at: 1), in: text) { marked.insert(String(text[r])) }
            }
        }
    }
    let known = Set(KnowledgeBase.spots.map(\.id))
    check("Every help spot is marked in the app, and every mark is a help spot",
          marked == known, "missing in views: \(known.subtracting(marked).sorted()), unknown: \(marked.subtracting(known).sorted())")

    let questions: [(String, String)] = [
        ("How do I measure a parking lot?", "measure-lot"), ("how do i cut out an island", "measure-cutout"),
        ("Where do I change my prices?", "rates"), ("how do I add option B", "estimate-options"),
        ("how do I send the proposal to the customer", "proposal-send"), ("change my profit margin", "estimate-markup"),
        ("How do I put a job on the schedule", "schedule-job"), ("move a crew day because of rain", "schedule-change"),
        ("where is the 811 ticket", "ticket-811"), ("how do I bill the customer", "invoice-create"),
        ("mark an invoice paid", "invoice-paid"), ("add a new lead", "new-lead"), ("I deleted a job by mistake", "delete-job"),
        ("how do I get back an old version", "history-restore"), ("where is my data saved", "data-folder"),
        ("add a crew", "crews"), ("set up my logo", "company"), ("how do I connect chatgpt", "assistant-connect"),
        ("attach a photo", "assistant-attach"), ("can it search the internet", "assistant-web"),
        ("how do I talk to it with my voice", "assistant-voice"), ("get directions to a job", "directions"),
        ("send the schedule to my calendar", "calendar"), ("how do I log tons", "daily-logs"),
        ("lines for striping and counting stalls", "measure-lines-counts"), ("the satellite photo is old", "measure-imagery"),
        ("follow up on a bid", "follow-up"), ("mark a bid lost", "lost-bid"), ("where am I lost", "find-your-way"),
        ("search for a customer", "search"), ("what is the weather rule", "weather-rules"), ("use it on two Macs", "two-macs"),
    ]
    let misses = questions.filter { q, id in !KnowledgeBase.search(q, limit: 2).map(\.id).contains(id) }
    check("Help search finds the right article in its top two for \(questions.count) everyday questions", misses.isEmpty,
          misses.map { "\($0.0) → \(KnowledgeBase.search($0.0, limit: 2).map(\.id))" }.joined(separator: "; "))
    check("Nonsense finds nothing instead of a wrong answer", KnowledgeBase.search("purple elephant xylophone").isEmpty && KnowledgeBase.search("").isEmpty)

    print("\n-- Assistant: markdown, chat files, sources")
    let md = Markdown.blocks("Here's how:\n\n1. Click **Estimate**.\n2. Click **Add option**.\n   It's at the top.\n\n- One\n- Two\n\n## Tip\n> Quote\n```\ncode\n```\n---")
    check("Replies are split into steps, lists, headings, quotes and code",
          md == [.paragraph("Here's how:"), .numbered(start: 1, ["Click **Estimate**.", "Click **Add option**. It's at the top."]),
                 .bullets(["One", "Two"]), .heading(2, "Tip"), .quote("Quote"), .code("code"), .rule], "\(md)")
    check("Plain text drops the markdown marks", Markdown.plain("1. Click **Estimate**.\n2. Then `Add`.") == "1. Click Estimate.\n2. Then Add.")
    var rng = SeededRandom(seed: 7)
    let alphabet = Array("abc 123\n#*->`_.)[]()!\u{1F6E3}é\t")
    var survived = true
    for _ in 0..<3000 {
        let text = String((0..<Int.random(in: 0...300, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
        let blocks = Markdown.blocks(text)
        if text.contains(where: { $0.isLetter }) && blocks.isEmpty { survived = false }
        _ = Markdown.plain(text)
    }
    check("3,000 random replies render without crashing or losing text", survived)

    let citations = Source.citations(in: [["type": "message", "content": [["type": "output_text", "text": "x", "annotations": [
        ["type": "url_citation", "url": "https://example.com/a", "title": "A"], ["type": "url_citation", "url": "https://example.com/a", "title": "dup"],
        ["type": "url_citation", "url": "javascript:alert(1)", "title": "bad"], ["type": "file_citation", "file_id": "f"]]]]]])
    check("Web sources are collected once each, and only web links can be opened",
          citations.count == 2 && citations[0].safeURL != nil && citations[1].safeURL == nil && Source(url: "file:///etc/passwd", title: "").safeURL == nil)

    let oldPrefs = try? JSONDecoder().decode(AssistantPrefs.self, from: Data(#"{"defaultMode":"action","shareContact":true,"areas":["jobs"]}"#.utf8))
    check("Preferences saved by an older version keep their settings and get the new defaults",
          oldPrefs?.defaultMode == .action && oldPrefs?.shareContact == true && oldPrefs?.areas == [.jobs] && oldPrefs?.webSearch == true && oldPrefs?.keepHistory == true)

    let archiveFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stringline-chats-\(UUID().uuidString)")
    let archive = ChatArchive(folder: archiveFolder, keep: 5)
    var lastID = UUID()
    for i in 0..<8 {
        let chat = SavedChat(id: UUID(), title: "Chat \(i)", created: .now, updated: Date().addingTimeInterval(Double(i)), mode: .chat,
                             items: [.user("Q\(i)", []), .reply("A", [Source(url: "https://a.com", title: "a")]), .run(RunLog()),
                                     .changes(title: "1 change", lines: ["✓ x"], state: "Applied")],
                             history: [["role": "user", "content": .string("Q\(i)")]])
        try? archive.save(chat)
        lastID = chat.id
    }
    let listed = archive.list()
    let perms = (try? FileManager.default.attributesOfItem(atPath: archiveFolder.appendingPathComponent("\(lastID.uuidString).json").path)[.posixPermissions] as? Int) ?? 0
    check("Saved chats round-trip, newest first, and only the newest are kept", listed.count == 5 && listed.first?.id == lastID
          && archive.load(lastID)?.items.count == 4 && archive.load(lastID)?.history.count == 1, "\(listed.count)")
    check("Saved chat files are readable only by you (0600)", perms == 0o600, String(perms, radix: 8))
    archive.deleteAll()
    check("Deleting all chats leaves none", archive.list().isEmpty)
    try? FileManager.default.removeItem(at: archiveFolder)

    print("\n-- Assistant: torture")
    // Streams cut into random pieces, with garbage lines mixed in, still read the same.
    let message: JSONValue = ["type": "message", "id": "m1", "role": "assistant", "content": [["type": "output_text", "text": "Hello there, friend"]]]
    let lines = ["data: " + (["type": "response.output_text.delta", "item_id": "m1", "delta": "Hello "] as JSONValue).compactString,
                 "data: " + (["type": "response.output_text.delta", "item_id": "m1", "delta": "there, friend"] as JSONValue).compactString,
                 "data: " + (["type": "response.completed", "response": ["output": [message]]] as JSONValue).compactString]
    var streamOK = true
    for _ in 0..<500 {
        var acc = ResponseAccumulator()
        var all = lines
        for _ in 0..<Int.random(in: 0...6, using: &rng) {
            all.insert(pick(["", "event: ping", "data: {broken", "data: [DONE]", ": comment", "data: {\"type\":\"unknown.event\"}", "data:"], &rng),
                       at: Int.random(in: 0...(all.count - 1), using: &rng))
        }
        for line in all { if let e = ResponsesEvent.parse(line: line) { acc.consume(e) } }
        if acc.status != .completed || acc.replyText != "Hello there, friend" { streamOK = false }
    }
    check("500 streams with junk lines mixed in all read correctly", streamOK)

    var tokensRejected = true
    let key = TestSigningKey()
    let good = key.sign(["iss": "https://auth.openai.com", "aud": "c", "sub": "s", "nonce": "n", "exp": .number(Date().timeIntervalSince1970 + 600)])
    for i in 0..<400 {
        var bytes = Array(good.utf8)
        let index = Int.random(in: 0..<bytes.count, using: &rng)
        bytes[index] = UInt8(Int.random(in: 33...126, using: &rng))
        let mutated = String(decoding: bytes, as: UTF8.self)
        if mutated != good, (try? IDTokenValidator.validate(mutated, keys: [key.jwk], clientID: "c", nonce: "n")) != nil {
            // Changing a base64 padding-free last character can decode to the same bytes; only accept it if so.
            if Base64URL.decode(String(mutated.split(separator: ".").last ?? "")) != Base64URL.decode(String(good.split(separator: ".").last ?? "")) {
                tokensRejected = false
                print("   accepted mutation \(i) at \(index)")
            }
        }
        _ = try? IDTokenValidator.validate(String((0..<Int.random(in: 0...200, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }),
                                           keys: [key.jwk], clientID: "c", nonce: "n")
    }
    check("400 tampered ID tokens are all refused, and random junk never crashes", tokensRejected)

    var roundTrips = true
    for _ in 0..<1000 {
        let text = String((0..<Int.random(in: 0...40, using: &rng)).map { _ in Character(UnicodeScalar(UInt32.random(in: 32...0x2FF, using: &rng)) ?? "x") })
        if FormEncoding.decode("k=\(FormEncoding.escape(text))")["k"] != text { roundTrips = false }
        let json: JSONValue = ["s": .string(text), "n": .number(Double(Int.random(in: -999...999, using: &rng))), "a": [.bool(true), .null]]
        if (try? JSONValue.parse(json.data)) != json { roundTrips = false }
    }
    check("1,000 random strings survive form and JSON encoding unchanged", roundTrips)

    // Flood the sign-in listener with junk and slow connections; the real redirect still gets through.
    let flood = Box<[String: Bool]>([:])
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        do {
            let server = LoopbackServer { q in q["state"] == "ok" ? .init(finish: true, status: 200, title: "ok", message: "ok") : .init(finish: false, status: 400, title: "no", message: "no") }
            let port = try await server.start()
            let waiter = Task { try await server.waitForCallback(timeout: 30) }
            var slow: [FileHandle] = []
            for _ in 0..<10 {
                if let socket = openSocket(port: port) {
                    try? socket.write(contentsOf: Data("GET /auth/callback?state=ok&code=slow HTTP/1.1\r\nHost: x\r\n".utf8))  // never finishes its headers
                    slow.append(socket)
                }
            }
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<120 {
                    group.addTask {
                        if let socket = openSocket(port: port) {
                            let junk = i % 3 == 0 ? Data(repeating: 0x41, count: 20_000) : Data("NOT HTTP \(i)\r\n\r\n".utf8)
                            try? socket.write(contentsOf: junk)
                            try? socket.close()
                        }
                    }
                }
            }
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?state=ok&code=real")!)
            let query = try await waiter.value
            flood.value["ok"] = (response as? HTTPURLResponse)?.statusCode == 200 && query["code"] == "real"
            for s in slow { try? s.close() }
        } catch {
            flood.value["error"] = false
        }
    }
    done.wait()
    check("The sign-in listener survives 120 junk and 10 stalled connections and still finishes a real sign-in", flood.value["ok"] == true, "\(flood.value)")

    MainActor.assumeIsolated { runToolTorture() }
}

private func pick<T>(_ list: [T], _ rng: inout SeededRandom) -> T { list[Int.random(in: 0..<list.count, using: &rng)] }

/// A raw TCP connection to 127.0.0.1, for flood testing.
func openSocket(port: UInt16) -> FileHandle? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard result == 0 else { close(fd); return nil }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}


@MainActor
private func runToolTorture() {
    let data = FakeData()
    var customer = Customer()
    customer.name = "Ridge Property Group"
    customer.phone = "555-0100"
    customer.email = "dana@example.com"
    var job = Job()
    job.name = "Maple Ridge Plaza"
    job.number = "2026-001"
    job.customerID = customer.id
    job.stage = .won
    job.address = "2200 Maple Ridge Rd"
    job.schedule = [ScheduleEntry(day: Date().startOfDay.adding(days: 2), crewID: data.settings.crews.first?.id, startTime: "7:00 AM", note: "")]
    var option = EstimateOption()
    option.title = "Mill & overlay"
    var line = LineItem(); line.name = "Surface mix"; line.qty = 500; line.unit = "ton"; line.unitCents = 7800; line.group = "Materials"
    option.items = [line]
    var estimate = Estimate(); estimate.options = [option]; estimate.selectedOptionID = option.id
    var second = Job(); second.name = "Hillcrest Apartments"; second.number = "2026-002"; second.stage = .lead
    data.jobs = [job, second]
    data.customers = [customer]
    data.estimates = [job.id: estimate, second.id: Estimate()]
    data.invoices = [:]
    func fingerprint() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let jobs = (try? encoder.encode(data.jobs)) ?? Data()
        let customers = (try? encoder.encode(data.customers)) ?? Data()
        let estimates = (try? encoder.encode(data.estimates.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value))) ?? Data()
        let rates = (try? encoder.encode(data.rates)) ?? Data()
        return jobs + customers + estimates + rates
    }
    let before = fingerprint()
    var proposedTotal = 0, errors = 0, calls = 0
    var replayMatches = true
    for seed in 0..<40 {
        var fuzzer = ToolFuzzer(seed: UInt64(seed), base: data)
        let mode: AssistantMode = seed % 4 == 0 ? .chat : .action
        let runner = ToolRunner(base: data, mode: mode, areas: Set(ToolArea.allCases), shareContact: seed % 2 == 0)
        var all: [ProposedChange] = []
        for _ in 0..<80 {
            let (name, args) = fuzzer.call()
            let outcome = runner.run(name: name, arguments: args)
            calls += 1
            if outcome.isError { errors += 1 }
            if outcome.output.compactString.count > 200_000 { replayMatches = false }
            all += runner.takeProposed()
        }
        if mode == .chat && !all.isEmpty { replayMatches = false }
        proposedTotal += all.count
        let replay = DraftState.replay(all.flatMap(\.ops), base: data)
        func timeless(_ jobs: [UUID: Job]) -> [UUID: Job] {
            jobs.mapValues { var j = $0; j.updated = .distantPast; j.stageChanged = .distantPast; j.sentOn = j.sentOn.map { _ in .distantPast }; return j }
        }
        if replay.state.estimates != runner.draft.estimates || timeless(replay.state.jobs) != timeless(runner.draft.jobs) || !replay.failures.isEmpty {
            replayMatches = false
        }
        // Any subset in order still replays without crashing.
        let subset = all.enumerated().filter { $0.offset % 2 == seed % 2 }.map(\.element)
        _ = DraftState.replay(subset.flatMap(\.ops), base: data)
        for draftEstimate in runner.draft.estimates.values {
            for o in draftEstimate.options where o.breakdown.costCents < 0 || o.profitPct < 0 || o.profitPct > 100 { replayMatches = false }
        }
    }
    check("Torture: 3,200 random tool calls (\(errors) refused cleanly, \(proposedTotal) changes proposed) never touched the real data",
          fingerprint() == before)
    check("Torture: every run's proposals replay to exactly what the assistant saw, with sane numbers, and Chat proposed nothing", replayMatches)
}
