import Foundation

/// One process's cumulative traffic from a single `nettop` pass.
struct ProcessTraffic: Equatable {
    /// "name.pid" exactly as nettop prints it — the key rates are diffed on.
    let key: String
    let name: String
    let pid: Int32
    let bytesIn: UInt64
    let bytesOut: UInt64
}

/// Parser for `nettop -P -L 1 -n -k …` CSV output (NET-004). Header-driven: the column
/// order is read from the header line, so a leading `time` column (present when nettop
/// is not told to exclude it) is handled too. Returns `nil` when no usable header is
/// found (empty output, a timeout's partial garbage) so callers can tell "nothing
/// parsed" from "no traffic".
enum NettopParser {
    static func parse(_ output: String) -> [ProcessTraffic]? {
        var lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.contains("bytes_in") && $0.contains("bytes_out") })
        else { return nil }
        let header = fields(lines[headerIndex])
        guard let inColumn = header.firstIndex(of: "bytes_in"),
              let outColumn = header.firstIndex(of: "bytes_out") else { return nil }
        // The process column is the first non-empty-named, non-"time" column; with `-P`
        // nettop leaves its header cell blank, so fall back to "the column after time".
        let nameColumn = header.first == "time" ? 1 : 0
        // With -L 1 there is a single sample, but if nettop ever prints a second header
        // (a second sample), only the first block is used.
        lines = Array(lines[(headerIndex + 1)...])
        var rows: [ProcessTraffic] = []
        for line in lines {
            if line.contains("bytes_in") { break }
            let cells = fields(line)
            guard cells.count > max(inColumn, outColumn, nameColumn),
                  let bytesIn = UInt64(cells[inColumn]),
                  let bytesOut = UInt64(cells[outColumn]),
                  let (name, pid) = split(cells[nameColumn]) else { continue }
            rows.append(ProcessTraffic(key: cells[nameColumn], name: name, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut))
        }
        return rows
    }

    /// "com.apple.WebKit.Networking.1234" → ("com.apple.WebKit.Networking", 1234).
    static func split(_ cell: String) -> (String, Int32)? {
        guard let dot = cell.lastIndex(of: "."),
              let pid = Int32(cell[cell.index(after: dot)...]) else { return nil }
        let name = String(cell[..<dot])
        return name.isEmpty ? nil : (name, pid)
    }

    /// CSV split honouring double quotes (a quoted name may contain commas; `""` is a
    /// literal quote).
    static func fields(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?
        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { current.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
}
