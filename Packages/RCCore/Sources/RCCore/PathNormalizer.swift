import Foundation

public enum PathNormalizer {
    /// Expands `~`, standardizes, and strips any trailing slash.
    public static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

/// Parses `dirs.txt` the same way `start.sh` does: `#` starts a comment,
/// surrounding whitespace and blank lines are dropped, `~` is expanded.
public enum DirsFile {
    public static func parse(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                var value = Substring(line)
                if let hash = value.firstIndex(of: "#") {
                    value = value[..<hash]
                }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return PathNormalizer.normalize(trimmed)
            }
    }
}
