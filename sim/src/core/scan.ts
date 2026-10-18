import { computeIndices, type Indices } from "./indices"
import type { Point } from "./types"

/** Own-scan pipeline: STL/OBJ triangles -> units, floor, heel/toe and medial side -> canonical frame
 *  (mm, x medial for a left foot, y heel -> toe from 0, z up, sole on z = 0) -> measurements and the
 *  insole outline. Pure, no DOM or three.js, ported from datasets/analysis/scan_measure.py (which
 *  was validated on the Schuster scans) with orientation added so any file orientation works. */

/** Indexed triangle mesh, canonical frame, mm. Right feet are mirrored to left (winding flipped). */
export interface TriMesh {
  positions: Float32Array
  indices: Uint32Array
}

export type AhiClass = "lower" | "typical" | "higher"

export interface ScanResult {
  mesh: TriMesh
  /** Which foot the file contained (the mesh itself is always the left-foot mirror image). */
  side: "left" | "right"
  /** False when the side cues were too weak or disagreed, so `side` is a guess the user should confirm. */
  sideSure: boolean
  /** The file's units were scaled by this to get mm (1 = mm, 1000 = meters, 10 = cm). */
  unitScale: number
  /** Affine map from the file's coordinates to the canonical frame, 4x4 column-major (three.js Matrix4 order). Negative
   *  determinant for a mirrored right foot. Places other exports of the same capture (the textured USDZ) on this scan. */
  toCanonical: number[]
  /** mm */
  length: number
  ballWidth: number
  heelWidth: number
  /** Heel to 1st metatarsal head, 0.73 of the length (anthropometric approximation). */
  truncLength: number
  /** Highest surface point at 50% of the length. */
  dorsumHeight: number
  /** Arch Height Index (Butler 2008): dorsumHeight / truncLength. */
  ahi: number
  ahiClass: AhiClass
  /** Height of the medial skin edge over the floor through the midfoot, mm. */
  medialArchHeight: number
  /** y of the highest point of the medial arch profile, mm from the heel. */
  medialArchY: number
  /** False when the underside is a hole fill (a standing scan never saw the sole). */
  soleObserved: boolean
  /** Share of the underside area made of large flat triangles. */
  fillShare: number
  /** Cavanagh / Staheli / Chippaux-Smirak from the virtual footprint (underside within 3 mm of the floor). Only meaningful when `soleObserved`. */
  footprint: Indices | null
  /** Insole outline: the foot silhouette near the floor, smoothed and offset outward, counter-clockwise. */
  outline: Point[]
  /** Heel/toe call: z-spread of the two ends (confidence). Side call cues, mm, > 0 pointing to a left foot: the forefoot
   *  height difference across the foot (`sideMargin`, decides) and the toe-tip lean (`toeLean`, confirms). */
  checks: { heelToeRatio: number; sideMargin: number; toeLean: number; ballWiderThanHeel: boolean }
}

// Butler 2008 AHI cutoffs. Our healthy-cohort scan pipeline reads about 0.37 +/- 0.03, i.e. higher than Butler's
// 0.340 +/- 0.030, so "higher" is common; read the class as a rough guide.
export const AHI_LOWER = 0.315
export const AHI_HIGHER = 0.365

const TRUNC_FRAC = 0.73
const FOOT_Z = 50
const CONTACT_MM = 3
const SILHOUETTE_Z = 20
const OUTLINE_OFFSET = 3
/** Longest edge above this (mm) marks a hole-fill triangle; real sole scans have about 2 mm triangles. */
const FILL_EDGE = 5
const FILL_SHARE_LIMIT = 0.5
/** A sure side call needs both cues past these, mm (see `orient`). */
const SIDE_RISE_MM = 4
const SIDE_LEAN_MM = 3

// ---------- parsing ----------

/** Triangle soup (9 floats per triangle) from a binary or ASCII STL. */
export function parseStl(buf: ArrayBuffer): Float32Array {
  const dv = new DataView(buf)
  if (buf.byteLength >= 84) {
    const n = dv.getUint32(80, true)
    if (84 + n * 50 === buf.byteLength) {
      const soup = new Float32Array(n * 9)
      for (let t = 0; t < n; t++)
        for (let k = 0; k < 9; k++) soup[t * 9 + k] = dv.getFloat32(84 + t * 50 + 12 + k * 4, true)
      return soup
    }
  }
  const out: number[] = []
  for (const m of new TextDecoder().decode(buf).matchAll(/vertex\s+(\S+)\s+(\S+)\s+(\S+)/g)) out.push(+m[1], +m[2], +m[3])
  if (out.length === 0 || out.length % 9 !== 0 || out.some(Number.isNaN)) throw new Error("This STL file could not be read.")
  return Float32Array.from(out)
}

/** Triangle soup from a Wavefront OBJ (polygons are fanned). */
export function parseObj(text: string): Float32Array {
  const verts: number[] = []
  const out: number[] = []
  for (const line of text.split("\n")) {
    const p = line.trim().split(/\s+/)
    if (p[0] === "v") verts.push(+p[1], +p[2], +p[3])
    else if (p[0] === "f") {
      const idx = p.slice(1).map((s) => {
        const i = parseInt(s, 10)
        return (i < 0 ? verts.length / 3 + i : i - 1) * 3
      })
      for (let k = 1; k + 1 < idx.length; k++) for (const i of [idx[0], idx[k], idx[k + 1]]) out.push(verts[i], verts[i + 1], verts[i + 2])
    }
  }
  if (out.length === 0 || out.some(Number.isNaN)) throw new Error("This OBJ file could not be read.")
  return Float32Array.from(out)
}

/** Picks the parser from the file name. USDZ is a zip of a USD scene and is not read here. */
export function parseScanFile(name: string, buf: ArrayBuffer): Float32Array {
  const ext = name.toLowerCase().split(".").pop()
  if (ext === "stl") return parseStl(buf)
  if (ext === "obj") return parseObj(new TextDecoder().decode(buf))
  if (ext === "usdz" || ext === "usd") throw new Error("Export as STL from your scanning app.")
  throw new Error("Use an STL or OBJ file.")
}

// ---------- small vector helpers ----------

type V3 = [number, number, number]
const dot = (a: V3, b: V3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
const cross = (a: V3, b: V3): V3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
const norm = (a: V3): V3 => {
  const l = Math.hypot(...a) || 1
  return [a[0] / l, a[1] / l, a[2] / l]
}
const median = (xs: number[]) => (xs.length ? [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] : NaN)
const quantile = (sorted: Float64Array, q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]

/** Units guess from the bounding box: a foot scan with its leg is 0.2-0.6 m, 20-60 cm or 200-600 mm. */
function unitScaleFor(soup: Float32Array): number {
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity]
  for (let i = 0; i < soup.length; i++) {
    lo[i % 3] = Math.min(lo[i % 3], soup[i])
    hi[i % 3] = Math.max(hi[i % 3], soup[i])
  }
  const ext = Math.max(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2])
  return ext < 3 ? 1000 : ext < 60 ? 10 : 1
}

/** Welds the soup into shared vertices (0.01 mm grid) and drops degenerate triangles. */
function weld(soup: Float32Array, scale: number): { v: Float64Array; f: Uint32Array } {
  const map = new Map<string, number>()
  const v: number[] = []
  const f: number[] = []
  const tri = [0, 0, 0]
  for (let t = 0; t < soup.length / 9; t++) {
    for (let k = 0; k < 3; k++) {
      const x = soup[t * 9 + k * 3] * scale, y = soup[t * 9 + k * 3 + 1] * scale, z = soup[t * 9 + k * 3 + 2] * scale
      const key = `${Math.round(x * 100)},${Math.round(y * 100)},${Math.round(z * 100)}`
      let id = map.get(key)
      if (id === undefined) map.set(key, (id = v.length / 3)), v.push(x, y, z)
      tri[k] = id
    }
    if (tri[0] !== tri[1] && tri[1] !== tri[2] && tri[0] !== tri[2]) f.push(tri[0], tri[1], tri[2])
  }
  return { v: Float64Array.from(v), f: Uint32Array.from(f) }
}

/** Least-squares affine map taking `src` points (file units times `unitScale`) to `dst`, as a column-major 4x4 acting
 *  on unscaled file coordinates. Exact here, since the canonical frame is an affine image of the file. */
function fitAffine(src: Float64Array, dst: Float32Array, unitScale: number): number[] {
  // Normal equations (A^T A) w = A^T b with rows [x, y, z, 1], solved once per output axis.
  const ata = Array.from({ length: 4 }, () => [0, 0, 0, 0]), atb = Array.from({ length: 4 }, () => [0, 0, 0])
  for (let i = 0; i < src.length; i += 3) {
    const row = [src[i], src[i + 1], src[i + 2], 1]
    for (let r = 0; r < 4; r++) {
      for (let c = 0; c < 4; c++) ata[r][c] += row[r] * row[c]
      for (let k = 0; k < 3; k++) atb[r][k] += row[r] * dst[i + k]
    }
  }
  // Gauss-Jordan with partial pivoting on [ata | atb].
  const m = ata.map((r, i) => [...r, ...atb[i]])
  for (let c = 0; c < 4; c++) {
    const piv = m.slice(c).reduce((best, r, i) => (Math.abs(r[c]) > Math.abs(m[best][c]) ? c + i : best), c)
    ;[m[c], m[piv]] = [m[piv], m[c]]
    for (let r = 0; r < 4; r++) {
      if (r === c) continue
      const f = m[r][c] / m[c][c]
      for (let k = c; k < 7; k++) m[r][k] -= f * m[c][k]
    }
  }
  const w = (r: number, k: number) => m[r][4 + k] / m[r][r] // weight of input r on output axis k
  // Column-major: column j holds input j's contribution to (x, y, z); the linear part also absorbs the unit scale.
  return [
    w(0, 0) * unitScale, w(0, 1) * unitScale, w(0, 2) * unitScale, 0,
    w(1, 0) * unitScale, w(1, 1) * unitScale, w(1, 2) * unitScale, 0,
    w(2, 0) * unitScale, w(2, 1) * unitScale, w(2, 2) * unitScale, 0,
    w(3, 0), w(3, 1), w(3, 2), 1,
  ]
}

// ---------- floor ----------

/** Direction that sees the largest flat patch at its low end: the sole (or its hole fill) resting on the floor.
 *  Coarse sphere search with a wide slab, then a hill climb with a narrower one. Works for any file orientation,
 *  upside down included. */
function findUp(v: Float64Array, f: Uint32Array): V3 {
  const nF = f.length / 3, nV = v.length / 3
  const fStride = Math.max(1, Math.floor(nF / 12000)), vStride = Math.max(1, Math.floor(nV / 20000))
  const area = (t: number) => {
    const [a, b, c] = [f[t * 3] * 3, f[t * 3 + 1] * 3, f[t * 3 + 2] * 3]
    return 0.5 * Math.hypot(...cross([v[b] - v[a], v[b + 1] - v[a + 1], v[b + 2] - v[a + 2]], [v[c] - v[a], v[c + 1] - v[a + 1], v[c + 2] - v[a + 2]]))
  }
  const sample: number[] = [], areas: number[] = []
  for (let t = 0; t < nF; t += fStride) (sample.push(t), areas.push(area(t)))
  const score = (d: V3, band: number, vs: number) => {
    let lo = Infinity
    for (let i = 0; i < nV; i += vs) lo = Math.min(lo, v[i * 3] * d[0] + v[i * 3 + 1] * d[1] + v[i * 3 + 2] * d[2])
    const lim = lo + band
    let s = 0
    for (let k = 0; k < sample.length; k++) {
      const t = sample[k]
      let ok = true
      for (let j = 0; j < 3 && ok; j++) {
        const i = f[t * 3 + j] * 3
        ok = v[i] * d[0] + v[i + 1] * d[1] + v[i + 2] * d[2] < lim
      }
      if (ok) s += areas[k]
    }
    return s
  }
  let best: V3 = [0, 0, 1], bestScore = -1
  const N = 1500
  for (let i = 0; i < N; i++) {
    const z = 1 - (2 * (i + 0.5)) / N, r = Math.sqrt(1 - z * z), phi = i * Math.PI * (3 - Math.sqrt(5))
    const d: V3 = [r * Math.cos(phi), r * Math.sin(phi), z]
    const s = score(d, 12, vStride)
    if (s > bestScore) (bestScore = s, best = d)
  }
  let cur = score(best, 6, 1)
  for (const step of [4, 2, 1, 0.5, 0.25].map((x) => (x * Math.PI) / 180)) {
    for (let improved = true, guard = 0; improved && guard < 8; guard++) {
      improved = false
      const e1 = norm(cross(best, Math.abs(best[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0])), e2 = cross(best, e1)
      for (let k = 0; k < 8; k++) {
        const a = (k * Math.PI) / 4
        const d = norm([best[0] + step * (Math.cos(a) * e1[0] + Math.sin(a) * e2[0]), best[1] + step * (Math.cos(a) * e1[1] + Math.sin(a) * e2[1]), best[2] + step * (Math.cos(a) * e1[2] + Math.sin(a) * e2[2])])
        const s = score(d, 6, 1)
        if (s > cur) (cur = s, best = d, improved = true)
      }
    }
  }
  return best
}

/** Least-squares plane through the lowest 2% of vertices (trimmed at 2 mm) -> refined up vector. */
function refineUp(v: Float64Array, up: V3): V3 {
  const nV = v.length / 3
  for (let pass = 0; pass < 2; pass++) {
    const e1 = norm(cross(up, Math.abs(up[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0])), e2 = cross(up, e1)
    const h = new Float64Array(nV)
    for (let i = 0; i < nV; i++) h[i] = v[i * 3] * up[0] + v[i * 3 + 1] * up[1] + v[i * 3 + 2] * up[2]
    const cut = quantile(Float64Array.from(h).sort(), 0.02)
    let keep: number[] = []
    for (let i = 0; i < nV; i++) if (h[i] <= cut) keep.push(i)
    let coef = [0, 0, 0]
    for (let iter = 0; iter < 2; iter++) {
      // normal equations for h = p a + q b + c
      const m = [[0, 0, 0], [0, 0, 0], [0, 0, 0]], r = [0, 0, 0]
      for (const i of keep) {
        const row = [v[i * 3] * e1[0] + v[i * 3 + 1] * e1[1] + v[i * 3 + 2] * e1[2], v[i * 3] * e2[0] + v[i * 3 + 1] * e2[1] + v[i * 3 + 2] * e2[2], 1]
        for (let a = 0; a < 3; a++) {
          r[a] += row[a] * h[i]
          for (let b = 0; b < 3; b++) m[a][b] += row[a] * row[b]
        }
      }
      coef = solve3(m, r)
      if (iter === 0)
        keep = keep.filter((i) => {
          const a = v[i * 3] * e1[0] + v[i * 3 + 1] * e1[1] + v[i * 3 + 2] * e1[2], b = v[i * 3] * e2[0] + v[i * 3 + 1] * e2[1] + v[i * 3 + 2] * e2[2]
          return Math.abs(h[i] - (coef[0] * a + coef[1] * b + coef[2])) < 2
        })
    }
    up = norm([up[0] - coef[0] * e1[0] - coef[1] * e2[0], up[1] - coef[0] * e1[1] - coef[1] * e2[1], up[2] - coef[0] * e1[2] - coef[1] * e2[2]])
  }
  return up
}

function solve3(m: number[][], r: number[]): number[] {
  const a = m.map((row, i) => [...row, r[i]])
  for (let c = 0; c < 3; c++) {
    let p = c
    for (let i = c + 1; i < 3; i++) if (Math.abs(a[i][c]) > Math.abs(a[p][c])) p = i
    ;[a[c], a[p]] = [a[p], a[c]]
    if (Math.abs(a[c][c]) < 1e-12) return [0, 0, 0]
    for (let i = 0; i < 3; i++) {
      if (i === c) continue
      const k = a[i][c] / a[c][c]
      for (let j = c; j < 4; j++) a[i][j] -= k * a[c][j]
    }
  }
  return [a[0][3] / a[0][0], a[1][3] / a[1][1], a[2][3] / a[2][2]]
}

// ---------- orientation ----------

interface Oriented {
  x: Float64Array
  y: Float64Array
  z: Float64Array
  side: "left" | "right"
  sideSure: boolean
  mirrored: boolean
  checks: ScanResult["checks"]
}

/** Floor frame -> canonical frame. See ScanResult for the conventions. A given `side` skips the side call. */
function orient(v: Float64Array, up: V3, side?: ScanResult["side"]): Oriented {
  const n = v.length / 3
  const e1 = norm(cross(up, Math.abs(up[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0])), e2 = cross(up, e1) // e1 x e2 = up
  const a = new Float64Array(n), b = new Float64Array(n), z = new Float64Array(n)
  for (let i = 0; i < n; i++) {
    const p: V3 = [v[i * 3], v[i * 3 + 1], v[i * 3 + 2]]
    a[i] = dot(p, e1); b[i] = dot(p, e2); z[i] = dot(p, up)
  }
  const z0 = quantile(Float64Array.from(z).sort(), 0.001)
  for (let i = 0; i < n; i++) z[i] -= z0

  // Long axis: PCA of the plan view of everything near the floor.
  let ma = 0, mb = 0, cnt = 0
  for (let i = 0; i < n; i++) if (z[i] < 40) (ma += a[i], mb += b[i], cnt++)
  ma /= cnt; mb /= cnt
  let saa = 0, sbb = 0, sab = 0
  for (let i = 0; i < n; i++) if (z[i] < 40) (saa += (a[i] - ma) ** 2, sbb += (b[i] - mb) ** 2, sab += (a[i] - ma) * (b[i] - mb))
  const ang = 0.5 * Math.atan2(2 * sab, saa - sbb)
  const u = [Math.cos(ang), Math.sin(ang)]
  // Right-handed plan frame: s along the foot, t = s x z.
  let s = new Float64Array(n), t = new Float64Array(n)
  for (let i = 0; i < n; i++) {
    s[i] = (a[i] - ma) * u[0] + (b[i] - mb) * u[1]
    t[i] = (a[i] - ma) * u[1] - (b[i] - mb) * u[0]
  }
  const extent = (sel: (i: number) => boolean, arr: Float64Array) => {
    let lo = Infinity, hi = -Infinity
    for (let i = 0; i < n; i++) if (sel(i)) (lo = Math.min(lo, arr[i]), hi = Math.max(hi, arr[i]))
    return [lo, hi]
  }

  // Heel end: the ankle and leg stand over the heel, so that end's third is higher on average.
  let [s0, s1] = extent((i) => z[i] < FOOT_Z, s)
  const third = (s1 - s0) / 3
  let zr = 0, zl = 0, nr = 0, nl = 0
  for (let i = 0; i < n; i++) {
    if (s[i] < s0 + third) (zl += z[i], nl++)
    else if (s[i] > s1 - third) (zr += z[i], nr++)
  }
  const zLow = zl / Math.max(1, nl), zHigh = zr / Math.max(1, nr)
  if (zHigh > zLow) {
    for (let i = 0; i < n; i++) (s[i] = -s[i], t[i] = -t[i])
    ;[s0, s1] = [-s1, -s0]
  }
  const heelToeRatio = Math.max(zLow, zHigh) / Math.max(1e-6, Math.min(zLow, zHigh))
  const L = s1 - s0
  for (let i = 0; i < n; i++) s[i] -= s0

  // Medial side from two cues, both > 0 when +t is medial. The forefoot height decides; the call is sure only when both cues
  // clear their noise floor and agree. Neither pointed the wrong way on the 203 scans whose heel and toe were found (the
  // Schuster dataset plus four phone scans).
  // 1. The big toe and first metatarsal stand taller than the lateral forefoot: 95th-percentile height of the medial third
  //    of the width minus the lateral third, at 60-75% of the length. Read 5-17 mm, flat feet and filled soles included.
  const fore = (i: number) => s[i] >= 0.6 * L && s[i] <= 0.75 * L && z[i] < FOOT_Z
  const [flo, fhi] = extent(fore, t)
  const medZ: number[] = [], latZ: number[] = []
  for (let i = 0; i < n; i++) {
    if (!fore(i)) continue
    if (t[i] > fhi - (fhi - flo) / 3) medZ.push(z[i])
    else if (t[i] < flo + (fhi - flo) / 3) latZ.push(z[i])
  }
  const p95 = (zs: number[]) => quantile(Float64Array.from(zs).sort(), 0.95)
  const rise = p95(medZ) - p95(latZ)
  // 2. The toe tips lean toward the big toe. Read 6-37 mm, but 1.7 mm on a flat phone scan with straight toes.
  const mid = extent((i) => Math.abs(s[i] - 0.5 * L) < 20 && z[i] < FOOT_Z, t)
  let tip = 0, k = 0
  for (let i = 0; i < n; i++) if (s[i] > 0.94 * L && z[i] < FOOT_Z) (tip += t[i], k++)
  const toeLean = k ? tip / k - (mid[0] + mid[1]) / 2 : 0
  const sideSure = side !== undefined || (Math.abs(rise) >= SIDE_RISE_MM && Math.abs(toeLean) >= SIDE_LEAN_MM && Math.sign(rise) === Math.sign(toeLean))
  const medialPositive = side ? side === "left" : rise > 0
  const x = new Float64Array(n)
  // In a right-handed (x, y, z) frame x = y x z = t, so a left foot (medial on +x) keeps t; a right foot is mirrored.
  for (let i = 0; i < n; i++) x[i] = medialPositive ? t[i] : -t[i]
  const [xlo, xhi] = extent((i) => z[i] < FOOT_Z, x)
  const xc = (xlo + xhi) / 2
  for (let i = 0; i < n; i++) x[i] -= xc

  const ball = widthIn(s, x, z, L, 0.6, 0.78), heel = widthIn(s, x, z, L, 0.08, 0.2)
  return {
    x, y: s, z, side: medialPositive ? "left" : "right", sideSure, mirrored: !medialPositive,
    checks: { heelToeRatio, sideMargin: rise, toeLean, ballWiderThanHeel: ball > heel },
  }
}

/** Widest 5 mm slab (extent of x) between two fractions of the length, foot vertices only. */
function widthIn(y: Float64Array, x: Float64Array, z: Float64Array, L: number, f0: number, f1: number): number {
  const buckets = new Map<number, [number, number]>()
  for (let i = 0; i < y.length; i++) {
    if (z[i] >= FOOT_Z) continue
    const fr = y[i] / L
    if (fr < f0 || fr >= f1 + 5 / L) continue
    for (let lo = Math.floor((fr - 5 / L) * 100) / 100; lo <= fr; lo += 0.01) {
      if (lo < f0 - 1e-9 || lo > f1 - 1e-9 || fr >= lo + 5 / L) continue
      const k = Math.round(lo * 100)
      const e = buckets.get(k)
      if (!e) buckets.set(k, [x[i], x[i]])
      else (e[0] = Math.min(e[0], x[i]), e[1] = Math.max(e[1], x[i]))
    }
  }
  let best = 0
  for (const [lo, hi] of buckets.values()) best = Math.max(best, hi - lo)
  return best
}

// ---------- underside, footprint, outline ----------

interface Raster {
  nx: number
  ny: number
  x0: number
  y0: number
  data: Float32Array
}

/** 1 mm raster of the lowest downward-facing surface height (NaN where none), like scan_measure._underside_heightmap. */
function undersideHeights(m: TriMesh, bounds: { x0: number; y0: number; nx: number; ny: number }): Raster {
  const { x0, y0, nx, ny } = bounds
  const h = new Float32Array(nx * ny).fill(Infinity)
  const p = m.positions
  for (let t = 0; t < m.indices.length / 3; t++) {
    const [a, b, c] = [m.indices[t * 3] * 3, m.indices[t * 3 + 1] * 3, m.indices[t * 3 + 2] * 3]
    const nz = (p[b] - p[a]) * (p[c + 1] - p[a + 1]) - (p[b + 1] - p[a + 1]) * (p[c] - p[a])
    const len = Math.hypot(...cross([p[b] - p[a], p[b + 1] - p[a + 1], p[b + 2] - p[a + 2]], [p[c] - p[a], p[c + 1] - p[a + 1], p[c + 2] - p[a + 2]]))
    if (len === 0 || nz / len > -0.1 || (p[a + 2] + p[b + 2] + p[c + 2]) / 3 > 60) continue
    fillTriangle(p, a, b, c, x0, y0, nx, ny, (i, w) => { h[i] = Math.min(h[i], w[0] * p[a + 2] + w[1] * p[b + 2] + w[2] * p[c + 2]) })
  }
  for (let i = 0; i < h.length; i++) if (h[i] === Infinity) h[i] = NaN
  return { nx, ny, x0, y0, data: h }
}

/** Calls `put(cellIndex, barycentric)` for each 1 mm cell center inside the xy projection of a triangle. */
function fillTriangle(p: Float32Array, a: number, b: number, c: number, x0: number, y0: number, nx: number, ny: number, put: (i: number, w: V3) => void): void {
  const ax = p[a], ay = p[a + 1], bx = p[b], by = p[b + 1], cx = p[c], cy = p[c + 1]
  const d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
  if (Math.abs(d) < 1e-9) return
  const i0 = Math.max(0, Math.floor(Math.min(ax, bx, cx) - x0 - 0.5)), i1 = Math.min(nx - 1, Math.ceil(Math.max(ax, bx, cx) - x0 - 0.5))
  const j0 = Math.max(0, Math.floor(Math.min(ay, by, cy) - y0 - 0.5)), j1 = Math.min(ny - 1, Math.ceil(Math.max(ay, by, cy) - y0 - 0.5))
  for (let j = j0; j <= j1; j++)
    for (let i = i0; i <= i1; i++) {
      const px = x0 + i + 0.5, py = y0 + j + 0.5
      const l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d, l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
      if (l1 >= 0 && l2 >= 0 && l1 + l2 <= 1) put(j * nx + i, [l1, l2, 1 - l1 - l2])
    }
}

/** Share of the underside area (normal pointing down, near the floor) that is hole-fill sized triangles. */
function undersideFillShare(m: TriMesh): number {
  const p = m.positions
  let all = 0, fill = 0
  for (let t = 0; t < m.indices.length / 3; t++) {
    const [a, b, c] = [m.indices[t * 3] * 3, m.indices[t * 3 + 1] * 3, m.indices[t * 3 + 2] * 3]
    const u: V3 = [p[b] - p[a], p[b + 1] - p[a + 1], p[b + 2] - p[a + 2]], w: V3 = [p[c] - p[a], p[c + 1] - p[a + 1], p[c + 2] - p[a + 2]]
    const n = cross(u, w), len = Math.hypot(...n)
    if (len === 0 || n[2] / len > -0.5 || (p[a + 2] + p[b + 2] + p[c + 2]) / 3 > 15) continue
    const area = len / 2
    all += area
    if (Math.max(Math.hypot(...u), Math.hypot(...w), Math.hypot(p[c] - p[b], p[c + 1] - p[b + 1], p[c + 2] - p[b + 2])) > FILL_EDGE) fill += area
  }
  return all > 0 ? fill / all : 1
}

/** Insole outline from the silhouette of everything below SILHOUETTE_Z: rasterize, close the gaps between toes,
 *  take the outermost edge along rays from the centroid, smooth, offset outward, counter-clockwise. */
function silhouetteOutline(m: TriMesh, length: number): Point[] {
  const p = m.positions
  let xlo = Infinity, xhi = -Infinity
  for (let i = 0; i < p.length; i += 3) if (p[i + 2] < SILHOUETTE_Z) (xlo = Math.min(xlo, p[i]), xhi = Math.max(xhi, p[i]))
  const pad = 12
  const x0 = Math.floor(xlo) - pad, y0 = -pad, nx = Math.ceil(xhi - xlo) + 2 * pad, ny = Math.ceil(length) + 2 * pad + 12
  const mask = new Uint8Array(nx * ny)
  for (let i = 0; i < p.length; i += 3)
    if (p[i + 2] < SILHOUETTE_Z) mask[Math.floor(p[i + 1] - y0) * nx + Math.floor(p[i] - x0)] = 1
  for (let t = 0; t < m.indices.length / 3; t++) {
    const [a, b, c] = [m.indices[t * 3] * 3, m.indices[t * 3 + 1] * 3, m.indices[t * 3 + 2] * 3]
    if (Math.max(p[a + 2], p[b + 2], p[c + 2]) < SILHOUETTE_Z) fillTriangle(p, a, b, c, x0, y0, nx, ny, (i) => { mask[i] = 1 })
  }
  const closed = close(mask, nx, ny, 6)
  let cx = 0, cy = 0, k = 0
  for (let j = 0; j < ny; j++) for (let i = 0; i < nx; i++) if (closed[j * nx + i]) (cx += x0 + i + 0.5, cy += y0 + j + 0.5, k++)
  cx /= k; cy /= k
  const N = 720, STEP = 0.5
  let r = new Float64Array(N)
  for (let q = 0; q < N; q++) {
    const dx = Math.cos((2 * Math.PI * q) / N), dy = Math.sin((2 * Math.PI * q) / N)
    for (let d = 0; d < 400; d += STEP) {
      const i = Math.floor(cx + dx * d - x0), j = Math.floor(cy + dy * d - y0)
      if (i < 0 || j < 0 || i >= nx || j >= ny) break
      if (closed[j * nx + i]) r[q] = d
    }
  }
  // Circular Gaussian smoothing (sigma 3 degrees) trims the toes into one curve.
  const sigma = 6, smoothed = new Float64Array(N)
  for (let q = 0; q < N; q++) {
    let sum = 0, wsum = 0
    for (let o = -3 * sigma; o <= 3 * sigma; o++) {
      const w = Math.exp(-(o * o) / (2 * sigma * sigma))
      sum += w * r[(q + o + N * 4) % N]
      wsum += w
    }
    smoothed[q] = sum / wsum
  }
  r = smoothed
  return Array.from(r, (rad, q) => {
    const a = (2 * Math.PI * q) / N
    return { x: cx + (rad + OUTLINE_OFFSET) * Math.cos(a), y: cy + (rad + OUTLINE_OFFSET) * Math.sin(a) }
  })
}

/** Binary closing (dilate then erode by a square-ish disc of radius `rad` cells), then fills enclosed holes. */
function close(mask: Uint8Array, nx: number, ny: number, rad: number): Uint8Array {
  const pass = (src: Uint8Array, grow: boolean) => {
    // Separable box passes on a running count; a box is close enough to a disc for gap filling.
    const tmp = new Int32Array(nx * ny), out = new Uint8Array(nx * ny)
    for (let j = 0; j < ny; j++)
      for (let i = 0; i < nx; i++) {
        let s = 0
        for (let o = -rad; o <= rad; o++) s += i + o >= 0 && i + o < nx ? src[j * nx + i + o] : grow ? 0 : 1
        tmp[j * nx + i] = s
      }
    for (let j = 0; j < ny; j++)
      for (let i = 0; i < nx; i++) {
        let any = false, all = true
        for (let o = -rad; o <= rad; o++) {
          const jj = j + o
          const on = jj >= 0 && jj < ny ? tmp[jj * nx + i] > 0 : false
          const full = jj >= 0 && jj < ny ? tmp[jj * nx + i] === 2 * rad + 1 : !grow
          any ||= on
          all &&= full
        }
        out[j * nx + i] = grow ? +any : +all
      }
    return out
  }
  const closed = pass(pass(mask, true), false)
  // Flood the outside; anything not reached is inside.
  const outside = new Uint8Array(nx * ny)
  const stack: number[] = []
  const push = (i: number, j: number) => {
    if (i < 0 || j < 0 || i >= nx || j >= ny || outside[j * nx + i] || closed[j * nx + i]) return
    outside[j * nx + i] = 1
    stack.push(j * nx + i)
  }
  for (let i = 0; i < nx; i++) (push(i, 0), push(i, ny - 1))
  for (let j = 0; j < ny; j++) (push(0, j), push(nx - 1, j))
  while (stack.length) {
    const c = stack.pop()!, i = c % nx, j = (c - i) / nx
    push(i + 1, j); push(i - 1, j); push(i, j + 1); push(i, j - 1)
  }
  return outside.map((o) => 1 - o) as Uint8Array
}

// ---------- measurement ----------

/** Medial edge profile through the midfoot (40-55% of the length): per 1 mm row, the lowest vertex within 8 mm of the
 *  medial extreme, i.e. where the arch side wall meets the floor plane. Returns the median height and where it peaks. */
function medialProfile(m: TriMesh, length: number): { height: number; peakY: number } {
  const p = m.positions
  const rows = new Map<number, number[]>()
  for (let i = 0; i < p.length; i += 3) {
    const r = Math.round(p[i + 1])
    if (r >= 0.4 * length && r <= 0.55 * length) (rows.get(r) ?? rows.set(r, []).get(r)!).push(i)
  }
  const prof: [number, number][] = []
  for (const [r, idx] of rows) {
    let xmax = -Infinity
    for (const i of idx) xmax = Math.max(xmax, p[i])
    let h = Infinity
    for (const i of idx) if (p[i] > xmax - 8) h = Math.min(h, p[i + 2])
    prof.push([r, h])
  }
  prof.sort((a, b) => a[0] - b[0])
  const smooth = prof.map((_, k) => median(prof.slice(Math.max(0, k - 4), k + 5).map((q) => q[1])))
  let peak = 0
  smooth.forEach((h, k) => { if (h > smooth[peak]) peak = k })
  return { height: median(prof.map((q) => q[1])), peakY: prof[peak]?.[0] ?? 0.45 * length }
}

/** Orients a scan (any units, orientation, centering, either foot) into the canonical frame and measures it. Pass `side`
 *  when it is known (a bundled scan, or the user's pick) to skip the side call. Throws a plain-language Error when the
 *  file does not look like a foot. */
export function analyzeScan(soup: Float32Array, side?: ScanResult["side"]): ScanResult {
  if (soup.length < 9 * 500) throw new Error("This file has too little geometry to be a foot scan.")
  const unitScale = unitScaleFor(soup)
  const { v, f } = weld(soup, unitScale)
  // Files disagree on winding; make the normals point outward (positive signed volume) before using them.
  let volume = 0
  for (let t = 0; t < f.length; t += 3) {
    const [a, b, c] = [f[t] * 3, f[t + 1] * 3, f[t + 2] * 3]
    volume += dot([v[a], v[a + 1], v[a + 2]], cross([v[b], v[b + 1], v[b + 2]], [v[c], v[c + 1], v[c + 2]]))
  }
  if (volume < 0) for (let t = 0; t < f.length; t += 3) [f[t + 1], f[t + 2]] = [f[t + 2], f[t + 1]]
  const up = refineUp(v, findUp(v, f))
  const o = orient(v, up, side)
  const n = v.length / 3
  const positions = new Float32Array(n * 3)
  for (let i = 0; i < n; i++) positions.set([o.x[i], o.y[i], o.z[i]], i * 3)
  const indices = f.slice()
  if (o.mirrored) for (let t = 0; t < indices.length; t += 3) [indices[t + 1], indices[t + 2]] = [indices[t + 2], indices[t + 1]]
  const mesh: TriMesh = { positions, indices }

  let ymin = Infinity, ymax = -Infinity
  for (let i = 0; i < n; i++) if (o.z[i] < FOOT_Z) (ymin = Math.min(ymin, o.y[i]), ymax = Math.max(ymax, o.y[i]))
  const length = ymax - ymin
  if (!(length > 120 && length < 400)) throw new Error("This does not look like a single foot. Scan one foot, with a little ankle.")
  const ball = widthIn(o.y, o.x, o.z, length, 0.6, 0.78), heel = widthIn(o.y, o.x, o.z, length, 0.08, 0.2)
  let dorsum = 0
  for (let i = 0; i < n; i++) if (Math.abs(o.y[i] - 0.5 * length) < 3) dorsum = Math.max(dorsum, o.z[i])
  const trunc = TRUNC_FRAC * length
  const ahi = dorsum / trunc
  const profile = medialProfile(mesh, length)

  const fillShare = undersideFillShare(mesh)
  const soleObserved = fillShare < FILL_SHARE_LIMIT
  let xlo = Infinity, xhi = -Infinity
  for (let i = 0; i < n; i++) if (o.z[i] < FOOT_Z) (xlo = Math.min(xlo, o.x[i]), xhi = Math.max(xhi, o.x[i]))
  const x0 = Math.floor(xlo) - 2, nx = Math.ceil(xhi - xlo) + 5, ny = Math.ceil(length) + 5, y0 = Math.floor(ymin) - 2
  const under = undersideHeights(mesh, { x0, y0, nx, ny })
  const contact = Float32Array.from(under.data, (h) => (h < CONTACT_MM ? 1 : 0))
  const footprint = computeIndices({ nx, ny, cell: 1, x0, y0, mask: new Uint8Array(0) }, contact)

  return {
    mesh, side: o.side, sideSure: o.sideSure, unitScale, toCanonical: fitAffine(v, positions, unitScale), length, ballWidth: ball, heelWidth: heel, truncLength: trunc, dorsumHeight: dorsum, ahi,
    ahiClass: ahi <= AHI_LOWER ? "lower" : ahi >= AHI_HIGHER ? "higher" : "typical",
    medialArchHeight: profile.height, medialArchY: profile.peakY, soleObserved, fillShare, footprint,
    outline: silhouetteOutline(mesh, length), checks: o.checks,
  }
}
