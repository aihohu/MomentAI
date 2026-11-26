package org.hohu.momentai

import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** Strict ZIP32 STORE profile used by iOS. No ZIP bombs, links, aliases or trailing bytes. */
internal class StoredSessionZip(file: File) : Closeable {
    data class Entry(val path: String, val offset: Long, val size: Long, val crc: Long)
    private val input = RandomAccessFile(file, "r")
    val entries: List<Entry>
    init {
        try {
            val size = input.length()
            require(size in 22..MAXIMUM_BYTES) {
                NativeStrings.text(R.string.native_invalid_archive_size_the_maximum_is_2_gib_0)
            }
            input.seek(size - 22)
            val end = read(22)
            require(
                end.u32(0) == 0x06054b50L && end.u16(4) == 0 && end.u16(6) == 0 &&
                    end.u16(8) == end.u16(10) && end.u16(20) == 0
            ) {
                NativeStrings.text(
                    R.string.native_split_archives_zip64_and_appended_data_are_not_supported_1
                )
            }
            val count = end.u16(10)
            val centralSize = end.u32(12)
            val centralOffset = end.u32(16)
            require(
                count in 5..10000 && centralSize <= 4 * 1024 * 1024 &&
                    centralOffset + centralSize == size - 22
            )
            input.seek(centralOffset)
            val central = read(centralSize.toInt())
            var cursor = 0
            var expectedOffset = 0L
            val names = mutableSetOf<String>()
            val found = mutableListOf<Entry>()
            repeat(count) {
                require(cursor + 46 <= central.size && central.u32(cursor) == 0x02014b50L) {
                    NativeStrings.text(R.string.native_the_archive_directory_is_damaged_2)
                }
                val h = central.copyOfRange(cursor, cursor + 46)
                val length = h.u16(28)
                val bytes = h.u32(24)
                val offset = h.u32(42)
                require(
                    h.u16(6) <= 20 && h.u16(8) == 0x800 && h.u16(10) == 0 &&
                        h.u32(20) == bytes && h.u16(30) == 0 && h.u16(32) == 0 && h.u16(34) == 0 &&
                        h.u16(36) == 0 && h.u32(38) == 0L && length in 1..240 &&
                        cursor + 46 + length <= central.size && offset == expectedOffset
                ) {
                    NativeStrings.text(
                        R.string.native_compressed_encrypted_linked_or_non_contiguous_archives_are_not_su_3
                    )
                }
                val nameData = central.copyOfRange(cursor + 46, cursor + 46 + length)
                val name = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(
                        CodingErrorAction.REPORT
                    ).decode(ByteBuffer.wrap(nameData)).toString()
                require(
                    allowedPath(name) &&
                        names.add(
                            Normalizer.normalize(name, Normalizer.Form.NFC).lowercase(Locale.ROOT)
                        )
                ) {
                    NativeStrings.text(
                        R.string.native_the_archive_contains_unsafe_paths_or_duplicate_filenames_4
                    )
                }
                val limit = if (name ==
                    "audio/session.wav"
                ) {
                    MAXIMUM_BYTES
                } else {
                    PortableText.METADATA_LIMIT
                }
                require(bytes <= limit && offset + 30 + length + bytes <= centralOffset) {
                    NativeStrings.text(R.string.native_archive_entries_exceed_limits_or_overlap_5)
                }
                input.seek(offset)
                val local = read(30)
                val localName = read(length)
                require(
                    local.u32(0) == 0x04034b50L && local.u16(4) == h.u16(6) &&
                        local.u16(
                            6
                        ) == h.u16(8) && local.u16(8) == 0 && local.u32(14) == h.u32(16) &&
                        local.u32(
                            18
                        ) == bytes && local.u32(22) == bytes && local.u16(26) == length &&
                        local.u16(28) == 0 && localName.contentEquals(nameData)
                ) {
                    NativeStrings.text(R.string.native_the_archive_headers_do_not_match_6)
                }
                val dataOffset = offset + 30 + length
                found.add(Entry(name, dataOffset, bytes, h.u32(16)))
                expectedOffset = dataOffset + bytes
                cursor += 46 + length
            }
            require(cursor == central.size && expectedOffset == centralOffset) {
                NativeStrings.text(R.string.native_the_archive_contains_undeclared_content_7)
            }
            entries = found
        } catch (failure: Exception) {
            input.close()
            throw failure
        }
    }
    fun extract(destination: File): Map<String, JsonMap> {
        val result = linkedMapOf<String, JsonMap>()
        val buffer = ByteArray(256 * 1024)
        for (entry in entries) {
            val file = File(destination, entry.path)
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            check(!file.exists())
            input.seek(entry.offset)
            val crc = CRC32()
            val digest = MessageDigest.getInstance("SHA-256")
            var remaining = entry.size
            FileOutputStream(file).use { output ->
                while (remaining > 0) {
                    val count = minOf(remaining, buffer.size.toLong()).toInt()
                    input.readFully(buffer, 0, count)
                    output.write(buffer, 0, count)
                    crc.update(buffer, 0, count)
                    digest.update(buffer, 0, count)
                    remaining -= count
                }
                output.fd.sync()
            }
            require(crc.value == entry.crc) {
                NativeStrings.text(R.string.native_archive_crc_verification_failed_8)
            }
            result[entry.path] = mapOf(
                "path" to entry.path,
                "byteCount" to entry.size,
                "sha256" to digest.digest().joinToString("") { "%02x".format(it) }
            )
        }
        return result
    }
    private fun read(count: Int) = ByteArray(count).also { input.readFully(it) }
    override fun close() = input.close()
    companion object {
        const val MAXIMUM_BYTES = 2L * 1024 * 1024 * 1024
        val requiredPaths =
            setOf(
                "manifest.json",
                "session.json",
                "session.md",
                "timeline.jsonl",
                "audio/session.wav"
            )
        fun allowedPath(path: String): Boolean = path in requiredPaths ||
            Regex("images/[\\p{L}\\p{N}_-]+\\.jpg").matches(path)
        fun sha(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n <
                        0
                    ) {
                        break
                    }
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
        fun artifact(root: File, path: String): JsonMap {
            val file = File(root, path)
            return mapOf("path" to path, "byteCount" to file.length(), "sha256" to sha(file))
        }
        fun write(root: File, paths: List<String>, destination: File) {
            require(paths.size in 5..10000 && paths.all(::allowedPath))
            val total = paths.sumOf { File(root, it).length() }
            require(total + paths.size * 600L + 22 <= MAXIMUM_BYTES) {
                NativeStrings.text(R.string.native_the_archive_exceeds_2_gib_9)
            }
            FileOutputStream(destination).use { output ->
                val zip = ZipOutputStream(output, Charsets.UTF_8)
                for (path in paths.sorted()) {
                    val file = File(root, path)
                    val crc = CRC32()
                    file.inputStream().use { input ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count <
                                0
                            ) {
                                break
                            }
                            crc.update(buffer, 0, count)
                        }
                    }
                    val entry = ZipEntry(path).apply {
                        method = ZipEntry.STORED
                        size = file.length()
                        compressedSize = size
                        this.crc = crc.value
                        time = 1704067200000L
                    }
                    zip.putNextEntry(entry)
                    file.inputStream().use { it.copyTo(zip, 256 * 1024) }
                    zip.closeEntry()
                }
                zip.finish()
                zip.flush()
                output.fd.sync()
            }
        }
    }
}

internal fun ByteArray.u16(offset: Int): Int = (this[offset].toInt() and 255) or ((this[offset + 1].toInt() and 255) shl 8)
internal fun ByteArray.u32(offset: Int): Long = u16(offset).toLong() or (u16(offset + 2).toLong() shl 16)
internal fun wavHeader(samples: Long): ByteArray {
    require(samples > 0 && samples * 2 <= 0xffffffffL - 36)
    return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("RIFF".toByteArray())
        putInt((samples * 2 + 36).toInt())
        put("WAVEfmt ".toByteArray())
        putInt(16)
        putShort(1)
        putShort(1)
        putInt(16000)
        putInt(32000)
        putShort(2)
        putShort(16)
        put("data".toByteArray())
        putInt((samples * 2).toInt())
    }.array()
}
