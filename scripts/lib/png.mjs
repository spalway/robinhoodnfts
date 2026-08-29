// Minimal, deterministic PNG encoder — 8-bit truecolour, no alpha.
//
// Written here rather than pulled in because the export has exactly one
// requirement a general image library does not promise: THE SAME SERIAL MUST
// PRODUCE THE SAME BYTES, on every machine, forever. A native encoder (libpng
// via sharp, say) picks filters and zlib strategy from whatever version happens
// to be installed, so two operators re-running the export get two different
// files for art that did not change — and a storage bucket full of spurious
// diffs is indistinguishable from art that actually drifted.
//
// Everything below is fixed: filter choice is a deterministic heuristic, the
// deflate settings are pinned, and there is no timestamp, no text chunk and no
// gAMA/sRGB chunk to carry environment into the output.
//
// No alpha because the artwork has none. The background layer always covers the
// full box — a solid fill, a tiled gradient over an opaque base colour, or a
// cover-cropped photograph — so every exported pixel is opaque. Emitting RGBA
// would cost 25% of the file to store a channel that is 255 everywhere.
import { deflateSync, constants as zlibConstants } from 'node:zlib'

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

function crc32(buf) {
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function chunk(type, data) {
  const out = Buffer.allocUnsafe(data.length + 12)
  out.writeUInt32BE(data.length, 0)
  out.write(type, 4, 'ascii')
  data.copy(out, 8)
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length)
  return out
}

/** Paeth predictor, verbatim from the PNG spec. */
function paeth(a, b, c) {
  const p = a + b - c
  const pa = Math.abs(p - a)
  const pb = Math.abs(p - b)
  const pc = Math.abs(p - c)
  if (pa <= pb && pa <= pc) return a
  if (pb <= pc) return b
  return c
}

const BPP = 3

/**
 * Filter one scanline five ways and keep the cheapest.
 *
 * The heuristic is the one the PNG spec recommends — minimum sum of absolute
 * values treating each filtered byte as signed — and it is used unchanged
 * precisely because it is a rule rather than a judgement: a "smarter" encoder
 * that consults entropy would make its choice depend on its own version.
 *
 * Candidates are written into caller-owned scratch buffers so a 5,000-image run
 * does not allocate 25,000 scanline buffers per image.
 */
function filterScanline(row, prev, width, cand, sums) {
  const n = width * BPP
  for (let f = 0; f < 5; f++) sums[f] = 0

  for (let i = 0; i < n; i++) {
    const x = row[i]
    const a = i >= BPP ? row[i - BPP] : 0
    const b = prev[i]
    const c = i >= BPP ? prev[i - BPP] : 0

    const v0 = x
    const v1 = (x - a) & 0xff
    const v2 = (x - b) & 0xff
    const v3 = (x - ((a + b) >> 1)) & 0xff
    const v4 = (x - paeth(a, b, c)) & 0xff

    cand[0][i] = v0
    cand[1][i] = v1
    cand[2][i] = v2
    cand[3][i] = v3
    cand[4][i] = v4

    // Signed magnitude: a byte >= 128 is a small negative number, not a large
    // positive one, and scoring it as large is how a filter heuristic picks the
    // worst option on smooth gradients.
    sums[0] += v0 < 128 ? v0 : 256 - v0
    sums[1] += v1 < 128 ? v1 : 256 - v1
    sums[2] += v2 < 128 ? v2 : 256 - v2
    sums[3] += v3 < 128 ? v3 : 256 - v3
    sums[4] += v4 < 128 ? v4 : 256 - v4
  }

  let best = 0
  for (let f = 1; f < 5; f++) if (sums[f] < sums[best]) best = f
  return best
}

/**
 * @param {{ width: number, height: number, rgb: Uint8Array }} image
 *        `rgb` is width*height*3 bytes, row-major, no padding.
 * @returns {Buffer} a complete PNG file.
 */
export function encodePng({ width, height, rgb }) {
  if (rgb.length !== width * height * BPP) {
    throw new Error(`encodePng: expected ${width * height * BPP} bytes, got ${rgb.length}`)
  }

  const stride = width * BPP
  const raw = Buffer.allocUnsafe(height * (stride + 1))
  const prev = new Uint8Array(stride)
  const cand = [
    new Uint8Array(stride),
    new Uint8Array(stride),
    new Uint8Array(stride),
    new Uint8Array(stride),
    new Uint8Array(stride),
  ]
  const sums = new Float64Array(5)

  for (let y = 0; y < height; y++) {
    const row = rgb.subarray(y * stride, (y + 1) * stride)
    const best = filterScanline(row, prev, width, cand, sums)
    raw[y * (stride + 1)] = best
    Buffer.from(cand[best].buffer, cand[best].byteOffset, stride).copy(raw, y * (stride + 1) + 1)
    prev.set(row)
  }

  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 2 // colour type 2 = truecolour, no alpha
  ihdr[10] = 0 // deflate
  ihdr[11] = 0 // adaptive filtering
  ihdr[12] = 0 // no interlace

  // Pinned so the bytes do not move when node's bundled zlib does. Level 9 with
  // the default strategy is what every PNG tool means by "maximum".
  const idat = deflateSync(raw, {
    level: 9,
    strategy: zlibConstants.Z_DEFAULT_STRATEGY,
    memLevel: 9,
    windowBits: 15,
  })

  return Buffer.concat([
    SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ])
}
