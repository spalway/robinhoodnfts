// The browser half of the renderer, in Node.
//
// src/lib/backgrounds.ts returns a React `style` object, not pixels. On the site
// a browser turns that into a picture; there is no browser here, so this module
// implements the exact subset of CSS that `backgroundFor()` emits: colour
// notation, the four filter functions used on the X-RATED scenes, one
// repeating-linear-gradient form and one radial-gradient form.
//
// TWO RULES GOVERN EVERYTHING BELOW.
//
// 1. It parses the real declaration rather than re-deriving the numbers.
//    backgrounds.ts is another track's file and it will change. Reading the
//    string the browser reads means a new hue band or a new ray form flows into
//    the export without anyone remembering to update it here.
//
// 2. It THROWS on anything it does not recognise, and never falls back.
//    A renderer that quietly skips a declaration it cannot parse ships 5,000
//    plausible-looking images that are not the art — the single failure this
//    export exists to avoid. An unparsed declaration must stop the run.

const CLAMP_255 = (v) => (v < 0 ? 0 : v > 255 ? 255 : v)

// ---------------------------------------------------------------------------
// colour
// ---------------------------------------------------------------------------

/** hsl() with the modern space-separated syntax — the only form backgrounds.ts emits. */
function parseHsl(text) {
  const m = /^hsl\(\s*([\d.]+)\s+([\d.]+)%\s+([\d.]+)%\s*\)$/.exec(text)
  if (!m) return null
  const h = Number(m[1]) / 360
  const s = Number(m[2]) / 100
  const l = Number(m[3]) / 100

  if (s === 0) {
    const v = Math.round(l * 255)
    return [v, v, v, 1]
  }
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s
  const p = 2 * l - q
  const hue = (t) => {
    let x = t
    if (x < 0) x += 1
    if (x > 1) x -= 1
    if (x < 1 / 6) return p + (q - p) * 6 * x
    if (x < 1 / 2) return q
    if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6
    return p
  }
  return [
    Math.round(hue(h + 1 / 3) * 255),
    Math.round(hue(h) * 255),
    Math.round(hue(h - 1 / 3) * 255),
    1,
  ]
}

/**
 * CSS colour -> [r, g, b, a]. Channels are 0–255 integers, alpha is 0–1.
 *
 * Covers #rgb, #rrggbb, rgb()/rgba() and hsl(). Named colours are deliberately
 * absent: nothing in the art code uses one, and a partial name table is worse
 * than none — it would resolve `red` and silently mis-resolve `rebeccapurple`.
 */
export function parseColor(input) {
  const text = String(input).trim()

  if (text.startsWith('#')) {
    const hex = text.slice(1)
    if (hex.length === 3) {
      return [
        parseInt(hex[0] + hex[0], 16),
        parseInt(hex[1] + hex[1], 16),
        parseInt(hex[2] + hex[2], 16),
        1,
      ]
    }
    if (hex.length === 6) {
      return [
        parseInt(hex.slice(0, 2), 16),
        parseInt(hex.slice(2, 4), 16),
        parseInt(hex.slice(4, 6), 16),
        1,
      ]
    }
    throw new Error(`parseColor: unsupported hex colour ${text}`)
  }

  const rgb = /^rgba?\(([^)]*)\)$/.exec(text)
  if (rgb) {
    const parts = rgb[1].split(/[,\s/]+/).filter(Boolean).map(Number)
    if (parts.length < 3 || parts.some(Number.isNaN)) {
      throw new Error(`parseColor: unsupported rgb colour ${text}`)
    }
    return [
      CLAMP_255(Math.round(parts[0])),
      CLAMP_255(Math.round(parts[1])),
      CLAMP_255(Math.round(parts[2])),
      parts.length > 3 ? parts[3] : 1,
    ]
  }

  const hsl = parseHsl(text)
  if (hsl) return hsl

  throw new Error(`parseColor: unsupported colour notation ${text}`)
}

// ---------------------------------------------------------------------------
// filter functions
// ---------------------------------------------------------------------------
//
// Filter Effects Level 1 defines each shorthand as an equivalent SVG filter
// primitive, and the shorthands run with color-interpolation-filters: sRGB —
// so the maths is on the non-linear 0–1 sRGB values, NOT on linearised light.
// Getting that wrong would darken every X-RATED backdrop by roughly a stop.
//
// Results are clamped between functions because each shorthand is its own
// primitive and a primitive's result is clamped to its range. That is not a
// detail here: `imageSpec()` reaches brightness(6.5) on the near-black sources,
// and whether the following contrast() sees 6.5 or a clamped 1.0 is the whole
// difference between a blown-out scene and a lifted one.

function saturateMatrix(s) {
  return [
    0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s,
    0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s,
    0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s,
  ]
}

function hueRotateMatrix(deg) {
  const rad = (deg * Math.PI) / 180
  const c = Math.cos(rad)
  const s = Math.sin(rad)
  return [
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
  ]
}

/**
 * Parse a `filter:` shorthand chain into a list of per-pixel stages.
 *
 * Only the four functions backgrounds.ts uses are implemented. Anything else —
 * blur, drop-shadow, a filter that needs neighbouring pixels — throws, because
 * a convolution silently dropped from an export is invisible until someone
 * compares a card against a file.
 */
export function parseFilter(spec) {
  const stages = []
  const re = /([a-z-]+)\(([^)]*)\)/g
  let m
  let matched = 0
  while ((m = re.exec(spec)) !== null) {
    matched++
    const fn = m[1]
    const arg = m[2].trim()
    switch (fn) {
      case 'hue-rotate': {
        const deg = /deg$/.test(arg) ? Number(arg.slice(0, -3)) : Number(arg)
        if (Number.isNaN(deg)) throw new Error(`parseFilter: bad hue-rotate ${arg}`)
        stages.push({ kind: 'matrix', m: hueRotateMatrix(deg) })
        break
      }
      case 'saturate': {
        const s = arg.endsWith('%') ? Number(arg.slice(0, -1)) / 100 : Number(arg)
        if (Number.isNaN(s)) throw new Error(`parseFilter: bad saturate ${arg}`)
        stages.push({ kind: 'matrix', m: saturateMatrix(s) })
        break
      }
      case 'brightness': {
        const b = arg.endsWith('%') ? Number(arg.slice(0, -1)) / 100 : Number(arg)
        if (Number.isNaN(b)) throw new Error(`parseFilter: bad brightness ${arg}`)
        stages.push({ kind: 'linear', slope: b, intercept: 0 })
        break
      }
      case 'contrast': {
        const c = arg.endsWith('%') ? Number(arg.slice(0, -1)) / 100 : Number(arg)
        if (Number.isNaN(c)) throw new Error(`parseFilter: bad contrast ${arg}`)
        stages.push({ kind: 'linear', slope: c, intercept: 0.5 - 0.5 * c })
        break
      }
      default:
        throw new Error(`parseFilter: unsupported filter function ${fn}()`)
    }
  }
  if (matched === 0 && spec.trim() && spec.trim() !== 'none') {
    throw new Error(`parseFilter: could not parse ${spec}`)
  }
  return stages
}

/**
 * Build a 256x3 lookup table when the chain permits one, else a per-pixel fn.
 *
 * A chain of only `linear` stages is separable per channel, so 768 evaluations
 * cover every pixel in the image. A matrix stage mixes channels and defeats
 * that; those are evaluated per pixel. X-RATED scenes always carry a
 * hue-rotate, so in practice this returns the per-pixel path — the table exists
 * so a future filter chain without one is not needlessly slow.
 */
export function compileFilter(spec) {
  const stages = parseFilter(spec)
  if (stages.length === 0) return null

  const separable = stages.every((s) => s.kind === 'linear')
  if (separable) {
    const lut = new Uint8Array(256)
    for (let i = 0; i < 256; i++) {
      let v = i / 255
      for (const s of stages) {
        v = v * s.slope + s.intercept
        v = v < 0 ? 0 : v > 1 ? 1 : v
      }
      lut[i] = Math.round(v * 255)
    }
    return (out, r, g, b) => {
      out[0] = lut[r]
      out[1] = lut[g]
      out[2] = lut[b]
    }
  }

  return (out, r, g, b) => {
    let cr = r / 255
    let cg = g / 255
    let cb = b / 255
    for (const s of stages) {
      if (s.kind === 'matrix') {
        const m = s.m
        const nr = m[0] * cr + m[1] * cg + m[2] * cb
        const ng = m[3] * cr + m[4] * cg + m[5] * cb
        const nb = m[6] * cr + m[7] * cg + m[8] * cb
        cr = nr
        cg = ng
        cb = nb
      } else {
        cr = cr * s.slope + s.intercept
        cg = cg * s.slope + s.intercept
        cb = cb * s.slope + s.intercept
      }
      cr = cr < 0 ? 0 : cr > 1 ? 1 : cr
      cg = cg < 0 ? 0 : cg > 1 ? 1 : cg
      cb = cb < 0 ? 0 : cb > 1 ? 1 : cb
    }
    out[0] = Math.round(cr * 255)
    out[1] = Math.round(cg * 255)
    out[2] = Math.round(cb * 255)
  }
}

// ---------------------------------------------------------------------------
// value lists and gradients
// ---------------------------------------------------------------------------

/**
 * Split a comma-separated CSS value list at the TOP level only.
 *
 * `background-image` is a list of layers and every layer here is a
 * function call containing its own commas, so a plain `.split(',')` shreds it.
 */
export function splitTopLevel(value) {
  const out = []
  let depth = 0
  let start = 0
  for (let i = 0; i < value.length; i++) {
    const ch = value[i]
    if (ch === '(') depth++
    else if (ch === ')') depth--
    else if (ch === ',' && depth === 0) {
      out.push(value.slice(start, i).trim())
      start = i + 1
    }
  }
  out.push(value.slice(start).trim())
  return out.filter((s) => s.length > 0)
}

/**
 * `repeating-linear-gradient(<angle>deg, <color> <a>px <b>px, ...)`.
 *
 * raysSpec() doubles every stop at the same offset, which is exactly what makes
 * the edges hard instead of blended — so the gradient is a STEP function of
 * distance along the gradient line and is modelled as one. Nothing here
 * interpolates, and a declaration whose stops do not butt up against each other
 * throws rather than being rendered as if they did.
 */
export function parseRepeatingLinearGradient(layer) {
  const m = /^repeating-linear-gradient\((.*)\)$/s.exec(layer)
  if (!m) throw new Error(`parseRepeatingLinearGradient: not a repeating-linear-gradient: ${layer}`)

  const parts = splitTopLevel(m[1])
  const angleText = parts.shift()
  const angle = /^(-?[\d.]+)deg$/.exec(angleText.trim())
  if (!angle) throw new Error(`parseRepeatingLinearGradient: unsupported angle ${angleText}`)

  const stops = []
  for (const part of parts) {
    const s = /^(.+?)\s+(-?[\d.]+)(px)?\s+(-?[\d.]+)px$/.exec(part.trim())
    if (!s) throw new Error(`parseRepeatingLinearGradient: unsupported stop "${part}"`)
    stops.push({ color: parseColor(s[1]), from: Number(s[2]), to: Number(s[4]) })
  }
  if (stops.length === 0) throw new Error('parseRepeatingLinearGradient: no stops')

  for (let i = 1; i < stops.length; i++) {
    if (Math.abs(stops[i].from - stops[i - 1].to) > 1e-9) {
      throw new Error(
        'parseRepeatingLinearGradient: stops are not contiguous — this renderer models hard ' +
          'stops only and would silently drop the blend between them',
      )
    }
  }

  return {
    angle: Number(angle[1]),
    stops,
    // The repeat period of a repeating gradient is first stop -> last stop.
    period: stops[stops.length - 1].to - stops[0].from,
    origin: stops[0].from,
  }
}

/**
 * `radial-gradient(circle at X% Y%, <color> 0 Rpx, <transparent> Rpx)`.
 *
 * The star dots in raysSpec(). Again a hard stop, so this is a filled disc of
 * radius R and nothing else; the ending-shape size (farthest-corner) never
 * matters because the last stop is transparent.
 */
export function parseRadialGradientDot(layer) {
  const m = /^radial-gradient\((.*)\)$/s.exec(layer)
  if (!m) throw new Error(`parseRadialGradientDot: not a radial-gradient: ${layer}`)

  const parts = splitTopLevel(m[1])
  const shape = /^circle\s+at\s+([\d.]+)%\s+([\d.]+)%$/.exec(parts.shift().trim())
  if (!shape) throw new Error(`parseRadialGradientDot: unsupported shape in ${layer}`)

  if (parts.length !== 2) {
    throw new Error(`parseRadialGradientDot: expected two stops, got ${parts.length}`)
  }
  const inner = /^(.+?)\s+0\s+([\d.]+)px$/.exec(parts[0].trim())
  const outer = /^(.+?)\s+([\d.]+)px$/.exec(parts[1].trim())
  if (!inner || !outer) throw new Error(`parseRadialGradientDot: unsupported stops in ${layer}`)
  if (Math.abs(Number(inner[2]) - Number(outer[2])) > 1e-9) {
    throw new Error('parseRadialGradientDot: stops are not coincident — this is not a hard dot')
  }
  const outerColor = parseColor(outer[1])
  if (outerColor[3] !== 0) {
    throw new Error('parseRadialGradientDot: outer stop is not transparent')
  }

  return {
    cxPct: Number(shape[1]) / 100,
    cyPct: Number(shape[2]) / 100,
    radius: Number(inner[2]),
    color: parseColor(inner[1]),
  }
}

/** `68px 68px` -> [68, 68]; `auto` -> null (meaning "the whole box"). */
export function parseBackgroundSize(value) {
  const text = value.trim()
  if (text === 'auto') return null
  const m = /^(-?[\d.]+)px\s+(-?[\d.]+)px$/.exec(text)
  if (!m) throw new Error(`parseBackgroundSize: unsupported value ${value}`)
  return [Number(m[1]), Number(m[2])]
}

/** `4px 3px` and `0 0` -> [x, y] in CSS px. */
export function parseBackgroundPosition(value) {
  const text = value.trim()
  const m = /^(-?[\d.]+)(?:px)?\s+(-?[\d.]+)(?:px)?$/.exec(text)
  if (!m) throw new Error(`parseBackgroundPosition: unsupported value ${value}`)
  return [Number(m[1]), Number(m[2])]
}
