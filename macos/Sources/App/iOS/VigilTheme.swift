import UIKit

/// The phone renders with the Mac's theme, not Ghostty's stock palette:
/// iOS loads no config files, so the theme is written into the app's
/// sandbox at every launch and loaded from there (idempotent; the file
/// is derived, never edited). Catppuccin Mocha = `~/.config/ghostty/config`
/// on Adrian's Macs; the values are the theme file's verbatim.
enum VigilTheme {
    static let config = """
    theme-name = Catppuccin Mocha
    palette = 0=#45475a
    palette = 1=#f38ba8
    palette = 2=#a6e3a1
    palette = 3=#f9e2af
    palette = 4=#89b4fa
    palette = 5=#f5c2e7
    palette = 6=#94e2d5
    palette = 7=#bac2de
    palette = 8=#585b70
    palette = 9=#f7aec2
    palette = 10=#c2ecbf
    palette = 11=#fcd682
    palette = 12=#aeccfc
    palette = 13=#f398da
    palette = 14=#b1eae1
    palette = 15=#a6adc8
    background = #1e1e2e
    foreground = #cdd6f4
    cursor-color = #f5e0dc
    cursor-text = #1e1e2e
    selection-background = #f5e0dc
    selection-foreground = #1e1e2e
    font-size = 8
    """

    /// Writes the config and returns its path (nil only if the sandbox
    /// refuses a write, which is a receipt-worthy failure).
    static func configPath() -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("vigil.ghostty")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try config.replacingOccurrences(of: "theme-name = Catppuccin Mocha\n", with: "")
                .write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            FileHandle.standardError.write(Data("vigil: theme: cannot write \(url.path): \(error)\n".utf8))
            return nil
        }
    }

    /// The transparency checker (Photoshop's, Figma's): the one pattern
    /// everyone reads as "nothing here". Dark, 8pt squares.
    static func checker(scale: CGFloat) -> UIImage {
        let side: CGFloat = 16
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = scale; return f
        }())
        return r.image { ctx in
            UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor(red: 0.17, green: 0.17, blue: 0.22, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side / 2, height: side / 2))
            ctx.fill(CGRect(x: side / 2, y: side / 2, width: side / 2, height: side / 2))
        }
    }
}
