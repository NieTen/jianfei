import hashlib
import json
import os
import struct
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"BJAR2"
CHUNK_SIZE = 64 * 1024


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as reader:
        while chunk := reader.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def derive_key(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 600_000, dklen=32)


def encrypt_file(source, destination, password):
    salt, prefix = os.urandom(16), os.urandom(8)
    header = MAGIC + salt + prefix
    cipher = AESGCM(derive_key(password, salt))
    with Path(source).open("rb") as reader, Path(destination).open("wb") as writer:
        writer.write(header)
        counter = 0
        while True:
            data = reader.read(CHUNK_SIZE)
            encoded_counter = struct.pack(">I", counter)
            sealed = cipher.encrypt(prefix + encoded_counter, data, header + encoded_counter)
            writer.write(struct.pack(">I", len(sealed)))
            writer.write(sealed)
            counter += 1
            if not data:
                break
        writer.flush()
        os.fsync(writer.fileno())


def exact_read(reader, length):
    data = reader.read(length)
    if len(data) != length:
        raise ValueError("归档文件不完整")
    return data


def decrypt_file(source, destination, password):
    with Path(source).open("rb") as reader, Path(destination).open("wb") as writer:
        header = exact_read(reader, 29)
        if header[:5] != MAGIC:
            raise ValueError("不支持的归档版本")
        cipher = AESGCM(derive_key(password, header[5:21]))
        counter, written = 0, 0
        while True:
            size = struct.unpack(">I", exact_read(reader, 4))[0]
            if not 16 <= size <= CHUNK_SIZE + 16:
                raise ValueError("归档分片大小无效")
            encoded_counter = struct.pack(">I", counter)
            plaintext = cipher.decrypt(header[21:29] + encoded_counter, exact_read(reader, size), header + encoded_counter)
            counter += 1
            if not plaintext:
                if reader.read(1):
                    raise ValueError("归档尾部包含无效内容")
                return
            written += len(plaintext)
            if written > 4 * 1024 * 1024 * 1024:
                raise ValueError("归档超过 4GB 限制")
            writer.write(plaintext)


def write_frame(writer, metadata, data):
    header = json.dumps(metadata, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    writer.write(struct.pack(">I", len(header)))
    writer.write(header)
    if isinstance(data, Path):
        with data.open("rb") as reader:
            while chunk := reader.read(CHUNK_SIZE):
                writer.write(chunk)
    else:
        writer.write(data)


def read_frames(path):
    with Path(path).open("rb") as reader:
        while True:
            size_data = reader.read(4)
            if not size_data:
                raise ValueError("归档缺少结束标记")
            if len(size_data) != 4:
                raise ValueError("归档帧不完整")
            size = struct.unpack(">I", size_data)[0]
            if size > 64 * 1024:
                raise ValueError("归档头超限")
            metadata = json.loads(exact_read(reader, size))
            length = metadata.get("length", 0)
            if not isinstance(length, int) or length < 0 or length > 15 * 1024 * 1024:
                raise ValueError("归档条目大小无效")
            if metadata["type"] == "end":
                if length or reader.read(1):
                    raise ValueError("归档结束标记无效")
                return
            yield metadata, exact_read(reader, length)

