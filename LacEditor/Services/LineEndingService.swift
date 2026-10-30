import Foundation

/// Окончания строк: только CR, LF и CRLF, как в cmark. U+2028, U+2029 и NEL остаются содержимым и не конвертируются.
enum LineEnding: String, CaseIterable, Identifiable, Sendable {
    case lf, crlf, cr

    var id: String { rawValue }

    var sequence: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }

    var utf16Length: Int { self == .crlf ? 2 : 1 }

    /// Технические имена, не локализуются.
    var shortName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
}

struct LineEndingSummary: Equatable, Sendable {
    var lf = 0
    var crlf = 0
    var cr = 0

    var total: Int { lf + crlf + cr }

    var isMixed: Bool { [lf, crlf, cr].filter { $0 > 0 }.count > 1 }

    /// Единственный вид переносов; nil, если переносов нет или они смешаны.
    var uniform: LineEnding? {
        guard !isMixed, total > 0 else { return nil }
        return crlf > 0 ? .crlf : (cr > 0 ? .cr : .lf)
    }
}

enum LineEndingService {
    private static let cancellationStride = 1 << 20  // проверка отмены примерно раз в 1 МиБ

    /// Один проход по UTF-8; CRLF считается одним переносом. При отмене возвращает nil.
    nonisolated static func detect(in text: String, isCancelled: () -> Bool = { false }) -> LineEndingSummary? {
        var text = text
        return text.withUTF8 { buffer -> LineEndingSummary? in
            var summary = LineEndingSummary()
            var index = 0
            var nextCheck = 0
            let count = buffer.count
            while index < count {
                if index >= nextCheck {
                    if isCancelled() { return nil }
                    nextCheck = index + cancellationStride
                }
                let byte = buffer[index]
                if byte == 0x0A {
                    summary.lf += 1
                } else if byte == 0x0D {
                    if index + 1 < count, buffer[index + 1] == 0x0A {
                        summary.crlf += 1
                        index += 1
                    } else {
                        summary.cr += 1
                    }
                }
                index += 1
            }
            return summary
        }
    }

    /// Приводит все переносы к одному виду. nil — менять нечего либо операция отменена.
    nonisolated static func convert(_ text: String, to target: LineEnding, isCancelled: () -> Bool = { false }) -> String? {
        guard let summary = detect(in: text, isCancelled: isCancelled),
              summary.total > 0, summary.uniform != target else { return nil }
        let replacement = Array(target.sequence.utf8)
        var text = text
        return text.withUTF8 { buffer -> String? in
            var output: [UInt8] = []
            output.reserveCapacity(buffer.count + summary.total)
            var index = 0
            var nextCheck = 0
            let count = buffer.count
            while index < count {
                if index >= nextCheck {
                    if isCancelled() { return nil }
                    nextCheck = index + cancellationStride
                }
                let byte = buffer[index]
                if byte == 0x0A {
                    output.append(contentsOf: replacement)
                } else if byte == 0x0D {
                    if index + 1 < count, buffer[index + 1] == 0x0A { index += 1 }
                    output.append(contentsOf: replacement)
                } else {
                    output.append(byte)
                }
                index += 1
            }
            return String(decoding: output, as: UTF8.self)
        }
    }

    /// Переводит позицию UTF-16 из старого текста в преобразованный; позиция внутри CRLF встаёт на начало переноса.
    nonisolated static func mappedLocation(_ location: Int, in text: NSString, to target: LineEnding) -> Int {
        let limit = min(max(location, 0), text.length)
        var delta = 0
        var index = 0
        while index < limit {
            let unit = text.character(at: index)
            if unit == 0x0A {
                delta += target.utf16Length - 1
            } else if unit == 0x0D {
                if index + 1 < text.length, text.character(at: index + 1) == 0x0A {
                    // Позиция между CR и LF совпадает с началом нового переноса.
                    if index + 1 >= limit { return index + delta }
                    delta += target.utf16Length - 2
                    index += 1
                } else {
                    delta += target.utf16Length - 1
                }
            }
            index += 1
        }
        return limit + delta
    }
}
