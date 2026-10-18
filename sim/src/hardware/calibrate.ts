/** Rough raw ADC -> kPa conversion for an FSR in a divider (FSR from supply to pin, 10k from pin to GND):
 *    adc/adcMax = R / (R + Rfsr)    =>   Rfsr = R * (adcMax / adc - 1)
 *  FSR402 datasheet curve is roughly linear in conductance: ~100 uS per newton (10k at 1 N, 1k at 10 N).
 *  Force over the 12.7 mm disc (127 mm^2) gives ~7.9 kPa per newton at the sensor face.
 *  Accuracy is poor (+-30% or worse, drifts with bending and temperature): use for relative patterns only. */
export const DIVIDER_OHMS = 10_000
const US_PER_NEWTON = 100
const DEFAULT_AREA_MM2 = 127
/** Readings above this are clipped (FSR saturates around 10 N). */
const MAX_KPA = 1000
/** kPa that a sensor's own max maps to when max-normalization is on. */
const NORMALIZED_KPA = 300

/** Converts one raw ADC reading to approximate kPa (0 for open circuit). */
export function adcToKPa(adc: number, adcMax: number, areaMm2 = DEFAULT_AREA_MM2): number {
  if (adc <= 0) return 0
  const rFsr = DIVIDER_OHMS * (adcMax / Math.min(adc, adcMax) - 1)
  if (rFsr <= 0) return MAX_KPA
  const newtons = 1e6 / rFsr / US_PER_NEWTON
  return Math.min(MAX_KPA, (newtons / areaMm2) * 1000)
}

/** Stateful converter for one device: zero-offset (tare) and optional per-sensor max normalization. */
export interface Calibrator {
  /** Raw ADC frame -> kPa (after baseline subtraction and optional normalization). */
  convert(raw: ArrayLike<number>): Float32Array
  /** Averages the next `frames` raw frames as the unloaded baseline (foot off the sensors). */
  tare(frames?: number): void
  /** Starts a fresh per-sensor max capture (stand on each sensor/foot), applied while `normalize` is on. */
  resetMax(): void
  normalize: boolean
  /** Full-scale ADC count (1023 on 10-bit boards, 4095 on 12-bit). Safe to change live: tare and peaks are kept in raw counts. */
  adcMax: number
}

export function createCalibrator(adcMax: number, count: number): Calibrator {
  let baseline = new Float32Array(count)
  /** Per-sensor max of raw counts above the baseline. */
  let peaks = new Float32Array(count)
  let tareLeft = 0
  let tareSum = new Float64Array(count)
  let tareTotal = 0

  const cal: Calibrator = {
    adcMax,
    normalize: false,
    tare(frames = 25) {
      tareLeft = tareTotal = frames
      tareSum = new Float64Array(count)
    },
    resetMax() {
      peaks = new Float32Array(count)
    },
    convert(raw) {
      if (tareLeft > 0) {
        for (let i = 0; i < count; i++) tareSum[i] += raw[i]
        if (--tareLeft === 0) baseline = Float32Array.from(tareSum, (s) => s / tareTotal)
      }
      const out = new Float32Array(count)
      for (let i = 0; i < count; i++) {
        const counts = Math.max(0, raw[i] - baseline[i])
        if (counts > peaks[i]) peaks[i] = counts
        const kPa = adcToKPa(counts, cal.adcMax)
        out[i] = cal.normalize && peaks[i] > 0 ? (kPa / adcToKPa(peaks[i], cal.adcMax)) * NORMALIZED_KPA : kPa
      }
      return out
    },
  }
  return cal
}
