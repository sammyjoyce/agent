import SwiftUI

/// Shared quoted-message banner used for composer reply targets and inline reply cards.
struct QuotedMessageBar<Trailing: View>: View {
  let heading: String
  let excerpt: String
  let accentColor: Color
  let lineLimit: Int
  let excerptColor: Color
  let headingFont: Font
  let trailing: Trailing

  init(
    heading: String,
    excerpt: String,
    accentColor: Color = .secondary,
    lineLimit: Int = 2,
    excerptColor: Color = .primary,
    headingFont: Font = .caption.weight(.semibold),
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.heading = heading
    self.excerpt = excerpt
    self.accentColor = accentColor
    self.lineLimit = lineLimit
    self.excerptColor = excerptColor
    self.headingFont = headingFont
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 2)
        .fill(accentColor)
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 2) {
        Text(heading)
          .font(headingFont)
          .foregroundStyle(.secondary)
        if !excerpt.isEmpty {
          Text(excerpt)
            .font(.caption)
            .foregroundStyle(excerptColor)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
        }
      }
      trailing
    }
  }
}
