import Foundation

/// The assistant's replies on a ChatGPT plan, its tool groups, and drawing on the map.
func runAssistantMapTests() {
    MainActor.assumeIsolated {
        print("\n-- Assistant: replies on a ChatGPT plan")
        let call: JSONValue = ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "look_at_map", "namespace": "maps", "arguments": "{}"]
        let message: JSONValue = ["type": "message", "id": "m1", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]]
        var planStream = ResponseAccumulator()
        for event in [["type": "response.output_item.done", "item": call], ["type": "response.output_item.done", "item": message],
                      ["type": "response.completed", "response": ["id": "r", "output": []]]] as [JSONValue] {
            planStream.consume(ResponsesEvent(type: event["type"]?.string ?? "", payload: event))
        }
        check("A reply whose last event lists no output still has its tool calls and words (the silent-reply bug)",
              planStream.functionCalls.count == 1 && planStream.replyText == "Done." && planStream.status == .completed)
        var apiStream = ResponseAccumulator()
        apiStream.consume(ResponsesEvent(type: "response.output_item.done", payload: ["type": "response.output_item.done", "item": message]))
        apiStream.consume(ResponsesEvent(type: "response.completed", payload: ["type": "response.completed", "response": ["output": [message, call]]]))
        check("When the last event does list the output, that list is used", apiStream.output.count == 2 && apiStream.functionCalls.count == 1)

        print("\n-- Assistant: tool groups")
        let all = Set(ToolArea.allCases)
        let specs = ToolRunner.specs(mode: .action, areas: all)
        let grouped = ToolFormat.tools(specs, format: .namespaces, strict: true)
        let nested = grouped.flatMap { $0["tools"]?.array ?? [] }
        check("For a ChatGPT plan every function tool goes inside a namespace",
              grouped.allSatisfy { $0["type"]?.string == "namespace" && !($0["name"]?.string ?? "").isEmpty } && nested.count == specs.count
                && nested.allSatisfy { $0["type"]?.string == "function" })
        check("Every tool belongs to a named group of 10 or fewer",
              ToolRunner.allSpecs(mode: .action).allSatisfy { $0.namespace != "app" } && ToolSpec.groups.allSatisfy { $0.tools.count <= 10 },
              ToolRunner.allSpecs(mode: .action).filter { $0.namespace == "app" }.map(\.name).description)
        check("For an API key the tools stay a plain list", ToolFormat.tools(specs, format: .flat, strict: true).allSatisfy { $0["type"]?.string == "function" })

        print("\n-- Assistant: map pictures")
        let lot = Coordinate(lat: 39.9612, lon: -82.9988)
        let frame = MapFrame(center: lot, spanMeters: 250)
        let middle = frame.gridPoint(lot)
        check("The picture's center is grid 500, 500", abs(middle.x - 500) < 1e-6 && abs(middle.y - 500) < 1e-6, "\(middle)")
        var roundTrip = 0.0
        for (x, y) in [(0.0, 0.0), (1000.0, 1000.0), (123.4, 876.5), (999.0, 3.0)] {
            let back = frame.gridPoint(frame.coordinate(gridX: x, gridY: y))
            roundTrip = max(roundTrip, abs(back.x - x), abs(back.y - y))
        }
        check("Grid points and map coordinates convert back and forth exactly", roundTrip < 1e-6, "\(roundTrip)")
        let across = Geo.lengthFt([frame.coordinate(gridX: 0, gridY: 500), frame.coordinate(gridX: 1000, gridY: 500)])
        let down = Geo.lengthFt([frame.coordinate(gridX: 500, gridY: 0), frame.coordinate(gridX: 500, gridY: 1000)])
        check("A 250 m picture is 250 m across and down", near(across, 820.2, 0.5) && near(down, 820.2, 0.5), "\(across) × \(down) ft")
        check("north is up: a smaller y is farther north", frame.coordinate(gridX: 500, gridY: 100).lat > frame.coordinate(gridX: 500, gridY: 900).lat)
        check("A map id round-trips, and nonsense ids are refused",
              MapFrame(id: frame.id) == frame && MapFrame(id: "abc") == nil && MapFrame(id: "95,0,250") == nil && MapFrame(id: "39,-83,99999") == nil)

        print("\n-- Assistant: drawing on the map")
        let data = FakeData()
        var job = Job()
        job.number = "2026-010"
        job.name = "Energy Blvd"
        job.latitude = lot.lat
        job.longitude = lot.lon
        data.jobs = [job]
        var existing = TakeoffShape()
        existing.name = "Area 1"
        existing.points = [frame.coordinate(gridX: 300, gridY: 300), frame.coordinate(gridX: 400, gridY: 300), frame.coordinate(gridX: 400, gridY: 400)]
        data.takeoffs[job.id] = Takeoff(shapes: [existing], center: lot, spanMeters: 250)
        let id = frame.id
        let runner = ToolRunner(base: data, mode: .action, areas: all, shareContact: false)
        @MainActor func run(_ name: String, _ args: JSONValue) -> ToolOutcome { runner.run(name: name, arguments: args.compactString) }

        let square: JSONValue = [[200, 200], [800, 200], [800, 800], [200, 800]]
        let drawn = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "area", "work_type": "millOverlay", "marker_kind": .null,
                                       "name": "Main lot", "depth_inches": .null, "points": square, "cutouts": [[[450, 450], [550, 450], [550, 550], [450, 550]]]])
        let shapes = runner.draft.takeoff(job.id, data).shapes
        let main = shapes.first { $0.name == "Main lot" }
        let expected = (150.0 * 150 - 25 * 25) * 10.7639
        check("draw_shape proposes an area from grid points, cut-out removed, at the usual depth",
              !drawn.isError && main.map { near(Geo.netAreaSqFt($0), expected, 1) && $0.holes.count == 1 && $0.depthInches == 2 && $0.workType == .millOverlay } == true,
              "\(drawn.output.compactString) \(main.map { Geo.netAreaSqFt($0) } ?? -1) vs \(expected)")
        check("…and only proposes it: nothing changes until Apply", data.takeoffs[job.id]?.shapes.count == 1 && runner.takeProposed().count == 1)

        let closed = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "area", "work_type": "sealcoat", "marker_kind": .null, "name": .null,
                                        "depth_inches": .null, "points": [[100, 100], [200, 100], [200, 200], [100, 200], [100, 100]], "cutouts": .null])
        check("A repeated first corner (a closed ring) is accepted", !closed.isError && runner.takeProposed().first?.ops.count == 1)

        let bowTie = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "area", "work_type": .null, "marker_kind": .null, "name": .null,
                                        "depth_inches": .null, "points": [[100, 100], [900, 900], [900, 100], [100, 900]], "cutouts": .null])
        let offPicture = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "area", "work_type": .null, "marker_kind": .null, "name": .null,
                                            "depth_inches": .null, "points": [[100, 100], [5000, 100], [100, 900]], "cutouts": .null])
        let badID = run("draw_shape", ["job": "2026-010", "map_id": "here", "kind": "area", "work_type": .null, "marker_kind": .null, "name": .null,
                                       "depth_inches": .null, "points": square, "cutouts": .null])
        let outsideCut = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "area", "work_type": .null, "marker_kind": .null, "name": .null,
                                            "depth_inches": .null, "points": [[100, 100], [300, 100], [300, 300], [100, 300]], "cutouts": [[[700, 700], [800, 700], [800, 800]]]])
        let wrongKind = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "area", "work_type": "striping", "marker_kind": .null, "name": .null,
                                           "depth_inches": .null, "points": square, "cutouts": .null])
        check("Outlines that cross themselves, points off the picture, made-up map ids, cutouts outside the area and lines drawn as areas are refused",
              bowTie.isError && offPicture.isError && badID.isError && outsideCut.isError && wrongKind.isError && runner.takeProposed().isEmpty,
              [bowTie, offPicture, badID, outsideCut, wrongKind].map { $0.output["error"]?.string ?? "ok" }.description)

        let line = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "line", "work_type": "striping", "marker_kind": .null, "name": .null,
                                      "depth_inches": .null, "points": [[0, 500], [1000, 500]], "cutouts": .null])
        let markers = run("draw_shape", ["job": "2026-010", "map_id": .string(id), "kind": "markers", "work_type": .null, "marker_kind": "ada", "name": .null,
                                         "depth_inches": .null, "points": [[300, 300], [320, 300], [340, 300]], "cutouts": .null])
        let lineShape = runner.draft.takeoff(job.id, data).shapes.first { $0.kind == .line }
        check("Lines measure their length, and markers become one marker each",
              !line.isError && near(Geo.lengthFt(lineShape?.points ?? []), 820.2, 0.5) && !markers.isError
                && runner.draft.takeoff(job.id, data).shapes.filter { $0.kind == .count && $0.countKind == .ada }.count == 3)
        _ = runner.takeProposed()

        let reshaped = run("reshape_area", ["job": "2026-010", "area": "Main lot", "map_id": .string(id), "points": [[200, 200], [500, 200], [500, 500], [200, 500]], "cutouts": .null])
        let after = runner.draft.takeoff(job.id, data).shapes.first { $0.name == "Main lot" }
        check("reshape_area moves an outline and drops a cutout that no longer fits",
              !reshaped.isError && after.map { near(Geo.netAreaSqFt($0), 75.0 * 75 * 10.7639, 1) && $0.holes.isEmpty } == true,
              reshaped.output.compactString)
        let deleted = run("delete_shape", ["job": "2026-010", "area": "Area 1"])
        check("delete_shape takes a shape off the map", !deleted.isError && !runner.draft.takeoff(job.id, data).shapes.contains { $0.name == "Area 1" })
        let ops = runner.takeProposed().flatMap(\.ops)
        let replay = DraftState.replay(ops, base: data)
        check("Proposed drawing replays the same way when the owner applies it", replay.failures.isEmpty && replay.state.takeoffs[job.id]?.shapes.contains { $0.name == "Area 1" } == false)

        let chat = ToolRunner(base: data, mode: .chat, areas: all, shareContact: false)
        check("Chat mode can look but can't draw",
              chat.run(name: "draw_shape", arguments: #"{"job":"2026-010","map_id":"x","kind":"area","work_type":null,"marker_kind":null,"name":null,"depth_inches":null,"points":[],"cutouts":null}"#).isError
                && ToolRunner.specs(mode: .chat, areas: all).contains { $0.name == "look_at_map" })

        print("\n-- Assistant: settings")
        let settings = run("update_settings", ["company_name": "Ridge Paving", "phone": .null, "email": .null, "address": .null, "license": .null, "website": .null,
                                               "home_base": .null, "home_latitude": .null, "home_longitude": .null, "paving_min_f": 45, "sealcoat_min_f": .null,
                                               "sealcoat_dry_hours": .null, "rain_chance_max": .null, "proposal_valid_days": .null, "exclusions": .null, "terms": .null,
                                               "escalation_clause": false, "backup_nightly": .null, "sealcoat_cycle_years": .null,
                                               "crew": ["id": .null, "name": "Crew C", "kind": "Patching", "people": 4, "equipment": .null]])
        let change = runner.takeProposed().first
        let s = runner.draft.currentSettings(data)
        check("update_settings proposes company, weather, proposal and crew changes, unticked until the owner ticks it",
              !settings.isError && change?.needsOK == true && change?.isOn == false && s.company.name == "Ridge Paving" && s.weather.pavingMinF == 45
                && !s.proposal.escalationClause && s.crews.contains { $0.name == "Crew C" } && data.settings.company.name.isEmpty,
              settings.output.compactString)
        let silly = run("update_settings", ["company_name": .null, "phone": .null, "email": .null, "address": .null, "license": .null, "website": .null,
                                            "home_base": .null, "home_latitude": .null, "home_longitude": .null, "paving_min_f": 500, "sealcoat_min_f": .null,
                                            "sealcoat_dry_hours": .null, "rain_chance_max": .null, "proposal_valid_days": .null, "exclusions": .null, "terms": .null,
                                            "escalation_clause": .null, "backup_nightly": .null, "sealcoat_cycle_years": .null, "crew": .null])
        check("Out-of-range settings are refused", silly.isError)

        print("\n-- Assistant: older preferences")
        let decoder = JSONDecoder()
        let allOn = try? decoder.decode(AssistantPrefs.self, from: Data(#"{"areas":["estimates","jobs","schedule","customers","money"]}"#.utf8))
        let someOff = try? decoder.decode(AssistantPrefs.self, from: Data(#"{"areas":["jobs"]}"#.utf8))
        check("A new permission starts on only for people who had every one on",
              allOn?.areas == all && someOff?.areas == [.jobs], "\(String(describing: allOn?.areas)) \(String(describing: someOff?.areas))")
    }
}
