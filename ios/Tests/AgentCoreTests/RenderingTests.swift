#if os(macOS) || AGENT_APP_HOST
  import CoreGraphics
  import SwiftUI
  import Testing

  @testable import AgentCore
  @testable import AgentUI

  #if os(iOS)
    import UIKit
  #else
    import AppKit
  #endif

  // Hosted captures share one scene and must own its key window serially.
  @Suite(.serialized) struct NativeRenderingTests {
    #if os(iOS)
      @Test @MainActor
      func nativeComposerCopiesAndClearsWithoutWaitingForAnotherRunLoop() async throws {
        let editor = ComposerEditor()
        var draft = "A restored unsent note"
        var focused = false
        let content = ComposerTextView(
          text: Binding(get: { draft }, set: { draft = $0 }),
          focused: Binding(get: { focused }, set: { focused = $0 }),
          enabled: true, editor: editor)
        let host = UIHostingController(rootView: content)
        let scene = try #require(
          UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
          window.isHidden = true
          window.rootViewController = nil
          previous?.makeKey()
        }
        window.layoutIfNeeded()
        let view = try #require(editor.view)
        #expect(view.text == draft)
        #expect(view.becomeFirstResponder())
        let text = "An uncommitted parcel note"
        view.selectedRange = NSRange(location: 0, length: view.text.utf16.count)
        view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        #expect(view.markedTextRange != nil)
        var submitted: String?
        #expect(
          editor.submit {
            submitted = $0
            draft = ""
            return true
          })
        // No await, layout pass or focus change may be needed to clear glyphs.
        #expect(submitted == text)
        #expect(view.text.isEmpty)
        #expect(view.markedTextRange == nil)
        #expect(view.isFirstResponder)
        view.insertText(text)
        #expect(view.text == text)
        #expect(draft == text)
        #expect(!editor.submit { _ in false })
        #expect(view.text == text)
        #expect(view.isFirstResponder)
        #expect(
          editor.submit { _ in
            draft = ""
            return true
          })
        // A local rejection may restore the identical copy before SwiftUI's
        // next update. It must still reach the already-cleared native view.
        host.rootView = ComposerTextView(
          text: .constant(text), focused: .constant(true), enabled: true, editor: editor)
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.view === view)
        #expect(view.text == text)
        #expect(view.isFirstResponder)
      }

      @Test(arguments: [false, true]) @MainActor
      func sendingClearsNativeMarkedTextWithoutDismissingTheKeyboard(stopping: Bool) async throws {
        let entered = AsyncStream<Void>.makeStream()
        let admission = AsyncStream<Bool>.makeStream()
        defer { admission.continuation.finish() }
        let model = ChatModel(admit: { _ in
          entered.continuation.yield(())
          for await result in admission.stream { return result }
          return false
        })
        try await withConnectedCoordinator(model) { _, directory in
          let host = UIHostingController(rootView: MainChatView(model: model))
          let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
          let previous = scene.windows.first(where: \.isKeyWindow)
          let window = UIWindow(windowScene: scene)
          window.rootViewController = host
          window.makeKeyAndVisible()
          defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
          }
          window.layoutIfNeeded()
          try await Task.sleep(for: .milliseconds(100))
          @MainActor func input(in view: UIView) -> (UIView & UITextInput)? {
            if let input = view as? (UIView & UITextInput) { return input }
            for child in view.subviews {
              if let input = input(in: child) { return input }
            }
            return nil
          }
          let editor = try #require(input(in: host.view))
          #expect(editor.becomeFirstResponder())
          let text = "The test parcel is ready"
          editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
          #expect(model.draft == text)
          #expect(editor.markedTextRange != nil)
          let sending = Task { await model.send() }
          for await _ in entered.stream { break }
          try await Task.sleep(for: .milliseconds(100))
          let range = try #require(
            editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument))
          #expect(editor.text(in: range) == "", "Sent text must leave the actual native editor")
          #expect(editor.isFirstResponder)
          #expect(model.draft.isEmpty)
          if stopping {
            await model.detach(directory.profile)
          } else {
            editor.insertText("The next parcel")
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.draft == "The next parcel")
          }
          admission.continuation.yield(true)
          await sending.value
          try await Task.sleep(for: .milliseconds(100))
          let expected = stopping ? "" : "The next parcel"
          let next = try #require(
            editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument))
          #expect(editor.text(in: next) == expected)
          #expect(editor.isFirstResponder)
          #expect(model.draft == expected)
        }
      }
    #endif

    @MainActor private func renderRows(
      _ rows: [ChatRow], size: DynamicTypeSize = .large, scheme: ColorScheme = .light,
      expandedActivity: Bool = false, inspection: ToolDetailsAvailable? = nil
    ) async throws -> CGImage {
      let models = rows.map(RowModel.init)
      let content = VStack(alignment: .leading, spacing: 22) {
        if expandedActivity {
          ForEach(TranscriptItem.grouped(models)) { item in
            switch item {
            case .activity(let group):
              ActivityGroupView(
                group: group,
                expansion: .constant(
                  ActivityExpansion(groups: [group.id], items: Set(group.rows.map(\.id)))),
                details: { row in .unavailable(.init(callId: row.tool?.callId ?? "")) })
            case .message(let model):
              MessageRow(model: model, retry: { _ in }, restore: { _ in }, discard: { _ in })
            }
          }
        } else {
          ForEach(models) { model in
            MessageRow(model: model, retry: { _ in }, restore: { _ in }, discard: { _ in })
          }
        }
        if let inspection {
          ToolContent(
            title: "Output", content: inspection.output, name: inspection.name,
            preview: rows.first?.presentation == nil ? nil : rows.first?.text)
        }
      }
      .padding(16)
      .frame(width: 390)
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, scheme)
      .background(.background)
      // Capture the native hierarchy: ImageRenderer omits platform-backed
      // controls and scroll views, which contain the code blocks and tables.
      #if os(iOS)
        let host = UIHostingController(rootView: content)
        let dimensions = host.sizeThatFits(
          in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
        #expect(dimensions.width == 390)
        let scene = try #require(
          UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        // A scene resizes its root view to the device. Keep the measured view
        // as a fixed-size child so narrow captures retain their leading edge.
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
          window.isHidden = true
          host.willMove(toParent: nil)
          host.view.removeFromSuperview()
          host.removeFromParent()
          window.rootViewController = nil
          previousWindow?.makeKey()
        }
        window.layoutIfNeeded()
        container.addChild(host)
        let viewport = UIView(
          frame: CGRect(
            origin: .zero,
            size: CGSize(
              width: dimensions.width, height: min(dimensions.height, container.view.bounds.height))
          ))
        viewport.clipsToBounds = true
        let scroll = UIScrollView(frame: viewport.bounds)
        scroll.showsVerticalScrollIndicator = false
        scroll.contentSize = dimensions
        viewport.addSubview(scroll)
        container.view.addSubview(viewport)
        scroll.addSubview(host.view)
        host.view.frame = CGRect(origin: .zero, size: dimensions)
        host.didMove(toParent: container)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.size == dimensions)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        var frames: [(CGFloat, UIImage)] = []
        let pageHeight = try #require(viewport.bounds.height > 0 ? viewport.bounds.height : nil)
        // Capture only attached, visible native surfaces, then assemble the gallery.
        // This UIKit scroll view owns its content; the app's lazy SwiftUI scroll
        // view is never moved through UIKit.
        for index in 0..<Int(ceil(dimensions.height / pageHeight)) {
          let offset = min(CGFloat(index) * pageHeight, max(0, dimensions.height - pageHeight))
          scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
          try await Task.sleep(for: .milliseconds(50))
          viewport.layoutIfNeeded()
          let frame = UIGraphicsImageRenderer(size: viewport.bounds.size, format: format).image {
            _ in
            #expect(viewport.drawHierarchy(in: viewport.bounds, afterScreenUpdates: true))
          }
          frames.append((offset, frame))
        }
        let image = UIGraphicsImageRenderer(size: dimensions, format: format).image { context in
          (scheme == .dark ? UIColor.black : UIColor.white).setFill()
          context.fill(CGRect(origin: .zero, size: dimensions))
          for (offset, frame) in frames {
            frame.draw(in: CGRect(x: 0, y: offset, width: dimensions.width, height: pageHeight))
          }
        }
        let pixels = try #require(image.cgImage)
        try requireVisibleContent(pixels)
        return pixels
      #else
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.setFrameSize(view.fittingSize)
        #expect(view.frame.width == 390)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
          view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        return try #require(bitmap.cgImage)
      #endif
    }

    @MainActor @Test func typedActivityRendersWithoutPrivateDetailsInLightAndDark() async throws {
      var transcript = Transcript()
      for (index, presentation, body) in [
        (
          0,
          MessagePresentation.command(
            .init(command: "printf 'literal output'", durationMs: 12, exitCode: 7)),
          "Literal **stdout**\nA second output line"
        ),
        (
          1, .fileChanges(.init(changes: [.init(operation: .update, path: "example.rs")])),
          "+new line\n-old line"
        ),
        (
          2,
          .agentCoordination(
            .init(
              action: .followup, agents: [.init(state: .completed, threadId: "child")],
              receiverThreadIds: ["child"])), ""
        ),
        (3, .plan, "1. **Keep** the existing conversation."),
      ] {
        transcript.message(
          .init(
            continuation: false, entryId: "typed-\(index)", finalChunk: true,
            presentation: presentation, role: index == 3 ? .assistant : .tool, text: body,
            tool: index < 3
              ? .init(
                callId: "typed-\(index)", name: "exec", status: index == 0 ? .failed : .finished)
              : nil))
      }
      for scheme in [ColorScheme.light, .dark] {
        let image = try await renderRows(transcript.rows, scheme: scheme, expandedActivity: true)
        #expect(image.width >= 390)
        #expect(image.height > 400)
        Attachment.record(image, named: "typed-activity-\(scheme)", as: .png)
      }
    }

    @MainActor @Test func richerLazyOutputRendersBeyondANonemptyTypedPreview() async throws {
      let preview = "Bounded preview\n[Output preview truncated]"
      var transcript = Transcript()
      transcript.message(
        .init(
          continuation: false, entryId: "retained", finalChunk: true,
          presentation: .tool(.init(namespace: "fixture")), role: .tool, text: preview,
          tool: .init(callId: "retained", name: "inspect", status: .finished)))
      let original = (0..<24).map { "Additional retained output line \($0)" }.joined(
        separator: "\n")
      let same = ToolDetailsAvailable(
        callId: "retained", input: .unavailable(.init(reason: .notRecorded)), name: "inspect",
        output: .text(.init(text: preview, truncated: false)), status: .finished)
      var richer = same
      richer.output = .text(.init(text: preview + "\n" + original, truncated: false))
      let collapsed = try await renderRows(transcript.rows, inspection: same)
      let expanded = try await renderRows(transcript.rows, inspection: richer)
      #expect(expanded.height > collapsed.height + 120)
      Attachment.record(expanded, named: "richer-retained-tool-output", as: .png)
    }

    @MainActor @Test func supportedMessageRowsRenderInLightAndDarkAppearance() async throws {
      var transcript = Transcript()
      let roles: [HistoryRole] = [
        .user, .assistant, .commentary, .partialAnswer, .final, .notice, .thinking,
      ]
      let file = AttachmentRef(
        id: "11111111-1111-4111-8111-111111111111", mediaType: "application/pdf",
        name: "Design notes.pdf",
        sha256: String(repeating: "a", count: 64), sizeBytes: 24576)
      for role in roles {
        transcript.message(
          .init(
            attachments: role == .user ? [file] : nil, continuation: false, entryId: role.rawValue,
            finalChunk: true,
            role: role,
            text: "A **useful** message with `inline code` and a [link](https://example.invalid).",
            tool: nil))
      }
      for status in [ToolStatus.running, .finished, .failed, .declined, .interrupted, .unknown] {
        transcript.message(
          .init(
            attachments: nil, continuation: false, entryId: "tool-\(status.rawValue)",
            finalChunk: true, role: .tool,
            text: "Build the native client",
            tool: .init(callId: status.rawValue, name: "build", status: status)))
      }
      transcript.message(
        .init(
          attachments: nil, continuation: false, entryId: "rich-answer", finalChunk: true,
          role: .final,
          text: """
            # Native rendering
            ## Second level
            ### Third level
            #### Fourth level
            ##### Fifth level
            ###### Sixth level

            Plain, *emphasis*, **strong**, ***both***, ~~struck through~~, `inline code`,
            and a [link](https://example.invalid).

            Unicode: café, 日本語, العربية, 🦀, and a combined accent: é.

            > A quoted update.

            - Unordered item
              - Nested item with a longer sentence that wraps onto another line.
            - Another item

            3. Ordered item

               A continuation paragraph stays indented without another number.

            4. Another item

            - [x] Completed task
            - [ ] Open task

            ~~~swift
            let message = "Hello 🦀"
            let deliberatelyWideLine = "Code remains on one line and scrolls horizontally at the phone's available width."
            ~~~

            ````markdown
            ```swift
            let nestedFence = "Preserved as code"
            ```
            ````

            | Check | Result | A deliberately wide third column |
            | --- | --- | --- |
            | Build | Passed | Code and tables can scroll horizontally |
            | Left\\|right | `inline code` | Escaped pipes stay in their cell |
            | - | : | Data that resembles a delimiter remains visible |
            | | An empty first cell | |

            ```swift
            let streaming = "An unfinished fence stays readable"
            """, tool: nil))
      for delivery in [Delivery.uncertain, .rejected] {
        transcript.pending(
          .init(
            attachments: nil, inputId: UUID().uuidString, mode: .steer,
            text: "Keep this original message"),
          delivery: delivery)
      }
      for scheme in [ColorScheme.light, .dark] {
        let image = try await renderRows(transcript.rows, scheme: scheme)
        #expect(image.width >= 390)
        #expect(image.height > 600)
        Attachment.record(image, named: "message-rows-\(scheme)", as: .png)
      }
      // Bound native offscreen surfaces while retaining every row at large text sizes.
      for start in stride(from: 0, to: transcript.rows.count, by: 4) {
        let rows = Array(transcript.rows[start..<min(start + 4, transcript.rows.count)])
        let accessible = try await renderRows(rows, size: .accessibility3)
        #expect(accessible.width >= 390)
        Attachment.record(
          accessible, named: "message-rows-accessibility-\(start / 4 + 1)", as: .png)
      }
    }

    @MainActor @Test func flatProseCompactActivityAndLiteralExpandedOutputKeepTheirNativeHierarchy()
      async throws
    {
      var transcript = Transcript()
      transcript.pending(
        .init(
          inputId: "native-example", mode: .steer, origin: .ios,
          text: "Check the saved request without changing its owner."), delivery: .saved)
      transcript.message(
        .init(
          continuation: false, entryId: "explanation", finalChunk: true,
          role: .assistant,
          text: """
            The saved request and the current connection can be inspected independently. Neither observation should submit another message.

            Keep the original input identifier while the coordinator reconnects. A receipt confirms storage, not completion of the work.

            Tool activity stays compact until it is opened. The answer remains ordinary readable prose, not a terminal transcript.
            """))
      transcript.message(
        .init(
          continuation: false, entryId: "command", finalChunk: true,
          presentation: .command(.init(command: "inspect-example --read-only", exitCode: 0)),
          role: .tool, text: "A bounded diagnostic result",
          tool: .init(callId: "read-only", name: "exec", status: .finished)))
      let output = ToolDetailsAvailable(
        callId: "read-only", input: .unavailable(.init(reason: .notRecorded)),
        name: "exec",
        output: .text(
          .init(
            text: """
              1: **literal output**, not Markdown emphasis
              2: let diagnostic = "a deliberately long line that remains horizontal native output rather than forcing the entire conversation wider";
              3: <result status="saved">unchanged</result>
              """, truncated: false)), status: .finished)
      for scheme in [ColorScheme.light, .dark] {
        let compact = try await renderRows(transcript.rows, scheme: scheme)
        let expanded = try await renderRows(
          transcript.rows, scheme: scheme, expandedActivity: true, inspection: output)
        #expect(compact.width >= 390)
        #expect(expanded.width == compact.width)
        #expect(expanded.height > compact.height)
        Attachment.record(compact, named: "native-reference-hierarchy-\(scheme)", as: .png)
        Attachment.record(expanded, named: "native-reference-literal-output-\(scheme)", as: .png)
      }
    }

    @MainActor @Test func nonSuccessToolStatesHaveDistinctNativeIconsAndCollapsedSummaries()
      async throws
    {
      func row(_ status: ToolStatus) throws -> ChatRow {
        var transcript = Transcript()
        transcript.message(
          .init(
            continuation: false, entryId: "tool-entry", finalChunk: true, role: .tool,
            text: "Check the requested result",
            tool: .init(callId: "tool-call", name: "verify_result", status: status)))
        return try #require(transcript.rows.first)
      }
      let finished = try await renderRows([row(.finished)])
      let finishedPixels = try #require(finished.dataProvider?.data) as Data
      for status in [ToolStatus.declined, .interrupted, .unknown] {
        let item = try row(status)
        let image = try await renderRows([item])
        let pixels = try #require(image.dataProvider?.data) as Data
        #expect(finishedPixels != pixels, "\(status.rawValue) must not render as success")
        let group = ActivityGroup(id: "activity:tool-entry", rows: [RowModel(item)])
        #expect(group.summary.contains(status.rawValue))
        Attachment.record(image, named: "tool-state-\(status.rawValue)", as: .png)
      }
    }

    #if os(iOS)
      private func requireVisibleContent(_ image: CGImage, region: CGRect? = nil) throws {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
          let context = try #require(
            CGContext(
              data: buffer.baseAddress, width: image.width, height: image.height,
              bitsPerComponent: 8, bytesPerRow: image.width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue))
          let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
          context.setFillColor(CGColor(gray: 1, alpha: 1))
          context.fill(bounds)
          context.draw(image, in: bounds)
          let area = (region ?? bounds).intersection(bounds).integral
          let bytes = try #require(buffer.bindMemory(to: UInt8.self).baseAddress)
          let first = Int(area.minY) * image.width * 4 + Int(area.minX) * 4
          var different = 0
          for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
              let offset = (y * image.width + x) * 4
              if (0..<3).contains(where: { bytes[offset + $0] != bytes[first + $0] }) {
                different += 1
              }
            }
          }
          #expect(
            different > Int(area.width * area.height) / 100, "Native transcript capture is blank")
        }
      }

      @MainActor private final class ConversationFixture {
        let model = ChatModel()
        private var details: [String: ToolDetails] = [:]
        private(set) var requests: Set<String> = []

        init() throws {
          var transcript = Transcript()
          transcript.message(
            .init(
              continuation: false, entryId: "request", finalChunk: true, role: .user,
              text: "Check the worker’s allocation logs and explain why its path is stale."))
          transcript.message(
            .init(
              continuation: false, entryId: "preamble", finalChunk: true, role: .commentary,
              text: "The saved allocation and live worker can be compared before changing anything."
            ))
          let commands: [(String, [String])] = [
            ("rg", ["-n", "allocation", "Sources/"]), ("tail", ["-n", "40", "logs/worker.log"]),
            ("ps", ["-o", "pid,comm", "-p", "42"]), ("cat", ["config/worker.json"]),
            ("ls", ["logs/"]), ("test", ["-d", "logs/current"]),
            ("readlink", ["logs/current"]), ("rg", ["-n", "pending", "logs/worker.log"]),
          ]
          for (index, command) in commands.enumerated() {
            if index.isMultiple(of: 3) {
              transcript.message(
                .init(
                  continuation: false, entryId: "thought-\(index)", finalChunk: true,
                  role: .thinking,
                  text: """
                    ### Check the saved allocation

                    The saved allocation and live process agree. The next check is whether the worker still reads an old path.

                    - Compare the recorded identifier.
                    - Inspect `logs/current` without changing the allocation.

                    The final answer should explain the smallest repair and preserve the existing work.
                    """))
            }
            let status: ToolStatus = index == 7 ? .running : index == 5 ? .failed : .finished
            let callID = "command-\(index)"
            transcript.message(
              .init(
                continuation: false, entryId: "tool-entry-\(index)", finalChunk: true, role: .tool,
                text: command.0,
                tool: .init(callId: callID, name: "exec", status: status)))
            let input = try JSONEncoder().encode(
              FixtureCommand(program: command.0, args: command.1, cwd: "/workspace/project"))
            let output = try JSONEncoder().encode(
              FixtureProcess(
                exitCode: status == .failed ? 1 : 0,
                stdout: status == .failed
                  ? "" : "The recorded allocation matches the running worker.\n",
                stderr: status == .failed ? "The current log directory does not exist.\n" : ""))
            details[callID] = .available(
              .init(
                callId: callID,
                input: .text(.init(text: String(decoding: input, as: UTF8.self), truncated: false)),
                name: "exec",
                output: status == .running
                  ? .unavailable(.init(reason: .pending))
                  : .text(.init(text: String(decoding: output, as: UTF8.self), truncated: false)),
                status: status))
          }
          transcript.message(
            .init(
              continuation: false, entryId: "steer", finalChunk: true, role: .user,
              text: "Keep the allocation. Explain the fix."))
          transcript.message(
            .init(
              continuation: false, entryId: "answer", finalChunk: true, role: .final,
              text: """
                ### What changed

                The allocation is intact. The worker was reading an old path.

                - Keep the allocation.
                - Point the worker at `logs/current`.
                - Restart only that worker.
                """))
          model.rows = transcript.rows.map(RowModel.init)
          model.connection = .connected
          model.model = "openai/gpt-6.1-sol · high"
          model.busy = true
        }

        func loadDetails(_ row: ChatRow) async throws -> ToolDetails {
          let id = row.tool?.callId ?? ""
          requests.insert(id)
          return details[id] ?? .unavailable(.init(callId: id))
        }

        func expansion() -> ActivityExpansion {
          var result = ActivityExpansion()
          for item in TranscriptItem.grouped(model.rows) {
            if case .activity(let group) = item { result.groups.insert(group.id) }
          }
          if let thought = model.rows.first(where: { $0.row.role == .thinking }) {
            result.items.insert(thought.id)
          }
          if let failed = model.rows.first(where: { $0.row.tool?.status == .failed }) {
            result.items.insert(failed.id)
          }
          if let command = model.rows.first(where: { $0.row.tool != nil }) {
            result.items.insert(command.id)
          }
          return result
        }
      }

      private struct FixtureCommand: Encodable {
        let program: String
        let args: [String]
        let cwd: String
      }

      private struct FixtureProcess: Encodable {
        let type = "process"
        let exitCode: Int
        let stdout: String
        let stderr: String
        let truncated = false
        enum CodingKeys: String, CodingKey {
          case type, stdout, stderr, truncated
          case exitCode = "exit_code"
        }
      }

      private enum ConversationFocus { case collapsed, latest, reasoning }

      @MainActor private func renderConversation(
        _ fixture: ConversationFixture, focus: ConversationFocus, size: DynamicTypeSize,
        scheme: ColorScheme, dimensions: CGSize
      ) async throws -> CGImage {
        let expanded = focus != .collapsed
        let content = MainChatView(
          model: fixture.model, expansion: expanded ? fixture.expansion() : ActivityExpansion(),
          details: fixture.loadDetails,
          initialScrollTarget: focus == .reasoning ? fixture.expansion().groups.first : nil
        )
        .environment(\.dynamicTypeSize, size).environment(\.colorScheme, scheme)
        let host = UIHostingController(rootView: content)
        let scene = try #require(
          UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
          window.isHidden = true
          host.willMove(toParent: nil)
          host.view.removeFromSuperview()
          host.removeFromParent()
          window.rootViewController = nil
          previousWindow?.makeKey()
        }
        window.layoutIfNeeded()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.frame = CGRect(origin: .zero, size: dimensions)
        host.didMove(toParent: container)
        host.view.layoutIfNeeded()
        // Allow native navigation/scroll layout to settle. The latest viewport
        // can virtualize the expanded detail rows; only the focused reasoning
        // capture promises that those rows are mounted and request their data.
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        if !expanded { #expect(fixture.requests.isEmpty) }
        if focus == .reasoning && !size.isAccessibilitySize {
          let deadline = ContinuousClock.now + .seconds(3)
          while fixture.requests.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
          }
          #expect(!fixture.requests.isEmpty, "Expanded tool details must request their data")
        }
        #expect(fixture.requests.isSubset(of: Set((0..<8).map { "command-\($0)" })))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: dimensions, format: format).image { _ in
          #expect(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let pixels = try #require(image.cgImage)
        try requireVisibleContent(
          pixels,
          region: CGRect(
            x: 16, y: 100, width: dimensions.width - 32, height: dimensions.height - 244))
        return pixels
      }

      @MainActor @Test func fullConversationRendersCompactAndExpandedActivity() async throws {
        for (name, scheme, size, width, height, focus) in [
          (
            "light", ColorScheme.light, DynamicTypeSize.large, 390, 844, ConversationFocus.collapsed
          ),
          ("dark", .dark, .large, 390, 844, .collapsed),
          ("large-text", .light, .accessibility3, 390, 844, .collapsed),
          ("small-phone", .light, .large, 320, 568, .collapsed),
          ("expanded-light", .light, .large, 390, 844, .latest),
          ("expanded-dark", .dark, .large, 390, 844, .latest),
          ("reasoning-and-command-light", .light, .large, 390, 844, .reasoning),
          ("reasoning-and-command-dark", .dark, .large, 390, 844, .reasoning),
          ("expanded-large-text", .light, .accessibility3, 390, 844, .reasoning),
        ] {
          let fixture = try ConversationFixture()
          let image = try await renderConversation(
            fixture, focus: focus, size: size, scheme: scheme,
            dimensions: CGSize(width: width, height: height))
          #expect(image.width == width)
          #expect(image.height == height)
          Attachment.record(image, named: "full-chat-\(name)", as: .png)
        }
      }

      /// How many pixels are within `tolerance` of `color` on every channel.
      private func pixels(near color: (Double, Double, Double), in image: CGImage) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
          let context = try #require(
            CGContext(
              data: buffer.baseAddress, width: image.width, height: image.height,
              bitsPerComponent: 8, bytesPerRow: image.width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue))
          context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let target = [color.0, color.1, color.2].map { $0 * 255 }
        return stride(from: 0, to: bytes.count, by: 4).filter { offset in
          (0..<3).allSatisfy { abs(Double(bytes[offset + $0]) - target[$0]) < 16 }
        }.count
      }

      @MainActor @Test func twoCoordinatorFeedNamesEachCoordinatorAndFoldsABroadcast() async throws
      {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = CoordinatorProfile(
          name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2", port: 4001)
        )
        let personal = CoordinatorProfile(
          name: try TagName("Personal"),
          address: try CoordinatorAddress(host: "100.64.1.2", port: 4002))
        let model = ChatModel()
        model.profiles = [work, personal]
        // Sessions that never connect stand in for the paired coordinators.
        for profile in [work, personal] {
          let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
          model.attach(
            Lane(
              id: profile.id,
              session: CoordinatorSession(
                directory: directory, address: profile.address, pin: CoordinatorID(UUID()),
                stamps: StampSource()),
              hold: LegacyHold(directory)))
        }
        func message(_ id: String, _ role: HistoryRole, _ text: String, tool: ToolHistory? = nil)
          -> HistoryMessage
        {
          .init(
            continuation: false, entryId: id, finalChunk: true, role: role, text: text, tool: tool)
        }
        func stamped(_ rows: [ChatRow], _ times: [TimeInterval], sends: [Int: String]) -> [ChatRow]
        {
          zip(rows.indices, zip(rows, times)).map { index, pair in
            var row = pair.0
            row.receivedAt = Date(timeIntervalSince1970: pair.1)
            row.sendID = sends[index]
            return row
          }
        }
        let broadcast = "Flying to Lisbon, offline until 6"
        var workTranscript = Transcript()
        for item in [
          message("w1", .final, "The nightly build finished. Two flaky tests were retried."),
          message("w2", .user, "Rotate the staging deploy key"),
          message(
            "w3", .tool, "rotate-key staging",
            tool: .init(callId: "rotate", name: "exec", status: .finished)),
          message("w4", .final, "Rotated. The old key is revoked."),
          message("w5", .user, broadcast),
          message("w6", .final, "Noted. I'll hold the release review."),
        ] {
          workTranscript.message(item)
        }
        var fromWork = ChatSnapshot()
        fromWork.connection = .connected
        fromWork.rows = stamped(workTranscript.rows, [1, 3, 4, 5, 6, 8], sends: [1: "A", 4: "B"])
        fromWork.sends = [
          "A": .init(recipients: [work.id], progress: .placed),
          "B": .init(recipients: [work.id, personal.id], progress: .placed),
        ]
        var personalTranscript = Transcript()
        personalTranscript.message(
          message("p1", .final, "Your 9:40 flight to Lisbon moved to gate B12."))
        personalTranscript.pending(
          .init(inputId: "personal-lisbon", mode: .steer, text: broadcast), delivery: .uncertain)
        personalTranscript.message(
          message("p2", .final, "Safe flight. Your boarding pass is in Wallet."))
        var fromPersonal = ChatSnapshot()
        fromPersonal.connection = .connected
        fromPersonal.rows = stamped(personalTranscript.rows, [2, 6.001, 9], sends: [1: "B"])
        fromPersonal.sends = [
          "B": .init(recipients: [work.id, personal.id], progress: .pending(.uncertain))
        ]
        model.apply(fromWork, lane: work.id)
        model.apply(fromPersonal, lane: personal.id)
        model.recipient = work.id
        model.draft = "Check the release checklist"

        #expect(
          model.rows.first { $0.id == "send:B" }?.receipts == [
            Receipt(lane: work.id, status: .placed),
            Receipt(lane: personal.id, status: .pending(.uncertain, inputID: "personal-lisbon")),
          ])
        #expect(model.rows.first { $0.id == "send:A" }?.receipts.count == 1)
        #expect(model.rows.filter { $0.row.text == broadcast }.count == 1, "The broadcast folds")
        #expect(TranscriptItem.runStarts(model.transcriptItems).count == 5)
        #expect(model.recipientLine == "To Work")
        func render(_ scheme: ColorScheme) async throws -> CGImage {
          let dimensions = CGSize(width: 390, height: 844)
          let host = UIHostingController(
            rootView: MainChatView(model: model).environment(\.colorScheme, scheme))
          let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
          let previousWindow = scene.windows.first(where: \.isKeyWindow)
          let window = UIWindow(windowScene: scene)
          window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
          let container = UIViewController()
          window.rootViewController = container
          window.makeKeyAndVisible()
          defer {
            window.isHidden = true
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            window.rootViewController = nil
            previousWindow?.makeKey()
          }
          window.layoutIfNeeded()
          container.addChild(host)
          container.view.addSubview(host.view)
          host.view.frame = CGRect(origin: .zero, size: dimensions)
          host.didMove(toParent: container)
          host.view.layoutIfNeeded()
          try await Task.sleep(for: .milliseconds(100))
          host.view.layoutIfNeeded()
          let format = UIGraphicsImageRendererFormat()
          format.scale = 1
          format.preferredRange = .standard
          return try #require(
            UIGraphicsImageRenderer(size: dimensions, format: format).image { _ in
              #expect(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }.cgImage)
        }
        for scheme in [ColorScheme.light, .dark] {
          let image = try await render(scheme)
          try requireVisibleContent(image)
          if scheme == .light {
            #expect(try pixels(near: (0.11, 0.31, 0.85), in: image) > 20, "Work's blue label")
            #expect(try pixels(near: (0.76, 0.25, 0.05), in: image) > 20, "Personal's orange label")
          }
          Attachment.record(image, named: "two-coordinator-feed-\(scheme)", as: .png)
        }

        let systemRed = (1.0, 0.23, 0.19)
        model.recipient = nil
        model.draft = "@"
        #expect(model.recipientLine == "Choose a coordinator" && !model.pickerMatches.isEmpty)
        let picking = try await render(.light)
        Attachment.record(picking, named: "two-coordinator-picker-hint", as: .png)
        #expect(try pixels(near: systemRed, in: picking) == 0, "An open picker is not an error")
        model.draft = "@Nobody check the invented report"
        let unknown = try await render(.light)
        #expect(try pixels(near: systemRed, in: unknown) > 0, "An unknown tag is an error")
      }

      /// The chip stays on the draft's first line, one line tall, however long its name or large
      /// the text. Its frame is all a tap can hit, so no line of the draft reaches into it: text
      /// beside it starts after it, and wrapped lines start under it at the field's leading edge.
      @MainActor @Test func theChipStaysInsideTheDraftsFirstLineAtEveryTextSize() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft =
          "Synthetic draft wraps under its recipient chip and remains readable. Second sentence ends here."
        let sizes: [UIContentSizeCategory] = [
          .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge,
          .extraExtraExtraLarge, .accessibilityMedium, .accessibilityLarge,
          .accessibilityExtraLarge, .accessibilityExtraExtraLarge,
          .accessibilityExtraExtraExtraLarge,
        ]
        let cases = sizes.map { ("Personal", $0) } + [(String(repeating: "W", count: 32), .large)]
        for (name, size) in cases {
          let chosen = CoordinatorProfile(
            name: try TagName(name), address: try CoordinatorAddress(host: "100.64.1.2"))
          let other = CoordinatorProfile(
            name: try TagName("Other"), address: try CoordinatorAddress(host: "100.64.1.3"))
          let model = ChatModel()
          model.profiles = [chosen, other]
          for profile in model.profiles {
            let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
            model.attach(
              Lane(
                id: profile.id,
                session: CoordinatorSession(
                  directory: directory, address: profile.address, pin: CoordinatorID(UUID()),
                  stamps: StampSource()),
                hold: LegacyHold(directory)))
          }
          model.recipient = chosen.id
          model.draft = draft
          let host = UIHostingController(rootView: MainChatView(model: model))
          host.traitOverrides.preferredContentSizeCategory = size
          let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
          let previousWindow = scene.windows.first(where: \.isKeyWindow)
          let window = UIWindow(windowScene: scene)
          window.rootViewController = host
          window.makeKeyAndVisible()
          defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
          }
          window.layoutIfNeeded()
          try await Task.sleep(for: .milliseconds(300))
          host.view.layoutIfNeeded()
          func boxes(_ view: UIView) -> [ComposerField.DraftBox] {
            (view as? ComposerField.DraftBox).map { [$0] } ?? view.subviews.flatMap(boxes)
          }
          let box = try #require(boxes(host.view).first)
          let chip = try #require(box.subviews.compactMap { $0 as? UIButton }.first)
          let field = box.draft
          let inset = ComposerField.inset
          let label = "\(name) at \(size.rawValue)"
          // Each line of the draft where TextKit places a tap, in the field's coordinates.
          var lines: [CGRect] = []
          let layout = try #require(field.textLayoutManager)
          layout.enumerateTextLayoutFragments(
            from: layout.documentRange.location, options: [.ensuresLayout]
          ) { fragment in
            for line in fragment.textLineFragments {
              lines.append(
                line.typographicBounds.offsetBy(
                  dx: field.textContainerInset.left + fragment.layoutFragmentFrame.minX,
                  dy: field.textContainerInset.top + fragment.layoutFragmentFrame.minY))
            }
            return true
          }
          let font = try #require(field.font)
          #expect(chip.frame.minY == inset.top, "\(label): the chip starts on the first line")
          #expect(chip.frame.height == font.lineHeight, "\(label): the chip is one line tall")
          #expect(
            try #require(chip.titleLabel).frame.height <= chip.frame.height + 0.5,
            "\(label): the chip's name takes one line")
          #expect(
            chip.frame.maxX <= box.bounds.width - inset.right, "\(label): a long name truncates")
          #expect(
            lines.allSatisfy { $0.minX >= chip.frame.maxX || $0.minY >= chip.frame.maxY },
            "\(label): no line reaches into the chip")
          let under = try #require(
            lines.first { $0.minY >= chip.frame.maxY }, "\(label): the draft wraps")
          #expect(
            abs(under.minX - inset.left) < 0.5,
            "\(label): wrapped lines start under the chip at the field's leading edge")
          #expect(
            under.minY - chip.frame.maxY < font.lineHeight / 2,
            "\(label): the line under the chip is the next one")
          let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
          }
          Attachment.record(
            try #require(image.cgImage), named: "chip-\(name.prefix(8))-\(size.rawValue)", as: .png)
        }
      }

      /// VoiceOver reads the chip, then the draft, while all of the chip shows. Scrolled out of the
      /// field, the chip is not an element, so VoiceOver cannot find it over the feed, and the
      /// draft's own action still removes the recipient.
      @MainActor @Test func voiceOverReachesTheChipOnlyWhileItShowsAndTheDraftCanRemoveIt()
        async throws
      {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = CoordinatorProfile(
          name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
        let personal = CoordinatorProfile(
          name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3"))
        let model = ChatModel()
        model.profiles = [work, personal]
        for profile in model.profiles {
          let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
          model.attach(
            Lane(
              id: profile.id,
              session: CoordinatorSession(
                directory: directory, address: profile.address, pin: CoordinatorID(UUID()),
                stamps: StampSource()),
              hold: LegacyHold(directory)))
        }
        model.recipient = work.id
        model.draft = (1...10).map { "Invented line \($0) for Work only" }.joined(separator: "\n")
        let host = UIHostingController(rootView: MainChatView(model: model))
        let scene = try #require(
          UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
          window.isHidden = true
          window.rootViewController = nil
          previousWindow?.makeKey()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        func boxes(_ view: UIView) -> [ComposerField.DraftBox] {
          (view as? ComposerField.DraftBox).map { [$0] } ?? view.subviews.flatMap(boxes)
        }
        let box = try #require(boxes(host.view).first)
        let chip = try #require(box.subviews.compactMap { $0 as? UIButton }.first)
        let field = box.draft
        func elements() -> [AnyObject] { (box.accessibilityElements ?? []).map { $0 as AnyObject } }
        #expect(elements().count == 2 && elements().first === chip && elements().last === field)
        #expect(chip.accessibilityLabel == "To Work")
        field.setContentOffset(
          CGPoint(x: 0, y: field.contentSize.height - field.bounds.height), animated: false)
        box.layoutIfNeeded()
        #expect(chip.frame.maxY <= 0, "The chip scrolled out with the first line")
        #expect(elements().count == 1 && elements().first === field)
        let action = try #require(
          field.accessibilityCustomActions?.first { $0.name == "Remove recipient" })
        #expect(action.actionHandler?(action) == true)
        #expect(model.recipient == nil)
      }

      /// The feed and composer of a model with Work and Personal saved, in a key window, with the
      /// composer's field focused.
      @MainActor private func withComposer(
        _ body:
          @MainActor (ChatModel, ComposerField.DraftBox, CoordinatorProfile)
          async throws -> Void
      ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = CoordinatorProfile(
          name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
        let personal = CoordinatorProfile(
          name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3"))
        let model = ChatModel()
        model.profiles = [work, personal]
        for profile in model.profiles {
          let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
          model.attach(Lane(id: profile.id, session: nil, hold: LegacyHold(directory)))
        }
        // The ink check reads dark text, whatever appearance an earlier test left the app in.
        let defaults = UserDefaults.standard
        let appearance = defaults.object(forKey: AppAppearance.preferenceKey)
        defaults.set(AppAppearance.light.rawValue, forKey: AppAppearance.preferenceKey)
        defer { defaults.set(appearance, forKey: AppAppearance.preferenceKey) }
        let host = UIHostingController(rootView: MainChatView(model: model))
        let scene = try #require(
          UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
          window.isHidden = true
          window.rootViewController = nil
          previousWindow?.makeKey()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        func boxes(_ view: UIView) -> [ComposerField.DraftBox] {
          (view as? ComposerField.DraftBox).map { [$0] } ?? view.subviews.flatMap(boxes)
        }
        let box = try #require(boxes(host.view).first)
        box.draft.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(200))
        try await body(model, box, work)
      }

      /// "@Work " typed before an existing draft becomes the chip, and the caret stays at the edit,
      /// moved back by the tag the text lost, so the next word lands where the user was typing.
      @MainActor @Test func aTagTypedBeforeTheDraftLeavesTheCaretAtTheEdit() async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          model.draft = "Existing invented note"
          try await Task.sleep(for: .milliseconds(200))
          field.selectedRange = NSRange(location: 0, length: 0)
          field.insertText("@Work ")
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF7-V2[caret] after the tag: text=\(field.text.debugDescription) selection=\(field.selectedRange) recipient=\(model.recipient.map(model.name) ?? "nil")"
          )
          #expect(model.recipient == work.id && field.text == "Existing invented note")
          #expect(field.selectedRange == NSRange(location: 0, length: 0))
          field.insertText("Prefix ")
          try await Task.sleep(for: .milliseconds(200))
          print("IF7-V2[caret] next edit=\(model.draft.debugDescription)")
          #expect(model.draft == "Prefix Existing invented note")
        }
      }

      /// The draft's text already starts with "@Work", and the user types "@Work " before it. The
      /// typed tag becomes the chip, and the caret moves back by exactly the tag the draft lost, so
      /// it stays before the old "@Work" and the next key lands where the user typed.
      @MainActor @Test func aTagTypedBeforeTheSameTagLeavesTheCaretAtTheEdit() async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          let original = "@Work invented quotation"
          model.recipient = work.id
          model.draft = original
          try await Task.sleep(for: .milliseconds(250))
          model.recipient = nil
          try await Task.sleep(for: .milliseconds(200))
          field.selectedRange = NSRange(location: 0, length: 0)
          field.insertText("@Work ")
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF8-W4 after the tag: text=\(field.text.debugDescription) selection=\(field.selectedRange) chip=\(model.recipient.map(model.name) ?? "none")"
          )
          #expect(model.recipient == work.id && field.text == original)
          #expect(field.selectedRange == NSRange(location: 0, length: 0))
          field.insertText("Prefix ")
          try await Task.sleep(for: .milliseconds(200))
          print("IF8-W4 next key: \(model.draft.debugDescription)")
          #expect(model.draft == "Prefix " + original)
        }
      }

      /// "@Work " typed before an existing draft becomes the chip. Undo then never removes text the
      /// user did not just insert, so the draft stays whole, and Undo and Redo keep working for what
      /// the user types next.
      @MainActor @Test func undoAfterATagBecomesTheChipKeepsTheDraft() async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          field.insertText("Existing invented note")
          try await Task.sleep(for: .milliseconds(200))
          field.selectedRange = NSRange(location: 0, length: 0)
          field.insertText("@Work ")
          try await Task.sleep(for: .milliseconds(300))
          let undo = try #require(field.undoManager)
          print(
            "IF8-W3 after the tag: canUndo=\(undo.canUndo) text=\(model.draft.debugDescription) chip=\(model.recipient.map(model.name) ?? "none")"
          )
          undo.undo()
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF8-W3 undone: text=\(model.draft.debugDescription) chip=\(model.recipient.map(model.name) ?? "none")"
          )
          #expect(model.draft == "Existing invented note")
          undo.redo()
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF8-W3 redone: text=\(model.draft.debugDescription) chip=\(model.recipient.map(model.name) ?? "none")"
          )
          #expect(model.draft == "Existing invented note" && model.recipient == work.id)
          field.selectedRange = NSRange(location: field.text.utf16.count, length: 0)
          field.insertText(" today")
          try await Task.sleep(for: .milliseconds(200))
          undo.undo()
          try await Task.sleep(for: .milliseconds(200))
          let undone = model.draft
          undo.redo()
          try await Task.sleep(for: .milliseconds(200))
          print(
            "IF8-W3 typed next: undone=\(undone.debugDescription) redone=\(model.draft.debugDescription)"
          )
          #expect(undone == "Existing invented note", "Undo of what the user typed next")
          #expect(model.draft == "Existing invented note today", "Redo of what the user typed next")
        }
      }

      /// Ordinary Undo and Redo work in the field, and text an input method is still composing
      /// survives an update of the model.
      @MainActor @Test func ordinaryUndoAndMarkedTextSurviveModelUpdates() async throws {
        try await withComposer { model, box, _ in
          let field = box.draft
          field.insertText("Invented")
          try await Task.sleep(for: .milliseconds(200))
          let undo = try #require(field.undoManager)
          undo.undo()
          try await Task.sleep(for: .milliseconds(200))
          #expect(model.draft.isEmpty)
          undo.redo()
          try await Task.sleep(for: .milliseconds(200))
          #expect(model.draft == "Invented")
          field.selectedRange = NSRange(location: field.text.utf16.count, length: 0)
          field.setMarkedText("\u{4EEE}", selectedRange: NSRange(location: 1, length: 0))
          try await Task.sleep(for: .milliseconds(200))
          print(
            "IF8-W3 input method: text=\(model.draft.debugDescription) marked=\(field.markedTextRange != nil)"
          )
          #expect(field.markedTextRange != nil)
          field.unmarkText()
          #expect(model.draft == "Invented\u{4EEE}")
        }
      }

      /// Restores a message held for `profile`, with `text` and, if `file` names one, an invented
      /// file, into the hosted composer.
      @MainActor private func restoreHeld(
        _ text: String, file: String? = nil, model: ChatModel, from profile: CoordinatorProfile
      ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
        var attachments: [AttachmentRef]?
        if let file {
          let store = AttachmentStore(directory: directory.legacy.appending(path: "Attachments"))
          let staged = try await store.stage(
            data: Data("Invented: \(file)".utf8), name: file, mediaType: "text/plain")
          attachments = [staged.reference]
        }
        try writePrivately(
          JSONEncoder().encode([
            NativeRequestSubmit(
              attachments: attachments, inputId: UUID().uuidString, mode: .steer, text: text)
          ]), to: directory.legacy.appending(path: "pending.json"))
        let hold = LegacyHold(directory)
        model.attach(Lane(id: profile.id, session: nil, hold: hold))
        let item = try #require(try await hold.items().first)
        await model.restoreHeld(HeldMessage(lane: profile.id, item: item))
        try await Task.sleep(for: .milliseconds(250))
      }

      /// A message held for Work is restored. Its text is a heading line, then "@Personal …". After
      /// the chip's ⓧ the user selects the heading in the field and deletes it. The tag now at the
      /// start is the restored text's own, so it stays text and no chip appears.
      @MainActor @Test func deletingARestoredHeadingInTheFieldPromotesNothing() async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          let heading = "Invented memo heading\n"
          let body = "@Personal invented quotation"
          try await restoreHeld(heading + body, model: model, from: work)
          model.recipient = nil
          try await Task.sleep(for: .milliseconds(200))
          field.selectedRange = NSRange(location: 0, length: heading.utf16.count)
          field.deleteBackward()
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF8-W2[field] deleting the selected heading: text=\(model.draft.debugDescription) chip=\(model.recipient.map(model.name) ?? "none")"
          )
          #expect(model.recipient == nil)
          #expect(model.draft == body)
        }
      }

      /// A message held for Work starts with "@Personal". The user restores it, removes its chip and
      /// empties the field, deleting all of its text at once, cutting it, or deleting it key by key.
      /// That ends the restored draft, and the field's Undo never reaches back past it, so Undo and
      /// Redo bring nothing back. The held message is still there to restore. Undo and Redo still
      /// work for what the user types next.
      @MainActor @Test(arguments: ["delete", "cut", "keys"])
      func undoAfterEmptyingARestoredDraftBringsNothingBack(_ how: String) async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          let text = "@Personal invented quotation from Work"
          try await restoreHeld(text, model: model, from: work)
          model.recipient = nil
          try await Task.sleep(for: .milliseconds(200))
          let undo = try #require(field.undoManager)
          field.selectedRange = NSRange(location: 0, length: field.text.utf16.count)
          switch how {
          case "cut": field.cut(nil)
          case "keys":
            field.selectedRange = NSRange(location: field.text.utf16.count, length: 0)
            // One key per turn of the run loop, as a person types, so the field records the run
            // of keys as one step at its first key.
            for _ in text {
              field.deleteBackward()
              try await Task.sleep(for: .milliseconds(30))
            }
          default: field.deleteBackward()
          }
          try await Task.sleep(for: .milliseconds(300))
          let emptied = model.draft
          let canUndo = undo.canUndo
          undo.undo()
          try await Task.sleep(for: .milliseconds(300))
          let undone = model.draft
          undo.redo()
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF10-2[\(how)] emptied=\(emptied.debugDescription) canUndo=\(canUndo) undone: chip=\(model.recipient.map(model.name) ?? "none") draft=\(undone.debugDescription) redone=\(model.draft.debugDescription) field=\(field.text.debugDescription) held=\(model.held.count)"
          )
          #expect(emptied.isEmpty)
          #expect(undone.isEmpty, "Undo brought back the cleared restored text")
          #expect(model.draft.isEmpty && field.text.isEmpty, "Redo brought back restored text")
          #expect(model.recipient == nil)
          #expect(model.held.count == 1, "The held message is gone")
          field.insertText("Invented new note")
          try await Task.sleep(for: .milliseconds(200))
          undo.undo()
          try await Task.sleep(for: .milliseconds(200))
          let typedUndone = model.draft
          undo.redo()
          try await Task.sleep(for: .milliseconds(200))
          print(
            "IF10-2[\(how)] typed next: undone=\(typedUndone.debugDescription) redone=\(model.draft.debugDescription)"
          )
          #expect(typedUndone.isEmpty, "Undo of what the user typed next")
          #expect(model.draft == "Invented new note", "Redo of what the user typed next")
        }
      }

      /// The same restored draft, chip removed. The user cuts all of its text, which empties the
      /// composer and ends the restored draft, and pastes it back. Pasted text is typed text, as text
      /// typed again is, so its leading "@Personal " becomes the chip.
      @MainActor @Test func textPastedIntoAnEmptiedRestoredDraftIsTyped() async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          let personal = try #require(model.profiles.last?.id)
          let text = "@Personal invented: forward Work's board deck to the auditors"
          try await restoreHeld(text, model: model, from: work)
          model.recipient = nil
          try await Task.sleep(for: .milliseconds(200))
          field.selectedRange = NSRange(location: 0, length: field.text.utf16.count)
          field.cut(nil)
          try await Task.sleep(for: .milliseconds(300))
          field.paste(nil)
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF9-Y2[paste] chip=\(model.recipient.map(model.name) ?? "none") draft=\(model.draft.debugDescription)"
          )
          #expect(model.recipient == personal)
          #expect(model.draft == "invented: forward Work's board deck to the auditors")
        }
      }

      /// The user edits Work's restored draft, its chip removed, without emptying it, so it stays
      /// restored and literal: pastes other text over all of it, pastes the same text over it, or
      /// types into a restored message that has only a file. Then the user empties the composer,
      /// text and file, which ends the restored draft, and Undo brings nothing back.
      @MainActor @Test(arguments: ["other text pasted", "the same text pasted", "typed by a file"])
      func undoAfterEmptyingAnEditedRestoredDraftBringsNothingBack(_ edit: String) async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          var text = "@Personal invented quotation from Work"
          switch edit {
          case "typed by a file":
            try await restoreHeld("", file: "Deck.txt", model: model, from: work)
            model.recipient = nil
            try await Task.sleep(for: .milliseconds(300))
            text = "@Personal invented quotation for both"
            for character in text {
              field.insertText(String(character))
              try await Task.sleep(for: .milliseconds(30))
            }
          case "other text pasted":
            try await restoreHeld("Invented restored Work note", model: model, from: work)
            model.recipient = nil
            try await Task.sleep(for: .milliseconds(200))
            text = "@Personal invented replacement while still restored"
            UIPasteboard.general.string = text
            field.selectedRange = NSRange(location: 0, length: field.text.utf16.count)
            field.paste(nil)
          default:
            try await restoreHeld(text, model: model, from: work)
            model.recipient = nil
            try await Task.sleep(for: .milliseconds(200))
            field.selectedRange = NSRange(location: 0, length: field.text.utf16.count)
            field.copy(nil)
            field.paste(nil)
          }
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF10-2[\(edit)] before emptying: chip=\(model.recipient.map(model.name) ?? "none") restoredFrom=\(model.restoredFrom.map(model.name) ?? "none") draft=\(model.draft.debugDescription) files=\(model.attachments.count)"
          )
          #expect(model.restoredFrom == work.id && model.recipient == nil && model.draft == text)
          field.selectedRange = NSRange(location: 0, length: field.text.utf16.count)
          field.deleteBackward()
          try await Task.sleep(for: .milliseconds(200))
          for file in model.attachments { await model.removeAttachment(file) }
          try await Task.sleep(for: .milliseconds(200))
          field.undoManager?.undo()
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF10-2[\(edit)] after Undo: chip=\(model.recipient.map(model.name) ?? "none") draft=\(model.draft.debugDescription) field=\(field.text.debugDescription) files=\(model.attachments.count)"
          )
          #expect(model.draft.isEmpty && field.text.isEmpty, "Undo brought back restored text")
          #expect(model.recipient == nil)
        }
      }

      /// A Restore ends the field's Undo even when it puts in only a file, so Undo never brings what
      /// the composer held before into the restored message. Before Personal's held message with only
      /// a file is restored, the field held Work's restored text, or text the user typed, and the user
      /// deleted it.
      @MainActor @Test(arguments: ["Work's restored text", "typed text"])
      func undoAfterAFileOnlyRestoreBringsNothingBack(_ before: String) async throws {
        try await withComposer { model, box, work in
          let field = box.draft
          let personal = try #require(model.profiles.last)
          let text = "Invented: Work's merger memo for the board"
          if before == "typed text" {
            field.insertText(text)
          } else {
            try await restoreHeld(text, model: model, from: work)
          }
          try await Task.sleep(for: .milliseconds(200))
          field.selectedRange = NSRange(location: 0, length: field.text.utf16.count)
          field.deleteBackward()
          try await Task.sleep(for: .milliseconds(300))
          try await restoreHeld("", file: "Receipt.txt", model: model, from: personal)
          let undo = try #require(field.undoManager)
          let canUndo = undo.canUndo
          undo.undo()
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF10-2[file-only Restore after \(before)] canUndo=\(canUndo) after Undo: chip=\(model.shownChip.map(model.name) ?? "none") draft=\(model.draft.debugDescription) files=\(model.attachments.map(\.reference.name))"
          )
          #expect(model.draft.isEmpty && field.text.isEmpty, "Undo brought text into Personal's")
          #expect(model.recipient == personal.id)
          #expect(model.attachments.map(\.reference.name) == ["Receipt.txt"])
        }
      }

      /// With Work the only coordinator saved, the user restores its held message, which binds it to
      /// Work with no chip, and deletes its text. Undo brings nothing back, before Personal is added
      /// or after, through a sheet whose own text field takes the keyboard, as Settings' does. No
      /// text is left that could go to Personal.
      @MainActor @Test(arguments: ["undo, then add", "add through a sheet, then undo"])
      func undoAfterClearingARestoredDraftWithOneCoordinatorBringsNothingBack(_ order: String)
        async throws
      {
        try await withComposer { model, box, work in
          let field = box.draft
          let personal = try #require(model.profiles.last)
          let personalLane = try #require(model.lanes.first { $0.id == personal.id })
          await model.detach(personal.id)
          model.profiles = [work]
          try await Task.sleep(for: .milliseconds(200))
          let text = "Invented: Work's merger memo for the board"
          try await restoreHeld(text, model: model, from: work)
          let bound = model.recipient
          field.selectedRange = NSRange(location: 0, length: field.text.utf16.count)
          field.deleteBackward()
          try await Task.sleep(for: .milliseconds(300))
          if order == "undo, then add" {
            field.undoManager?.undo()
            try await Task.sleep(for: .milliseconds(300))
            model.profiles = [work, personal]
            model.attach(personalLane)
          } else {
            let host = try #require(box.window?.rootViewController)
            let sheet = UIViewController()
            let address = UITextField(frame: CGRect(x: 20, y: 100, width: 300, height: 44))
            sheet.view.addSubview(address)
            host.present(sheet, animated: false)
            try await Task.sleep(for: .milliseconds(400))
            address.becomeFirstResponder()
            address.insertText("100.64.1.3")
            try await Task.sleep(for: .milliseconds(200))
            model.profiles = [work, personal]
            model.attach(personalLane)
            address.resignFirstResponder()
            sheet.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(400))
            field.becomeFirstResponder()
            try await Task.sleep(for: .milliseconds(200))
            field.undoManager?.undo()
          }
          try await Task.sleep(for: .milliseconds(300))
          print(
            "IF10-2[one coordinator, \(order)] restored: recipient=\(bound.map(model.name) ?? "none") with Personal added, after Undo: draft=\(model.draft.debugDescription) recipient=\(model.recipient.map(model.name) ?? "none") chip=\(model.shownChip.map(model.name) ?? "none") line=\(model.recipientLine)"
          )
          #expect(bound == work.id, "Restore did not bind the draft to Work")
          #expect(model.draft.isEmpty && field.text.isEmpty, "Undo brought back Work's text")
          #expect(model.recipient == nil)
        }
      }

      /// The user types a line after the chip and its ⓧ removes the chip. Then the user types more,
      /// and the chip comes back. Each time the chip comes or goes, the draft is drawn at once where
      /// its layout puts it, at the field's leading edge without the chip and after it with one, so
      /// the caret and taps land on what is drawn.
      @MainActor @Test func theDraftIsDrawnWhereItsLayoutPutsItWhenTheChipComesOrGoes()
        async throws
      {
        try await withComposer { model, box, work in
          let field = box.draft
          model.recipient = work.id
          try await Task.sleep(for: .milliseconds(200))
          field.insertText("Invented one line")
          try await Task.sleep(for: .milliseconds(300))
          /// The leftmost and rightmost dark pixels of the first line as the field draws it.
          func drawn() throws -> (minX: CGFloat, maxX: CGFloat) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: field.bounds, format: format).image { _ in
              field.drawHierarchy(in: field.bounds, afterScreenUpdates: true)
            }
            let cg = try #require(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try #require(
              CGContext(
                data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let top = Int(field.textContainerInset.top)
            let bottom = min(cg.height, top + Int(try #require(field.font).lineHeight))
            var span = (minX: CGFloat.infinity, maxX: -CGFloat.infinity)
            for y in top..<bottom {
              for x in 0..<cg.width {
                let pixel = (y * cg.width + x) * 4
                let rgb = Int(pixels[pixel]) + Int(pixels[pixel + 1]) + Int(pixels[pixel + 2])
                if pixels[pixel + 3] > 128 && rgb < 330 {
                  span = (min(span.minX, CGFloat(x)), max(span.maxX, CGFloat(x)))
                }
              }
            }
            return span
          }
          /// Where TextKit puts the first line, which is where a tap or the caret finds it.
          func laidOut() throws -> CGFloat {
            let layout = try #require(field.textLayoutManager)
            var starts: [CGFloat] = []
            layout.enumerateTextLayoutFragments(
              from: layout.documentRange.location, options: [.ensuresLayout]
            ) { fragment in
              starts += fragment.textLineFragments.map {
                field.textContainerInset.left + fragment.layoutFragmentFrame.minX
                  + $0.typographicBounds.minX
              }
              return false
            }
            return try #require(starts.first)
          }
          let steps: [(String, ProfileID?, String)] = [
            ("with the chip", work.id, ""), ("chip removed", nil, ""),
            ("typed without the chip", nil, " two"), ("chip back", work.id, ""),
          ]
          for (step, chip, typed) in steps {
            if !typed.isEmpty { field.insertText(typed) }
            model.recipient = chip
            try await Task.sleep(for: .milliseconds(100))
            box.window?.layoutIfNeeded()
            let line = try laidOut()
            let ink = try drawn()
            let end = field.caretRect(for: field.endOfDocument).midX
            print(
              "IF7-V2[draw] \(step): line x=\(line) drawn=\(ink.minX)...\(ink.maxX) caret at end=\(end)"
            )
            #expect(abs(ink.minX - line) < 4, "\(step): the first line is drawn where taps find it")
            #expect(abs(ink.maxX - end) < 4, "\(step): the caret is drawn after the last letter")
            if chip == nil && typed.isEmpty {
              let edge = ComposerField.inset.left
              #expect(abs(line - edge) < 0.5, "The first line keeps the chip's room")
              #expect(
                abs(field.caretRect(for: field.beginningOfDocument).midX - edge) < 0.5,
                "The caret keeps the chip's room")
            }
          }
        }
      }

      @MainActor @Test func accessibilityTextSizeExpandsMessageLayout() async throws {
        var transcript = Transcript()
        transcript.message(
          .init(
            attachments: nil, continuation: false, entryId: "long-answer", finalChunk: true,
            role: .final,
            text: """
              This answer should wrap at the phone's available width. Increasing the preferred text size
              must increase the row's height so that the full message remains readable.
              """, tool: nil))
        let standard = try await renderRows(transcript.rows)
        let accessible = try await renderRows(transcript.rows, size: .accessibility3)
        #expect(standard.width == accessible.width)
        #expect(accessible.height > standard.height)
        Attachment.record(accessible, named: "message-accessibility", as: .png)
      }
    #endif
  }

#endif
