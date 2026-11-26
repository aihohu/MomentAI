import CryptoKit
import Foundation

struct SessionImportError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}

// Deliberately implements only the ZIP32 STORE dialect produced by our exporter.
// Never feeds untrusted names to a general-purpose unzip utility.
final class StoredZIPReader {
  static let maximumArchiveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
  static let maximumMetadataBytes = 20 * 1_024 * 1_024
  struct Entry {
    let path: String
    let offset: UInt64
    let size: Int
    let crc: UInt32
  }
  let entries: [Entry]
  private let input: FileHandle
  private let size: UInt64

  init(url: URL) throws {
    input = try FileHandle(forReadingFrom: url)
    size = try input.importSeekToEnd()
    guard size >= 22, size <= UInt64(Self.maximumArchiveBytes) else {
      try? input.close()
      throw SessionImportError(
        NativeStrings.text(
          "native_invalid_archive_size_this_version_supports_momentai_files_up_to_105"))
    }
    // Fixed EOCD, no comments, no multi-disk, no ZIP64, no appended bytes.
    try input.seek(toOffset: size - 22)
    let end = try Self.read(input, count: 22)
    guard end.zipUInt32(0) == 0x0605_4b50,
      end.zipUInt16(4) == 0, end.zipUInt16(6) == 0,
      end.zipUInt16(8) == end.zipUInt16(10), end.zipUInt16(20) == 0
    else {
      throw SessionImportError(
        NativeStrings.text("native_split_archives_zip64_and_appended_data_are_not_supported_106"))
    }
    let count = Int(end.zipUInt16(10))
    let centralSize = UInt64(end.zipUInt32(12))
    let centralOffset = UInt64(end.zipUInt32(16))
    guard count >= 5, count <= 10_000, centralSize <= 4 * 1_024 * 1_024,
      centralOffset + centralSize == size - 22
    else {
      throw SessionImportError(
        NativeStrings.text("native_invalid_archive_directory_size_or_file_count_107"))
    }
    try input.seek(toOffset: centralOffset)
    let central = try Self.read(input, count: Int(centralSize))
    var cursor = 0
    var names = Set<String>()
    var found: [Entry] = []
    var expectedOffset: UInt64 = 0
    for _ in 0..<count {
      guard cursor + 46 <= central.count, central.zipUInt32(cursor) == 0x0201_4b50 else {
        throw SessionImportError(
          NativeStrings.text("native_the_archive_central_directory_is_damaged_108"))
      }
      let h = central.subdata(in: cursor..<(cursor + 46))
      let length = Int(h.zipUInt16(28))
      let fileSize = h.zipUInt32(24)
      let offset = UInt64(h.zipUInt32(42))
      guard h.zipUInt16(6) <= 20, h.zipUInt16(8) == 0x0800, h.zipUInt16(10) == 0,
        h.zipUInt32(20) == fileSize, h.zipUInt16(30) == 0, h.zipUInt16(32) == 0,
        h.zipUInt16(34) == 0, h.zipUInt16(36) == 0, h.zipUInt32(38) == 0,
        length > 0, length <= 240, cursor + 46 + length <= central.count,
        offset == expectedOffset
      else {
        throw SessionImportError(
          NativeStrings.text(
            "native_only_uncompressed_unencrypted_link_free_contiguous_momentai_arch_109"))
      }
      let nameData = central.subdata(in: (cursor + 46)..<(cursor + 46 + length))
      guard let name = String(data: nameData, encoding: .utf8), Self.isAllowedPath(name),
        names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted
      else {
        throw SessionImportError(
          NativeStrings.text(
            "native_the_archive_contains_unsafe_paths_duplicate_names_or_unsupported_110"))
      }
      let limit =
        name == "audio/session.wav" ? Int(Self.maximumArchiveBytes) : Self.maximumMetadataBytes
      guard fileSize <= limit, offset + 30 + UInt64(length) + UInt64(fileSize) <= centralOffset
      else {
        throw SessionImportError(
          NativeStrings.text("native_archive_entries_exceed_limits_or_overlap_5"))
      }
      try input.seek(toOffset: offset)
      let local = try Self.read(input, count: 30)
      let localName = try Self.read(input, count: length)
      guard local.zipUInt32(0) == 0x0403_4b50, local.zipUInt16(4) == h.zipUInt16(6),
        local.zipUInt16(6) == h.zipUInt16(8), local.zipUInt16(8) == 0,
        local.zipUInt32(14) == h.zipUInt32(16),
        local.zipUInt32(18) == fileSize, local.zipUInt32(22) == fileSize,
        local.zipUInt16(26) == length, local.zipUInt16(28) == 0, localName == nameData
      else {
        throw SessionImportError(
          NativeStrings.text("native_the_local_and_central_archive_headers_do_not_match_111"))
      }
      let dataOffset = offset + 30 + UInt64(length)
      found.append(Entry(path: name, offset: dataOffset, size: Int(fileSize), crc: h.zipUInt32(16)))
      expectedOffset = dataOffset + UInt64(fileSize)
      cursor += 46 + length
    }
    guard cursor == central.count, expectedOffset == centralOffset else {
      throw SessionImportError(
        NativeStrings.text("native_the_archive_contains_undeclared_content_112"))
    }
    entries = found
  }

  deinit { try? input.close() }

  static func isAllowedPath(_ name: String) -> Bool {
    if ["manifest.json", "session.json", "session.md", "timeline.jsonl", "audio/session.wav"]
      .contains(name)
    {
      return true
    }
    guard name.hasPrefix("images/"), name.hasSuffix(".jpg") else { return false }
    let component = String(name.dropFirst(7).dropLast(4))
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return !component.isEmpty && component.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  func data(_ entry: Entry) throws -> Data {
    guard entry.size <= Self.maximumMetadataBytes else {
      throw SessionImportError(NativeStrings.text("native_metadata_is_too_large_113"))
    }
    try input.seek(toOffset: entry.offset)
    let data = try Self.read(input, count: entry.size)
    guard Self.crc32(data) == entry.crc else {
      throw SessionImportError(
        NativeStrings.text(
          "native_file_crc_verification_failed_114", String(describing: entry.path)))
    }
    return data
  }

  func extract(to destination: URL) throws -> [String: (bytes: Int, sha256: String)] {
    var results: [String: (Int, String)] = [:]
    for entry in entries {
      let url = destination.appendingPathComponent(entry.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw SessionImportError(
          NativeStrings.text("native_could_not_create_the_import_staging_file_115"))
      }
      let output = try FileHandle(forWritingTo: url)
      defer { try? output.close() }
      try input.seek(toOffset: entry.offset)
      var remaining = entry.size
      var hasher = SHA256()
      var crc = UInt32.max
      while remaining > 0 {
        let data = try Self.read(input, count: min(256 * 1_024, remaining))
        hasher.update(data: data)
        crc = Self.updateCRC(crc, data)
        try output.importWrite(data)
        remaining -= data.count
      }
      try output.synchronize()
      guard crc ^ UInt32.max == entry.crc else {
        throw SessionImportError(
          NativeStrings.text(
            "native_file_crc_verification_failed_114", String(describing: entry.path)))
      }
      results[entry.path] = (
        entry.size, hasher.finalize().map { String(format: "%02x", $0) }.joined()
      )
    }
    return results
  }

  private static func read(_ handle: FileHandle, count: Int) throws -> Data {
    let value = try handle.importRead(count) ?? Data()
    guard value.count == count else {
      throw SessionImportError(NativeStrings.text("native_the_archive_ended_unexpectedly_116"))
    }
    return value
  }
  static func crc32(_ data: Data) -> UInt32 { updateCRC(UInt32.max, data) ^ UInt32.max }
  private static func updateCRC(_ initial: UInt32, _ data: Data) -> UInt32 {
    var crc = initial
    for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    return crc
  }
  private static let crcTable: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1 }
    return crc
  }
}

extension Data {
  // Callers check record lengths before accessing offsets; no unaligned loads.
  func zipUInt16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
  func zipUInt32(_ offset: Int) -> UInt32 {
    UInt32(zipUInt16(offset)) | UInt32(zipUInt16(offset + 2)) << 16
  }
}

extension FileHandle {
  func importRead(_ count: Int) throws -> Data? {
    try read(upToCount: count)
  }
  func importWrite(_ data: Data) throws {
    try write(contentsOf: data)
  }
  func importSeekToEnd() throws -> UInt64 {
    try seekToEnd()
  }
}
