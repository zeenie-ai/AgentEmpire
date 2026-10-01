// Minimal zip reading and writing for the release scripts, with no dependencies.
//
// Writing keeps Unix permissions (the "made by Unix" external attributes that unzip, macOS
// Archive Utility and most Linux tools honour), so a game or a Node.js packed on Windows still
// runs after it is unzipped on macOS or Linux. Reading works on a file descriptor, so a large
// archive such as Godot's export templates (over a gigabyte) is never loaded whole, and it
// understands Zip64 archives.
import { closeSync, fstatSync, openSync, readSync, writeSync } from 'node:fs';
import { crc32, deflateRawSync, inflateRawSync } from 'node:zlib';

const S_IFDIR = 0o040000;
const S_IFREG = 0o100000;

function dosDateTime(date) {
  const year = Math.max(1980, date.getFullYear());
  const time = (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2);
  const day = ((year - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate();
  return { time, day };
}

/** Compressing these again gains nothing. */
const STORED = /\.(zip|gz|xz|tpz|png|jpg|jpeg|ogg|mp3|glb|webp|wasm|pck)$/i;

export class ZipWriter {
  constructor(file) {
    this.fd = openSync(file, 'w');
    this.offset = 0;
    this.entries = [];
    this.names = new Set();
  }

  #write(buf) {
    writeSync(this.fd, buf);
    this.offset += buf.length;
  }

  /** Adds a folder entry (`name` ends with or without "/"). */
  addDir(name, mode = 0o755) {
    const n = name.endsWith('/') ? name : `${name}/`;
    if (this.names.has(n)) return;
    this.#add(n, Buffer.alloc(0), (S_IFDIR | mode) >>> 0, 0x10);
  }

  /** Adds a file. `mode` is its Unix permission bits (0o755 for programs). */
  addFile(name, data, mode = 0o644) {
    if (this.names.has(name)) throw new Error(`duplicate zip entry ${name}`);
    this.#add(name, data, (S_IFREG | mode) >>> 0, 0);
  }

  #add(name, data, unixMode, dosAttr) {
    if (this.entries.length >= 0xffff) throw new Error('too many zip entries for a non-Zip64 archive');
    this.names.add(name);
    const nameBuf = Buffer.from(name, 'utf8');
    const crc = crc32(data);
    const deflate = data.length > 0 && !STORED.test(name);
    const body = deflate ? deflateRawSync(data, { level: 9 }) : data;
    const method = deflate && body.length < data.length ? 8 : 0;
    const payload = method === 8 ? body : data;
    if (this.offset + payload.length > 0xffffffff - 0x10000) throw new Error('zip archive would exceed 4 GB');
    const { time, day } = dosDateTime(new Date());
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0x0800, 6); // UTF-8 names
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(time, 10);
    local.writeUInt16LE(day, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(payload.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    local.writeUInt16LE(0, 28);
    const at = this.offset;
    this.#write(local);
    this.#write(nameBuf);
    this.#write(payload);
    this.entries.push({ nameBuf, method, time, day, crc, csize: payload.length, usize: data.length, at, external: ((unixMode << 16) | dosAttr) >>> 0 });
  }

  close() {
    const start = this.offset;
    for (const e of this.entries) {
      const h = Buffer.alloc(46);
      h.writeUInt32LE(0x02014b50, 0);
      h.writeUInt16LE((3 << 8) | 20, 4); // made by Unix, version 2.0
      h.writeUInt16LE(20, 6);
      h.writeUInt16LE(0x0800, 8);
      h.writeUInt16LE(e.method, 10);
      h.writeUInt16LE(e.time, 12);
      h.writeUInt16LE(e.day, 14);
      h.writeUInt32LE(e.crc, 16);
      h.writeUInt32LE(e.csize, 20);
      h.writeUInt32LE(e.usize, 24);
      h.writeUInt16LE(e.nameBuf.length, 28);
      h.writeUInt16LE(0, 30); // extra
      h.writeUInt16LE(0, 32); // comment
      h.writeUInt16LE(0, 34); // disk
      h.writeUInt16LE(0, 36); // internal attributes
      h.writeUInt32LE(e.external, 38);
      h.writeUInt32LE(e.at, 42);
      this.#write(h);
      this.#write(e.nameBuf);
    }
    const size = this.offset - start;
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0);
    end.writeUInt16LE(this.entries.length, 8);
    end.writeUInt16LE(this.entries.length, 10);
    end.writeUInt32LE(size, 12);
    end.writeUInt32LE(start, 16);
    this.#write(end);
    closeSync(this.fd);
  }
}

function readAt(fd, position, length) {
  const buf = Buffer.alloc(length);
  let done = 0;
  while (done < length) {
    const n = readSync(fd, buf, done, length - done, position + done);
    if (n === 0) throw new Error('unexpected end of zip file');
    done += n;
  }
  return buf;
}

/**
 * Opens a zip archive. Returns its entries, each { name, isDir, mode, size, read() }, where
 * `mode` is the Unix permission bits when the archive recorded them (else 0o644, or 0o755 for
 * folders) and read() returns the entry's uncompressed bytes. Call close() when done.
 */
export function openZip(file) {
  const fd = openSync(file, 'r');
  try {
    const size = fstatSync(fd).size;
    const tailLength = Math.min(size, 65557);
    const tail = readAt(fd, size - tailLength, tailLength);
    let eocd = -1;
    for (let i = tail.length - 22; i >= 0; i--) {
      if (tail.readUInt32LE(i) === 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw new Error(`${file} is not a zip archive`);
    let count = tail.readUInt16LE(eocd + 10);
    let cdSize = tail.readUInt32LE(eocd + 12);
    let cdOffset = tail.readUInt32LE(eocd + 16);
    if (count === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) {
      // Zip64: the end-of-central-directory locator sits just before the classic record.
      const locator = eocd - 20;
      if (locator < 0 || tail.readUInt32LE(locator) !== 0x07064b50) throw new Error(`${file}: missing Zip64 locator`);
      const recordAt = Number(tail.readBigUInt64LE(locator + 8));
      const record = readAt(fd, recordAt, 56);
      if (record.readUInt32LE(0) !== 0x06064b50) throw new Error(`${file}: bad Zip64 record`);
      count = Number(record.readBigUInt64LE(32));
      cdSize = Number(record.readBigUInt64LE(40));
      cdOffset = Number(record.readBigUInt64LE(48));
    }
    const cd = readAt(fd, cdOffset, cdSize);
    const entries = [];
    let p = 0;
    for (let i = 0; i < count; i++) {
      if (cd.readUInt32LE(p) !== 0x02014b50) throw new Error(`${file}: bad central directory`);
      const madeBy = cd.readUInt16LE(p + 4) >> 8;
      const method = cd.readUInt16LE(p + 10);
      let csize = cd.readUInt32LE(p + 20);
      let usize = cd.readUInt32LE(p + 24);
      const nlen = cd.readUInt16LE(p + 28);
      const xlen = cd.readUInt16LE(p + 30);
      const clen = cd.readUInt16LE(p + 32);
      const external = cd.readUInt32LE(p + 38);
      let at = cd.readUInt32LE(p + 42);
      const name = cd.toString('utf8', p + 46, p + 46 + nlen);
      // Zip64 extra field: the 64-bit values, in order, for the fields that hold 0xffffffff.
      let x = p + 46 + nlen;
      const xend = x + xlen;
      while (x + 4 <= xend) {
        const id = cd.readUInt16LE(x);
        const len = cd.readUInt16LE(x + 2);
        if (id === 0x0001) {
          let q = x + 4;
          if (usize === 0xffffffff) { usize = Number(cd.readBigUInt64LE(q)); q += 8; }
          if (csize === 0xffffffff) { csize = Number(cd.readBigUInt64LE(q)); q += 8; }
          if (at === 0xffffffff) { at = Number(cd.readBigUInt64LE(q)); q += 8; }
        }
        x += 4 + len;
      }
      p += 46 + nlen + xlen + clen;
      const isDir = name.endsWith('/');
      const unix = madeBy === 3 ? (external >>> 16) & 0o7777 : 0;
      const mode = unix || (isDir ? 0o755 : 0o644);
      entries.push({
        name,
        isDir,
        mode,
        size: usize,
        read() {
          const local = readAt(fd, at, 30);
          if (local.readUInt32LE(0) !== 0x04034b50) throw new Error(`${file}: bad local header for ${name}`);
          const dataAt = at + 30 + local.readUInt16LE(26) + local.readUInt16LE(28);
          const raw = readAt(fd, dataAt, csize);
          if (method === 0) return raw;
          if (method === 8) return inflateRawSync(raw);
          throw new Error(`${file}: ${name} uses unsupported compression method ${method}`);
        },
      });
    }
    return { entries, close: () => closeSync(fd) };
  } catch (err) {
    closeSync(fd);
    throw err;
  }
}
