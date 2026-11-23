import SwiftUI
import VigilWire

#if os(macOS)
import AppKit

/// The table `c accounts` and `cx accounts` print, one row per account, in
/// their colours and bars: everything drawn here is what agent-hud's `--json`
/// says (each window's xterm-256 tone and bold, its bar's lit cells, its
/// percent's colour, the table's other colours), mapped through the standard
/// xterm palette once (`AgentAccounts.xterm`). Nothing here decides a tone.
/// Columns line up across rows: a column per window label, as wide as its
/// widest cell, so the rows read down like the terminal's table.
struct AccountTable {
    let accounts: AgentAccounts
    let now: Date
    let size: CGFloat
    let font: Font
    let boldFont: Font
    /// One character's advance in the monospaced font.
    let cell: CGFloat

    let nameColumn: Int
    let emailColumn: Int
    let planColumn: Int
    let labels: [String]
    let labelColumn: [String: Int]
    let resetColumn: [String: Int]

    init(_ accounts: AgentAccounts, marks: (AgentAccounts.Account) -> String?, now: Date, size: CGFloat = 12) {
        self.accounts = accounts
        self.now = now
        self.size = size
        font = .system(size: size, design: .monospaced)
        boldFont = .system(size: size, weight: .bold, design: .monospaced)
        let measured = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cell = ("0" as NSString).size(withAttributes: [.font: measured]).width
        nameColumn = accounts.accounts.map { Self.name($0, marks($0)).count }.max() ?? 0
        emailColumn = accounts.accounts.map { Self.email($0).count }.max() ?? 0
        planColumn = accounts.accounts.map { ($0.plan ?? "").count + ($0.spent ? " SPENT".count : 0) }.max() ?? 0
        labels = accounts.windowLabels
        var labelColumn: [String: Int] = [:], resetColumn: [String: Int] = [:]
        for label in labels {
            labelColumn[label] = label.count
            resetColumn[label] = accounts.accounts.compactMap { $0.limits.first { $0.label == label } }
                .map { Self.reset($0, now: now).count }.max() ?? 0
        }
        self.labelColumn = labelColumn
        self.resetColumn = resetColumn
    }

    static func name(_ account: AgentAccounts.Account, _ marks: String?) -> String {
        account.name + (marks.map { " (\($0))" } ?? "")
    }

    static func reset(_ limit: AgentAccounts.Limit, now: Date) -> String {
        (limit.spent ? "spent " : "") + (limit.resets.map { "↻" + AgentAccounts.left($0, now: now) } ?? "")
    }

    func color(_ index: Int?) -> Color {
        guard let index else { return .primary }
        let c = AgentAccounts.xterm(index)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    private func column(_ chars: Int) -> CGFloat { CGFloat(chars) * cell }

    /// One account's row.
    @ViewBuilder
    func row(_ account: AgentAccounts.Account, marks: String?, icon: String) -> some View {
        let palette = accounts.palette
        HStack(spacing: 0) {
            Image(systemName: icon).font(.system(size: size))
                .foregroundStyle(account.spent || account.loggedOut ? color(palette?.alert) : .primary)
                .frame(width: size * 1.6, alignment: .leading)
            Text(Self.name(account, marks)).font(font).foregroundStyle(color(palette?.name))
                .frame(width: column(nameColumn), alignment: .leading)
            gap
            // Who it signs in as, second, as the table prints it.
            Text(Self.email(account)).font(font)
                .frame(width: column(emailColumn), alignment: .leading)
            gap
            (Text(account.plan ?? "").foregroundStyle(color(palette?.plan))
                + Text(account.spent ? " SPENT" : "").foregroundStyle(color(palette?.alert)))
                .font(font)
                .frame(width: column(planColumn), alignment: .leading)
            if account.loggedOut {
                gap
                Text(account.note ?? "logged out").font(font).foregroundStyle(color(palette?.note))
            } else {
                ForEach(labels, id: \.self) { label in
                    gap
                    window(account.limits.first { $0.label == label }, label: label)
                }
                tail(account)
            }
        }
        .fixedSize()
    }

    static func email(_ account: AgentAccounts.Account) -> String {
        guard let email = account.email, !email.hasPrefix("(") else { return "" }
        return email
    }

    private var gap: some View { Color.clear.frame(width: column(2), height: 1) }

    /// A window's cell: label, bar, percent, reset, or blank where the
    /// account has no such window.
    @ViewBuilder
    private func window(_ limit: AgentAccounts.Limit?, label: String) -> some View {
        let cells = accounts.accounts.compactMap { $0.limits.first { $0.label == label }?.look?.cells }.max() ?? 0
        let width = column((labelColumn[label] ?? 0) + 1 + cells + 1 + 4 + 1 + (resetColumn[label] ?? 0))
        if let limit {
            let palette = accounts.palette
            let percent = String(Int(limit.percent.rounded(.down)))
            let padded = String(repeating: " ", count: max(0, 3 - percent.count)) + percent + "%"
            let look = limit.look
            let tone = color(look?.index)
            HStack(spacing: 0) {
                Text(label).font(look?.bold == true ? boldFont : font).foregroundStyle(tone)
                    .frame(width: column(labelColumn[label] ?? label.count), alignment: .leading)
                Color.clear.frame(width: cell, height: 1)
                if let look { bar(look, tone: tone, track: color(palette?.track)) }
                (Text(" " + padded).font(look?.bold == true ? boldFont : font).foregroundStyle(color(look?.percentIndex))
                    + Text(limit.spent ? " spent" : "").font(font).foregroundStyle(color(palette?.alert))
                    + Text(limit.resets == nil ? "" : " ↻").font(.system(size: size)).foregroundStyle(color(palette?.reset))
                    + Text(limit.resets.map { AgentAccounts.left($0, now: now) } ?? "").font(font).foregroundStyle(color(palette?.reset)))
                    .fixedSize()
            }
            .frame(width: width, alignment: .leading)
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }

    /// agent-hud's bar (`━━━╸────`): `cells` character cells, `full` lit and
    /// one more half lit, the rest track, drawn as a thin line in the
    /// window's tone over the track's, as the terminal's glyphs look.
    private func bar(_ look: AgentAccounts.Look, tone: Color, track: Color) -> some View {
        let lit = (CGFloat(look.full) + (look.half ? 0.5 : 0)) * cell
        let thickness = max(2, size * 0.2)
        return ZStack(alignment: .leading) {
            Capsule().fill(track).frame(width: CGFloat(look.cells) * cell, height: thickness / 2)
            Capsule().fill(tone).frame(width: lit, height: thickness)
        }
        .frame(width: CGFloat(look.cells) * cell, height: size, alignment: .leading)
    }

    /// What `cx accounts` adds after the windows, and why the usage is not
    /// fresh.
    @ViewBuilder
    private func tail(_ account: AgentAccounts.Account) -> some View {
        let palette = accounts.palette
        if let model = account.model {
            gap
            Text(model.available ? "model ✓" : "model ✗" + (model.back.map { " back " + AgentAccounts.left($0, now: now) } ?? ""))
                .font(font).foregroundStyle(color(model.index))
        }
        if let resets = account.resets, resets > 0 {
            gap
            Text("\(resets) reset\(resets == 1 ? "" : "s")").font(font).foregroundStyle(color(palette?.reset))
        }
        if let note = account.note {
            gap
            Text("(\(note))").font(font).foregroundStyle(color(palette?.note))
        }
    }

    /// The row as an image, for a menu item (a menu draws an image as it
    /// is; its title text would lose the colours and the columns). Kept
    /// per reading, row and minute: a menu's body is evaluated often.
    @MainActor
    func image(_ account: AgentAccounts.Account, marks: String?, icon: String, read: Date, scale: CGFloat) -> NSImage? {
        let key = "\(read.timeIntervalSince1970)|\(Int(now.timeIntervalSince1970 / 60))|\(account.name)|\(marks ?? "")|\(icon)|\(scale)|\(nameColumn)|\(planColumn)|\(labels)"
        if let kept = AccountRowImages.kept[key] { return kept }
        let renderer = ImageRenderer(content: row(account, marks: marks, icon: icon).padding(.vertical, 1))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        if AccountRowImages.kept.count > 64 { AccountRowImages.kept.removeAll() }
        AccountRowImages.kept[key] = image
        return image
    }
}

@MainActor
private enum AccountRowImages {
    static var kept: [String: NSImage] = [:]
}
#endif
