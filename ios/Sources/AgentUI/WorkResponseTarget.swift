import AgentCore

struct WorkResponseTarget: Equatable, Sendable {
  let reference: WorkResponseReference
  let laneEpoch: Int?
}

extension WorkResponseReference {
  var excerpt: String {
    [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  func message(with response: String) -> String {
    let fields: [(String, String?)] = [
      ("Coordinator", coordinator),
      ("Work item ID", itemID),
      ("Conversation ID", conversationID),
      ("Task ID", taskID),
      ("Child agent ID", agentID),
      ("Job", isJob ? "yes" : nil),
      ("Side chat", sidechatSlug),
      ("Title", title),
      ("Detail", detail),
    ]
    let context = fields.compactMap { label, value in
      value.map { "\(label): \(String(reflecting: $0))" }
    }.joined(separator: "\n")
    return """
      Quoted work item context for reference:
      \(context)

      My response:
      \(response)
      """
  }
}
