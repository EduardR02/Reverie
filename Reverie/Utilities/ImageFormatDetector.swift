import Foundation

extension Data {
    func isJpeg() -> Bool {
        let bytes = [UInt8](self.prefix(3))
        return bytes.count == 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
    }

    func isPng() -> Bool {
        let bytes = [UInt8](self.prefix(8))
        return bytes.count == 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
    }

    func isGif() -> Bool {
        let bytes = [UInt8](self.prefix(4))
        return bytes.count == 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38
    }

    func isWebp() -> Bool {
        let bytes = [UInt8](self.prefix(12))
        return bytes.count == 12
            && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50
    }

    func isBmp() -> Bool {
        let bytes = [UInt8](self.prefix(2))
        return bytes.count == 2 && bytes[0] == 0x42 && bytes[1] == 0x4D
    }

    func isSvg() -> Bool {
        let text = String(data: self, encoding: .utf8) ?? String(data: self, encoding: .isoLatin1)
        return text?.range(of: "<svg", options: .caseInsensitive) != nil
    }
}
