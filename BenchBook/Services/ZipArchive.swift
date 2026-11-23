import Compression
import Foundation

/// A small ZIP writer and reader, so BenchBook's portable files open
/// anywhere (Windows' .NET reads them with `ZipFile`) without a dependency.
///
/// The writer stores files as they are, without compression: photos, PDFs
/// and HEIC files are compressed already. The reader also accepts Deflate,
/// for a file someone has zipped again with another tool. Both use ZIP64
/// when a file or the archive passes 4 GB, or there are over 65,535 entries.
nonisolated enum ZipArchive {
    enum ZipError: LocalizedError, Equatable {
        case notAZip
        case unsupported(String)
        case unsafeName(String)
        case damaged(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: String(localized: "The file isn't a ZIP archive.")
            case .unsupported(let name): String(localized: "“\(name)” is stored in a way BenchBook can't read.")
            case .unsafeName(let name): String(localized: "The archive has an entry BenchBook won't open: “\(name)”.")
            case .damaged(let name): String(localized: "The archive is damaged at “\(name)”.")
            }
        }
    }

    /// An entry in the archive's central directory.
    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    static let maxEntries = 200_000

    /// Whether `name` is safe to extract: relative, `/`-separated, with no
    /// empty, `.` or `..` parts, backslashes, drive letters or control characters.
    static func isSafeName(_ name: String) -> Bool {
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\"), !trimmed.contains(":"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return false }
        return trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Whether the file starts like a ZIP archive (`50 4B 03 04`, or an empty archive).
    static func looksLikeZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let start = (try? handle.read(upToCount: 4)) ?? Data()
        return start == Data([0x50, 0x4B, 0x03, 0x04]) || start == Data([0x50, 0x4B, 0x05, 0x06])
    }

    // MARK: Writing

    /// Writes stored entries to a new file, in the order they're added.
    final class Writer {
        private let handle: FileHandle
        private var offset: UInt64 = 0
        private var central = Data()
        private var count = 0
        private let dosTime: UInt16
        private let dosDate: UInt16

        init(creating url: URL, date: Date = .now) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            handle = try FileHandle(forWritingTo: url)
            (dosTime, dosDate) = ZipArchive.dosDateTime(date)
        }

        deinit { try? handle.close() }

        func add(_ name: String, data: Data) throws {
            try add(name, size: UInt64(data.count), crc: CRC32.checksum(data)) { write in try write(data) }
        }

        /// Copies a file in, reading it twice: once for its checksum, then to store it.
        func add(_ name: String, contentsOf url: URL) throws {
            var crc = CRC32()
            var size: UInt64 = 0
            try Self.chunks(of: url) { chunk in
                crc.update(chunk)
                size += UInt64(chunk.count)
            }
            try add(name, size: size, crc: crc.value) { write in
                try Self.chunks(of: url, write)
            }
        }

        private func add(_ name: String, size: UInt64, crc: UInt32, body: ((Data) throws -> Void) throws -> Void) throws {
            guard ZipArchive.isSafeName(name) else { throw ZipError.unsafeName(name) }
            let nameBytes = Data(name.utf8)
            let big = size >= 0xFFFF_FFFF
            let headerOffset = offset

            var local = Data()
            local.le32(0x0403_4B50)
            local.le16(big ? 45 : 20)
            local.le16(0x0800) // UTF-8 names
            local.le16(0) // stored
            local.le16(dosTime)
            local.le16(dosDate)
            local.le32(crc)
            local.le32(big ? 0xFFFF_FFFF : UInt32(size))
            local.le32(big ? 0xFFFF_FFFF : UInt32(size))
            local.le16(UInt16(nameBytes.count))
            var localExtra = Data()
            if big {
                localExtra.le16(0x0001)
                localExtra.le16(16)
                localExtra.le64(size)
                localExtra.le64(size)
            }
            local.le16(UInt16(localExtra.count))
            local.append(nameBytes)
            local.append(localExtra)
            try write(local)
            var written: UInt64 = 0
            try body { chunk in
                written += UInt64(chunk.count)
                try self.write(chunk)
            }
            guard written == size else { throw ZipError.damaged(name) }

            let farOffset = headerOffset >= 0xFFFF_FFFF
            var extra = Data()
            if big || farOffset {
                var fields = Data()
                if big {
                    fields.le64(size)
                    fields.le64(size)
                }
                if farOffset { fields.le64(headerOffset) }
                extra.le16(0x0001)
                extra.le16(UInt16(fields.count))
                extra.append(fields)
            }
            var entry = Data()
            entry.le32(0x0201_4B50)
            entry.le16(0x0300 | 45) // made by Unix, ZIP 4.5
            entry.le16(big || farOffset ? 45 : 20)
            entry.le16(0x0800)
            entry.le16(0)
            entry.le16(dosTime)
            entry.le16(dosDate)
            entry.le32(crc)
            entry.le32(big ? 0xFFFF_FFFF : UInt32(size))
            entry.le32(big ? 0xFFFF_FFFF : UInt32(size))
            entry.le16(UInt16(nameBytes.count))
            entry.le16(UInt16(extra.count))
            entry.le16(0) // comment
            entry.le16(0) // disk
            entry.le16(0) // internal attributes
            entry.le32(UInt32(0o100644) << 16) // a plain file, rw-r--r--
            entry.le32(farOffset ? 0xFFFF_FFFF : UInt32(headerOffset))
            entry.append(nameBytes)
            entry.append(extra)
            central.append(entry)
            count += 1
        }

        /// Writes the central directory. The file is complete only after this.
        func finish() throws {
            let centralOffset = offset
            try write(central)
            let centralSize = UInt64(central.count)
            let needs64 = count > 0xFFFE || centralOffset >= 0xFFFF_FFFF || centralSize >= 0xFFFF_FFFF
            if needs64 {
                let recordOffset = offset
                var record = Data()
                record.le32(0x0606_4B50)
                record.le64(44)
                record.le16(0x0300 | 45)
                record.le16(45)
                record.le32(0)
                record.le32(0)
                record.le64(UInt64(count))
                record.le64(UInt64(count))
                record.le64(centralSize)
                record.le64(centralOffset)
                record.le32(0x0706_4B50)
                record.le32(0)
                record.le64(recordOffset)
                record.le32(1)
                try write(record)
            }
            var end = Data()
            end.le32(0x0605_4B50)
            end.le16(0)
            end.le16(0)
            end.le16(needs64 ? 0xFFFF : UInt16(count))
            end.le16(needs64 ? 0xFFFF : UInt16(count))
            end.le32(needs64 ? 0xFFFF_FFFF : UInt32(centralSize))
            end.le32(needs64 ? 0xFFFF_FFFF : UInt32(centralOffset))
            end.le16(0)
            try write(end)
            try handle.synchronize()
            try handle.close()
        }

        private func write(_ data: Data) throws {
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }

        static func chunks(of url: URL, _ body: (Data) throws -> Void) throws {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try body(chunk)
            }
        }
    }

    // MARK: Reading

    /// Reads an archive's entries and extracts them, checking each one's size
    /// and checksum.
    final class Reader {
        let entries: [Entry]
        private let handle: FileHandle
        private let fileSize: UInt64

        init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            fileSize = try handle.seekToEnd()
            do {
                entries = try Self.readDirectory(handle, fileSize: fileSize)
            } catch {
                try? handle.close()
                throw error
            }
        }

        deinit { try? handle.close() }

        /// Extracts every entry under `folder`. Refuses unsafe names, links,
        /// encryption and methods other than stored and Deflate.
        func extractAll(to folder: URL) throws {
            let fileManager = FileManager.default
            for entry in entries {
                let destination = folder.appending(path: entry.name)
                if entry.isDirectory {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                    throw ZipError.damaged(entry.name)
                }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                try extract(entry) { try output.write(contentsOf: $0) }
            }
        }

        func extract(_ entry: Entry, to body: @escaping (Data) throws -> Void) throws {
            try handle.seek(toOffset: entry.localHeaderOffset)
            let header = try read(30, for: entry.name)
            guard header.le32(at: 0) == 0x0403_4B50 else { throw ZipError.damaged(entry.name) }
            let dataStart = entry.localHeaderOffset + 30 + UInt64(header.le16(at: 26)) + UInt64(header.le16(at: 28))
            guard dataStart + entry.compressedSize <= fileSize else { throw ZipError.damaged(entry.name) }
            try handle.seek(toOffset: dataStart)

            var crc = CRC32()
            var produced: UInt64 = 0
            let emit: (Data) throws -> Void = { chunk in
                produced += UInt64(chunk.count)
                // Never write more than the directory promised.
                guard produced <= entry.uncompressedSize else { throw ZipError.damaged(entry.name) }
                crc.update(chunk)
                try body(chunk)
            }
            var remaining = entry.compressedSize
            switch entry.method {
            case 0:
                while remaining > 0 {
                    let chunk = try read(Int(min(remaining, 1 << 20)), for: entry.name)
                    remaining -= UInt64(chunk.count)
                    try emit(chunk)
                }
            case 8:
                // Compression's zlib is raw Deflate, as ZIP stores it.
                let filter = try OutputFilter(.decompress, using: .zlib) { data in
                    if let data { try emit(data) }
                }
                while remaining > 0 {
                    let chunk = try read(Int(min(remaining, 1 << 20)), for: entry.name)
                    remaining -= UInt64(chunk.count)
                    try filter.write(chunk)
                }
                try filter.finalize()
            default:
                throw ZipError.unsupported(entry.name)
            }
            guard produced == entry.uncompressedSize, crc.value == entry.crc32 else { throw ZipError.damaged(entry.name) }
        }

        private func read(_ count: Int, for name: String) throws -> Data {
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ZipError.damaged(name) }
            return data
        }

        private static func readDirectory(_ handle: FileHandle, fileSize: UInt64) throws -> [Entry] {
            // The end record is in the last 22 bytes, plus up to 64 KB of comment.
            let tailSize = min(fileSize, 22 + 0xFFFF)
            try handle.seek(toOffset: fileSize - tailSize)
            guard let tail = try handle.read(upToCount: Int(tailSize)), tail.count >= 22,
                  let endIndex = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.le32(at: $0) == 0x0605_4B50 })
            else { throw ZipError.notAZip }
            var count = UInt64(tail.le16(at: endIndex + 10))
            var centralSize = UInt64(tail.le32(at: endIndex + 12))
            var centralOffset = UInt64(tail.le32(at: endIndex + 16))
            guard tail.le16(at: endIndex + 4) == 0, tail.le16(at: endIndex + 6) == 0 else {
                throw ZipError.unsupported("multi-part archive")
            }

            let endOffset = fileSize - tailSize + UInt64(endIndex)
            if count == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
                guard endOffset >= 20 else { throw ZipError.notAZip }
                try handle.seek(toOffset: endOffset - 20)
                guard let locator = try handle.read(upToCount: 20), locator.count == 20,
                      locator.le32(at: 0) == 0x0706_4B50
                else { throw ZipError.notAZip }
                let recordOffset = locator.le64(at: 8)
                guard recordOffset + 56 <= fileSize else { throw ZipError.notAZip }
                try handle.seek(toOffset: recordOffset)
                guard let record = try handle.read(upToCount: 56), record.count == 56,
                      record.le32(at: 0) == 0x0606_4B50
                else { throw ZipError.notAZip }
                count = record.le64(at: 32)
                centralSize = record.le64(at: 40)
                centralOffset = record.le64(at: 48)
            }
            guard count <= UInt64(maxEntries), centralOffset + centralSize <= fileSize,
                  centralSize <= 64 << 20
            else { throw ZipError.notAZip }

            try handle.seek(toOffset: centralOffset)
            let directory = try handle.read(upToCount: Int(centralSize)) ?? Data()
            guard directory.count == Int(centralSize) else { throw ZipError.notAZip }

            var entries: [Entry] = []
            var names = Set<String>()
            var position = 0
            for _ in 0..<count {
                guard position + 46 <= directory.count, directory.le32(at: position) == 0x0201_4B50 else {
                    throw ZipError.notAZip
                }
                let madeBy = directory.le16(at: position + 4)
                let flags = directory.le16(at: position + 8)
                let method = directory.le16(at: position + 10)
                let crc = directory.le32(at: position + 16)
                var compressed = UInt64(directory.le32(at: position + 20))
                var uncompressed = UInt64(directory.le32(at: position + 24))
                let nameLength = Int(directory.le16(at: position + 28))
                let extraLength = Int(directory.le16(at: position + 30))
                let commentLength = Int(directory.le16(at: position + 32))
                let attributes = directory.le32(at: position + 38)
                var offset = UInt64(directory.le32(at: position + 42))
                let nameStart = position + 46
                guard nameStart + nameLength + extraLength + commentLength <= directory.count else {
                    throw ZipError.notAZip
                }
                let nameData = directory.subdata(in: nameStart..<nameStart + nameLength)
                let name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1) ?? ""

                // ZIP64 sizes and offset, in that order, for the fields set to all ones.
                var extra = nameStart + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let id = directory.le16(at: extra)
                    let size = Int(directory.le16(at: extra + 2))
                    var field = extra + 4
                    if id == 0x0001 {
                        if uncompressed == 0xFFFF_FFFF, field + 8 <= extraEnd { uncompressed = directory.le64(at: field); field += 8 }
                        if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd { compressed = directory.le64(at: field); field += 8 }
                        if offset == 0xFFFF_FFFF, field + 8 <= extraEnd { offset = directory.le64(at: field) }
                    }
                    extra += 4 + size
                }
                position = extraEnd + commentLength

                guard isSafeName(name), names.insert(name).inserted else { throw ZipError.unsafeName(name) }
                // Unix links: mode S_IFLNK in the high half of the attributes.
                if madeBy >> 8 == 3, (attributes >> 16) & 0o170000 == 0o120000 { throw ZipError.unsafeName(name) }
                guard flags & 0x0001 == 0 else { throw ZipError.unsupported(name) } // encrypted
                guard method == 0 || method == 8 else { throw ZipError.unsupported(name) }
                guard offset < fileSize, method == 8 || compressed == uncompressed else { throw ZipError.damaged(name) }
                entries.append(Entry(name: name, method: method, crc32: crc, compressedSize: compressed,
                                     uncompressedSize: uncompressed, localHeaderOffset: offset))
            }
            return entries
        }
    }

    /// MS-DOS local date and time, as ZIP stores them. Years before 1980 are 1980.
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((parts.year ?? 1980) - 1980, 0)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(min(year, 127) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

/// CRC-32 as ZIP uses it (IEEE 802.3, reflected, polynomial 0xEDB88320).
nonisolated struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    private var crc: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { crc ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        var crc = self.crc
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        self.crc = crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}

private extension Data {
    nonisolated mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    nonisolated mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    nonisolated mutating func le64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }

    nonisolated func le16(at index: Int) -> UInt16 {
        let start = startIndex + index
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    nonisolated func le32(at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + index + $1]) << (8 * $1) }
    }

    nonisolated func le64(at index: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + index + $1]) << (8 * $1) }
    }
}
