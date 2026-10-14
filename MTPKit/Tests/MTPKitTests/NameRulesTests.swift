import Testing
@testable import MTPKit

@Suite struct NameRulesTests {
    // MARK: MTP code line (D-26)

    @Test(arguments: [
        (MTPError.response(code: 0x200F, op: 0x9804), "MTP error 0x200F (Access Denied)"),
        (MTPError.response(code: 0x200C, op: 0x100C), "MTP error 0x200C (Store Full)"),
        (MTPError.response(code: 0x2FFF, op: 0x9804), "MTP error 0x2FFF"),
        (MTPError.deviceGone, nil),
        (MTPError.io(operation: "Bulk write", code: 0xE000_02ED), nil),
    ] as [(MTPError, String?)])
    func codeLine(error: MTPError, line: String?) {
        #expect(error.codeLine == line)
    }

    // MARK: Phone refusal → Finder-style alert (D-25, D-27)

    @Test(arguments: [
        (UInt16(0x200F), "The phone doesn’t allow changing “X”.", "MTP error 0x200F (Access Denied)"),
        (0x200D, "The phone doesn’t allow changing “X”.", "MTP error 0x200D (Object Write-Protected)"),
        (0x200E, "The phone doesn’t allow changing “X”.", "MTP error 0x200E (Store Read-Only)"),
        (0x2002, "The operation can’t be completed because an unexpected error occurred.",
         "MTP error 0x2002 (General Error)"),
    ] as [(UInt16, String, String)])
    func refusalText(code: UInt16, message: String, detail: String) {
        #expect(OperationAlert.text(for: .response(code: code, op: 0x9804), name: "X")
                == AlertText(message: message, detail: detail))
    }

    // MARK: Name validation (D-21, RESEARCH Pitfalls 3-4)

    @Test(arguments: [
        ("", NameVerdict.empty),
        ("a/b", .invalidCharacter),
        ("a:b", .invalidCharacter),
        (".", .reserved),
        ("..", .reserved),
        ("...", .ok),
        (String(repeating: "a", count: 254), .ok),
        (String(repeating: "a", count: 255), .tooLong),
        (String(repeating: "😀", count: 127), .ok),       // 254 UTF-16 units
        (String(repeating: "😀", count: 128), .tooLong),  // 256 UTF-16 units
    ] as [(String, NameVerdict)])
    func validateShape(name: String, verdict: NameVerdict) {
        #expect(NameRules.validate(name, current: nil, siblings: []) == verdict)
    }

    @Test(arguments: [
        ("IMG_2.JPG", nil, ["IMG_2.jpg"], NameVerdict.taken),
        ("e\u{301}.txt", nil, ["\u{e9}.txt"], .taken),          // NFC
        ("Photo.jpg", "photo.jpg", ["photo.jpg"], .ok),         // the item itself does not count
        ("a.txt", "a.txt", ["a.txt"], .unchanged),
        ("b.txt", "a.txt", ["a.txt", "B.TXT"], .taken),
        ("c.txt", nil, ["a.txt", "b.txt"], .ok),
    ] as [(String, String?, [String], NameVerdict)])
    func validateSiblings(name: String, current: String?, siblings: [String], verdict: NameVerdict) {
        #expect(NameRules.validate(name, current: current, siblings: siblings) == verdict)
    }

    @Test(arguments: [
        (NameVerdict.taken, AlertText(message: "The name “X” is already taken. Please choose a different name.", detail: nil)),
        (.invalidCharacter, AlertText(message: "The name “X” can’t be used.",
                                      detail: "Try using a name with fewer characters, or with no punctuation marks.")),
        (.reserved, AlertText(message: "The name “X” can’t be used.",
                              detail: "Try using a name with fewer characters, or with no punctuation marks.")),
        (.tooLong, AlertText(message: "The name “X” is too long.", detail: "Try using a name with fewer characters.")),
        (.empty, AlertText(message: "Please enter a name.", detail: nil)),
    ] as [(NameVerdict, AlertText)])
    func rejectionWording(verdict: NameVerdict, text: AlertText) {
        #expect(NameRules.alert(for: verdict, name: "X") == text)
    }

    @Test(arguments: [NameVerdict.ok, .unchanged])
    func acceptedNamesHaveNoAlert(verdict: NameVerdict) {
        #expect(NameRules.alert(for: verdict, name: "X") == nil)
    }

    @Test func nonResponseErrorIsGenericWithItsDetail() {
        let error = MTPError.deviceGone
        #expect(OperationAlert.text(for: error, name: "X")
                == AlertText(message: "The operation can’t be completed because an unexpected error occurred.",
                             detail: error.detail))
    }

    // MARK: New folder name (D-19)

    @Test(arguments: [
        ([], "untitled folder"),
        (["untitled folder"], "untitled folder 2"),
        (["Untitled Folder"], "untitled folder 2"),
        (["untitled folder", "untitled folder 2"], "untitled folder 3"),
        (["untitled folder", "untitled folder 3"], "untitled folder 2"),
    ] as [([String], String)])
    func uniqueName(siblings: [String], name: String) {
        #expect(NameRules.uniqueName(among: siblings) == name)
    }

    // MARK: Keep Both name (D-07)

    @Test(arguments: [
        ("IMG.jpg", false, ["IMG.jpg"], "IMG 2.jpg"),
        (".nomedia", false, [".nomedia"], ".nomedia 2"),                 // a dotfile has no extension
        ("archive.tar.gz", false, ["archive.tar.gz"], "archive.tar 2.gz"),
        ("Photos", true, ["Photos"], "Photos 2"),
        ("v1.2", true, ["v1.2"], "v1.2 2"),                              // a folder never splits
        ("IMG.", false, ["IMG."], "IMG. 2"),
        ("IMG.jpg", false, ["IMG.jpg", "img 2.JPG"], "IMG 3.jpg"),       // case-insensitive
        ("Caf\u{E9}.txt", false, ["Caf\u{E9}.txt", "Cafe\u{301} 2.txt"], "Caf\u{E9} 3.txt"),   // NFC
    ] as [(String, Bool, [String], String)])
    func keepBothName(name: String, isFolder: Bool, taken: [String], result: String) {
        #expect(NameRules.keepBothName(name, isFolder: isFolder, among: taken) == result)
    }
}
