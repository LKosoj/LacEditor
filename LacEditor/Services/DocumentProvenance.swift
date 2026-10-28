import Foundation

final class DocumentProvenance {
    enum Source: String, CaseIterable {
        case unknown, typed, pasted, generated

        var title: String {
            switch self {
            case .unknown: L10n.tr("来源未知")
            case .typed: L10n.tr("手动输入")
            case .pasted: L10n.tr("粘贴文本")
            case .generated: L10n.tr("内置 AI 生成")
            }
        }
    }

    struct Fragment: Equatable {
        var range: NSRange
        let source: Source
    }

    private(set) var fragments: [Fragment] = []
    private(set) var isEnabled = false
    private var length = 0

    func configure(enabled: Bool, length: Int) {
        if !enabled {
            isEnabled = false
            fragments = []
            self.length = 0
        } else if !isEnabled || self.length != length {
            isEnabled = true
            self.length = length
            fragments = length > 0 ? [Fragment(range: NSRange(location: 0, length: length), source: .unknown)] : []
        }
    }

    func record(editedRange: NSRange, replacementLength: Int, source: Source) {
        guard isEnabled else { return }
        guard editedRange.location != NSNotFound, editedRange.location <= length,
              editedRange.length <= length - editedRange.location, replacementLength >= 0 else {
            // An edit without a matching prior range cannot establish provenance.
            fragments = length > 0 ? [Fragment(range: NSRange(location: 0, length: length), source: .unknown)] : []
            return
        }
        let end = NSMaxRange(editedRange)
        let change = replacementLength - editedRange.length
        var result: [Fragment] = []
        for fragment in fragments {
            let start = fragment.range.location
            let fragmentEnd = NSMaxRange(fragment.range)
            if start < editedRange.location {
                let prefixEnd = min(fragmentEnd, editedRange.location)
                if prefixEnd > start {
                    result.append(Fragment(range: NSRange(location: start, length: prefixEnd - start), source: fragment.source))
                }
            }
            if fragmentEnd > end {
                let suffixStart = max(start, end)
                result.append(Fragment(range: NSRange(location: suffixStart + change, length: fragmentEnd - suffixStart), source: fragment.source))
            }
        }
        if replacementLength > 0 {
            result.append(Fragment(range: NSRange(location: editedRange.location, length: replacementLength), source: source))
        }
        result.sort { $0.range.location < $1.range.location }
        fragments = []
        for fragment in result {
            if let last = fragments.last, last.source == fragment.source,
               NSMaxRange(last.range) == fragment.range.location {
                fragments[fragments.count - 1].range.length += fragment.range.length
            } else {
                fragments.append(fragment)
            }
        }
        length += change
    }

    func report() -> String {
        let introduction = L10n.tr("仅记录启用后的输入事件，不检测 AI。撤销、重载或未追踪内容的来源保持未知。重启后不保留记录。")
        let lines = fragments.map {
            L10n.tr("%@：UTF-16 %d–%d", $0.source.title, $0.range.location, NSMaxRange($0.range))
        }
        return ([introduction] + lines).joined(separator: "\n")
    }
}
