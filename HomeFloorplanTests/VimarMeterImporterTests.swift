import Foundation
import Testing
@testable import HomeFloorplan

/// Gli stadi parsabili dell'import Vimar, inchiodati sulla forma REALE
/// dell'export (verificata sul file della casa: sharedStrings per i
/// timestamp, valori Wh inline, header «Timestamp/Value» alla terza riga).
/// Lo strato zip si collauda sul device col file vero: costruire archivi
/// nei test vorrebbe dire testare un compressore, non il nostro lettore.
@Suite("Import contatore Vimar — dal foglio ai punti giornalieri")
struct VimarMeterImporterTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    /// La forma vera del foglio: titolo, riga vuota, header, poi i dati.
    /// I timestamp passano dalle sharedStrings (t="s"), i Wh sono inline.
    private var sheetXML: Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c></row>
        <row r="2"/>
        <row r="3"><c r="A3" t="s"><v>1</v></c><c r="B3" t="s"><v>2</v></c></row>
        <row r="4"><c r="A4" t="s"><v>3</v></c><c r="B4"><v>432039</v></c></row>
        <row r="5"><c r="A5" t="s"><v>4</v></c><c r="B5"><v>432157</v></c></row>
        <row r="6"><c r="A6" t="s"><v>5</v></c><c r="B6"><v>432500</v></c></row>
        <row r="7"><c r="A7" t="s"><v>6</v></c><c r="B7"><v>433100</v></c></row>
        </sheetData>
        </worksheet>
        """.utf8)
    }

    private var sharedStringsXML: Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <si><t>Meter-Energia consumata-TaTi Home-Wh</t></si>
        <si><t>Timestamp</t></si>
        <si><t>Value</t></si>
        <si><t>2025-08-30T22:15:56+02:00</t></si>
        <si><t>2025-08-30T23:45:56+02:00</t></si>
        <si><t>2025-08-31T00:15:56+02:00</t></si>
        <si><t>2025-08-31T21:00:56+02:00</t></si>
        </sst>
        """.utf8)
    }

    @Test("sharedStrings: i run di testo escono nell'ordine giusto")
    func sharedStringsParse() {
        let strings = VimarMeterImporter.sharedStrings(from: sharedStringsXML)
        #expect(strings.count == 7)
        #expect(strings[1] == "Timestamp")
        #expect(strings[3] == "2025-08-30T22:15:56+02:00")
    }

    @Test("Foglio: titolo e header saltati, Wh → kWh, ordinati")
    func sheetParse() {
        let shared = VimarMeterImporter.sharedStrings(from: sharedStringsXML)
        let points = VimarMeterImporter.points(sheetXML: sheetXML, sharedStrings: shared)
        #expect(points.count == 4)
        #expect(abs(points[0].cumulativeKilowattHours! - 432.039) < 0.0001)
        #expect(abs(points[3].cumulativeKilowattHours! - 433.100) < 0.0001)
        #expect(points[0].timestamp < points[1].timestamp)
    }

    @Test("Sottocampionamento: primo e ultimo di ogni giorno, niente doppioni")
    func dailyBoundaries() {
        let shared = VimarMeterImporter.sharedStrings(from: sharedStringsXML)
        let points = VimarMeterImporter.points(sheetXML: sheetXML, sharedStrings: shared)
        let daily = VimarMeterImporter.dailyBoundarySamples(points, calendar: calendar)
        // Giorno 30/08: due campioni (22:15 e 23:45). Giorno 31/08: due
        // (00:15 e 21:00). Totale 4 — e con un solo campione in un giorno
        // non deve mai uscire duplicato.
        #expect(daily.count == 4)

        let single = [points[0]]
        #expect(VimarMeterImporter.dailyBoundarySamples(single, calendar: calendar).count == 1)
    }

    /// Un xlsx VERO in miniatura (stessa struttura dell'export, generato con
    /// openpyxl e incorporato in base64): collauda anche lo strato zip —
    /// EOCD, central directory, local header, deflate.
    @Test("Archivio xlsx completo: il giro intero fino ai punti giornalieri")
    func fullArchive() throws {
        let base64 = "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"
        let archive = try #require(Data(base64Encoded: base64))
        let daily = try VimarMeterImporter.dailyPoints(from: archive, calendar: calendar)
        #expect(daily.count == 4)
        #expect(abs(daily.first!.cumulativeKilowattHours! - 432.039) < 0.0001)
        #expect(abs(daily.last!.cumulativeKilowattHours! - 433.100) < 0.0001)
    }

    @Test("Un foglio senza dati sotto l'header produce zero punti")
    func emptyBody() {
        let headerOnly = Data("""
        <worksheet><sheetData>
        <row r="3"><c r="A3" t="inlineStr"><is><t>Timestamp</t></is></c></row>
        </sheetData></worksheet>
        """.utf8)
        let points = VimarMeterImporter.points(sheetXML: headerOnly, sharedStrings: [])
        #expect(points.isEmpty)
    }
}
