import Compression
import Foundation

// MARK: - VimarMeterImporter

/// Legge l'export consumi del quadro Vimar (xlsx) e lo riduce a punti
/// contatore pronti per la pipeline energia.
///
/// Forma del file (verificata sull'export reale): un solo foglio, due colonne
/// — Timestamp ISO8601 col fuso, Value = **contatore cumulativo in Wh** — un
/// campione ogni 15 minuti. È la stessa natura dei nostri `EnergySample`:
/// stessi delta, stesso smear, stessa gestione degli azzeramenti (il file
/// vero ne contiene uno, e il builder li spezza già per progetto).
///
/// Niente dipendenze: un xlsx è uno zip di XML, e per DUE colonne note basta
/// un lettore mirato — EOCD + central directory + deflate via Compression, e
/// due parser SAX per sharedStrings e foglio. Non è un lettore xlsx generico
/// e non vuole diventarlo.
///
/// Il sottocampionamento è parte del contratto: 33k righe a 15 minuti non
/// servono a nessuna analisi giornaliera — restano il primo e l'ultimo
/// campione di ogni giorno (~730/anno), che attraversano CloudKit senza
/// pesare e danno al builder esattamente i punti di frontiera che gli
/// servono per i totali giornalieri.
enum VimarMeterImporter {

    enum ImportError: LocalizedError {
        case notAZipArchive
        case entryMissing(String)
        case unsupportedCompression
        case corruptArchive
        case noSamples

        var errorDescription: String? {
            switch self {
            case .notAZipArchive:
                return String(localized: "vimar.import.error.notXlsx",
                              defaultValue: "The file is not an xlsx export.")
            case .entryMissing(let name):
                return String(format: String(localized: "vimar.import.error.missing",
                                             defaultValue: "The export is missing the '%@' part."), name)
            case .unsupportedCompression:
                return String(localized: "vimar.import.error.compression",
                              defaultValue: "The export uses an unsupported compression.")
            case .corruptArchive:
                return String(localized: "vimar.import.error.corrupt",
                              defaultValue: "The export looks corrupted.")
            case .noSamples:
                return String(localized: "vimar.import.error.empty",
                              defaultValue: "No meter samples found in the export.")
            }
        }
    }

    /// Il giro completo: xlsx → punti giornalieri di frontiera, ordinati.
    static func dailyPoints(from data: Data, calendar: Calendar = .current) throws -> [EnergyStatsPoint] {
        let sheetXML = try inflatedEntry(named: "xl/worksheets/sheet1.xml", in: data)
        // Le sharedStrings possono mancare in un foglio tutto-inline: qui i
        // timestamp sono stringhe condivise, ma il parser regge entrambi.
        let sharedData = try? inflatedEntry(named: "xl/sharedStrings.xml", in: data)
        let shared = sharedData.map(sharedStrings(from:)) ?? []
        let points = points(sheetXML: sheetXML, sharedStrings: shared)
        guard !points.isEmpty else { throw ImportError.noSamples }
        return dailyBoundarySamples(points, calendar: calendar)
    }

    // MARK: - Interpretazione del foglio

    /// Dal foglio XML ai punti: cerca la riga di intestazione «Timestamp» e
    /// da lì in poi legge coppie (colonna A = data, colonna B = Wh).
    static func points(sheetXML: Data, sharedStrings: [String]) -> [EnergyStatsPoint] {
        let parser = SheetParser(sharedStrings: sharedStrings)
        parser.run(on: sheetXML)

        let isoFormatter = ISO8601DateFormatter()
        var result: [EnergyStatsPoint] = []
        var pastHeader = false
        for row in parser.rows {
            let first = row["A"]?.trimmingCharacters(in: .whitespaces) ?? ""
            if !pastHeader {
                if first.caseInsensitiveCompare("Timestamp") == .orderedSame { pastHeader = true }
                continue
            }
            guard let timestamp = isoFormatter.date(from: first),
                  let wattHours = row["B"].flatMap(Double.init) else { continue }
            result.append(EnergyStatsPoint(timestamp: timestamp,
                                           cumulativeKilowattHours: wattHours / 1_000))
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// Primo e ultimo campione di ogni giorno locale: le frontiere che
    /// servono ai totali giornalieri, senza le 96 righe intermedie.
    static func dailyBoundarySamples(_ points: [EnergyStatsPoint],
                                     calendar: Calendar = .current) -> [EnergyStatsPoint] {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        var byDay: [Date: (first: EnergyStatsPoint, last: EnergyStatsPoint)] = [:]
        for point in sorted {
            let day = calendar.startOfDay(for: point.timestamp)
            if var entry = byDay[day] {
                entry.last = point
                byDay[day] = entry
            } else {
                byDay[day] = (point, point)
            }
        }
        return byDay.values
            .flatMap { $0.first.timestamp == $0.last.timestamp ? [$0.first] : [$0.first, $0.last] }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - sharedStrings

    static func sharedStrings(from data: Data) -> [String] {
        let parser = SharedStringsParser()
        parser.run(on: data)
        return parser.strings
    }

    // MARK: - Lettore zip minimale (EOCD → central directory → deflate)

    private static func inflatedEntry(named name: String, in archive: Data) throws -> Data {
        guard archive.count > 22 else { throw ImportError.notAZipArchive }

        // End of Central Directory: firma 0x06054b50, cercata dal fondo
        // (il commento finale può spostarla fino a 64KB prima della fine).
        let tailStart = max(0, archive.count - 66_000)
        var eocdOffset: Int?
        var index = archive.count - 22
        while index >= tailStart {
            if readUInt32(archive, at: index) == 0x0605_4b50 { eocdOffset = index; break }
            index -= 1
        }
        guard let eocd = eocdOffset else { throw ImportError.notAZipArchive }

        let entryCount = Int(readUInt16(archive, at: eocd + 10))
        var cursor = Int(readUInt32(archive, at: eocd + 16))
        guard cursor != 0xFFFF_FFFF else { throw ImportError.corruptArchive }  // ZIP64: fuori scala per questi export

        for _ in 0..<entryCount {
            guard cursor + 46 <= archive.count,
                  readUInt32(archive, at: cursor) == 0x0201_4b50 else { throw ImportError.corruptArchive }
            let method = readUInt16(archive, at: cursor + 10)
            let compressedSize = Int(readUInt32(archive, at: cursor + 20))
            let uncompressedSize = Int(readUInt32(archive, at: cursor + 24))
            let nameLength = Int(readUInt16(archive, at: cursor + 28))
            let extraLength = Int(readUInt16(archive, at: cursor + 30))
            let commentLength = Int(readUInt16(archive, at: cursor + 32))
            let localOffset = Int(readUInt32(archive, at: cursor + 42))
            let entryName = String(data: archive.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)),
                                   encoding: .utf8) ?? ""
            cursor += 46 + nameLength + extraLength + commentLength

            guard entryName == name else { continue }

            // Local header: le lunghezze di nome/extra possono differire da
            // quelle del central directory — si rileggono da qui.
            guard localOffset + 30 <= archive.count,
                  readUInt32(archive, at: localOffset) == 0x0403_4b50 else { throw ImportError.corruptArchive }
            let localNameLength = Int(readUInt16(archive, at: localOffset + 26))
            let localExtraLength = Int(readUInt16(archive, at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= archive.count else { throw ImportError.corruptArchive }
            let compressed = archive.subdata(in: dataStart..<(dataStart + compressedSize))

            switch method {
            case 0:
                return compressed
            case 8:
                return try inflate(compressed, uncompressedSize: uncompressedSize)
            default:
                throw ImportError.unsupportedCompression
            }
        }
        throw ImportError.entryMissing(name)
    }

    /// Deflate grezzo: COMPRESSION_ZLIB di Apple è raw deflate, che è
    /// esattamente il formato delle entry zip.
    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { outBuffer -> Int in
            data.withUnsafeBytes { inBuffer -> Int in
                guard let outPointer = outBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let inPointer = inBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outPointer, uncompressedSize,
                                                 inPointer, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == uncompressedSize else { throw ImportError.corruptArchive }
        return output
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readUInt16(data, at: offset)) | (UInt32(readUInt16(data, at: offset + 2)) << 16)
    }
}

// MARK: - Parser SAX

/// sharedStrings.xml: la lista dei testi. Un `<si>` può contenere più run
/// `<t>` (rich text): si concatenano.
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current = ""
    private var insideText = false
    private var insideItem = false

    func run(on data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "si":
            insideItem = true
            current = ""
        case "t":
            insideText = insideItem
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch elementName {
        case "t":
            insideText = false
        case "si":
            strings.append(current)
            insideItem = false
        default:
            break
        }
    }
}

/// sheet1.xml: righe di celle. Ogni cella ha riferimento («A4»), tipo
/// opzionale (`t="s"` = indice nelle sharedStrings, `t="inlineStr"` = testo
/// inline) e valore in `<v>` (o `<is><t>` per l'inline).
private final class SheetParser: NSObject, XMLParserDelegate {
    private(set) var rows: [[String: String]] = []

    private let sharedStrings: [String]
    private var currentRow: [String: String] = [:]
    private var currentColumn = ""
    private var currentType = ""
    private var currentValue = ""
    private var collecting = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func run(on data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "row":
            currentRow = [:]
        case "c":
            // «A4» → colonna «A»: interessano le lettere, la riga è implicita.
            let reference = attributes["r"] ?? ""
            currentColumn = String(reference.prefix { $0.isLetter })
            currentType = attributes["t"] ?? ""
            currentValue = ""
        case "v", "t":
            collecting = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { currentValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch elementName {
        case "v", "t":
            collecting = false
        case "c":
            guard !currentColumn.isEmpty else { break }
            if currentType == "s", let index = Int(currentValue), sharedStrings.indices.contains(index) {
                currentRow[currentColumn] = sharedStrings[index]
            } else if !currentValue.isEmpty {
                currentRow[currentColumn] = currentValue
            }
        case "row":
            if !currentRow.isEmpty { rows.append(currentRow) }
        default:
            break
        }
    }
}
