import {
  AmbientLight, BufferAttribute, BufferGeometry, Color, DataTexture, DirectionalLight, InstancedMesh, Line, LineBasicMaterial,
  LinearFilter, Matrix4, Mesh, MeshBasicMaterial, MeshStandardMaterial, PerspectiveCamera, RGBAFormat, Scene,
  SphereGeometry, SRGBColorSpace, Vector3, UnsignedByteType, WebGLRenderer, type Texture,
} from "three"
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js"
import { createHeatmapImage, paintHeatmap, type ColormapName, type HeatmapImage } from "../core/colormap"
import type { InsoleMesh } from "../core/insole"
import { sampleGrid, type Grid } from "../core/pressure"
import type { FootPose } from "../core/gait"
import type { Point } from "../core/types"
import { FootModel } from "./foot"

/** Camera framing box: center and bounding radius of insole plus posed foot, mm. */
export interface Frame {
  center: readonly [number, number, number]
  radius: number
}
const GENERIC_FRAME: Frame = { center: [7, 111, 45], radius: Math.hypot(101, 258, 100) / 2 }

const TERRAIN_MM = 18 // displacement at full-scale pressure

export interface FieldStyle {
  map: Float32Array
  vmax: number
  colormap: ColormapName
  patterns: boolean
  diverging: boolean
  terrain: boolean
}

/** three.js scene for the insole: heatmap texture, optional pressure terrain, sensor points and CoP trail.
 *  Renders only when `render()` is called; `onChange` fires when the camera moves so the host can schedule a frame. */
export class InsoleScene {
  private renderer: WebGLRenderer
  private camera = new PerspectiveCamera(35, 1, 10, 3000)
  private scene = new Scene()
  readonly controls: OrbitControls
  private mesh: Mesh | null = null
  private mesh0: InsoleMesh | null = null
  private baseZ = new Float32Array(0)
  private grid: Grid | null = null
  private img: HeatmapImage | null = null
  private texture: DataTexture | null = null
  private material = new MeshStandardMaterial({ roughness: 0.8, metalness: 0 })
  private sensorMesh = new InstancedMesh(new SphereGeometry(1.2, 10, 8), new MeshBasicMaterial({ color: 0xffffff }), 48)
  private sensors: readonly Point[] = []
  private trail = new Line(new BufferGeometry(), new LineBasicMaterial({ color: 0xffffff }))
  private marker = new Mesh(new SphereGeometry(3, 12, 8), new MeshBasicMaterial({ color: 0xffffff }))
  private tmp = new Matrix4()

  constructor(canvas: HTMLCanvasElement, onChange: () => void) {
    this.renderer = new WebGLRenderer({ canvas, antialias: true })
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
        this.camera.up.set(0, 0, 1)
    this.camera.position.set(170, -190, 330)
    this.controls = new OrbitControls(this.camera, canvas)
    this.controls.target.set(0, 105, 35)
    this.controls.enableDamping = true
    this.controls.addEventListener("change", onChange)
    this.controls.update()
    this.scene.add(new AmbientLight(0xffffff, 1.1))
    const sun = new DirectionalLight(0xffffff, 1.6)
    sun.position.set(-150, -100, 300)
    this.scene.add(sun, this.sensorMesh, this.trail, this.marker)
    this.trail.frustumCulled = false
    this.sensorMesh.frustumCulled = false
    this.material.emissive.set(0xffffff)
    this.material.emissiveIntensity = 0.4
  }

  /** Matches the scene to the page: clear color is the CSS background (`bg`, a CSS color), materials follow light or dark. */
  setTheme(bg: string, dark: boolean): void {
    this.dark = dark
    this.emptyColor = dark ? [32, 30, 24] : [176, 175, 168]
    this.renderer.setClearColor(new Color(bg), 1)
    const ink = dark ? 0xffffff : 0x26251e
    ;(this.sensorMesh.material as MeshBasicMaterial).color.set(ink)
    ;(this.trail.material as LineBasicMaterial).color.set(ink)
    this.marker.material.color.set(ink)
    this.plainMaterial.color.set(dark ? 0xc9c6bd : 0xa9a597)
    this.baseMaterial.color.set(dark ? 0x3a372f : 0x8d897c)
    this.material.emissiveIntensity = 0.4
    this.foot?.setTone(dark)
  }

  /** Resizes the drawing buffer to the canvas' CSS size. */
  resize(): void {
    const c = this.renderer.domElement
    // Hidden canvases report 0x0; fitting the camera then would push it to infinity for good.
    if (!c.clientWidth || !c.clientHeight) return
    this.renderer.setSize(c.clientWidth, c.clientHeight, false)
    this.camera.aspect = c.clientWidth / Math.max(1, c.clientHeight)
    this.camera.updateProjectionMatrix()
    this.fitCamera()
  }

  /** Camera preset along a fixed direction (`?cam=` deep link): 3/4, straight down, or from the medial side. */
  setView(view: "3d" | "top" | "side"): void {
    const dir = view === "top" ? new Vector3(0, -0.001, 1) : view === "side" ? new Vector3(1, 0, 0.02) : new Vector3(163, -301, 285)
    this.camera.position.copy(this.controls.target).addScaledVector(dir.normalize(), 1)
    this.fitCamera()
  }

  private frame = GENERIC_FRAME
  /** Frames the camera on a different box (own scan); null returns to the generic insole. */
  setFrame(frame: Frame | null): void {
    this.frame = frame ?? GENERIC_FRAME
    this.fitCamera()
  }

  /** Frames insole plus the posed foot (box in mm, heel/toe lift included) with margin, keeping the current view direction. */
  fitCamera(): void {
    const center = new Vector3(...this.frame.center), radius = this.frame.radius
    const vHalf = (this.camera.fov * Math.PI) / 360
    const hHalf = Math.atan(Math.tan(vHalf) * this.camera.aspect)
    const dist = (radius * 0.95) / Math.sin(Math.min(vHalf, hHalf))
    const dir = this.camera.position.clone().sub(this.controls.target).normalize()
    if (!Number.isFinite(dir.x + dir.y + dir.z) || dir.lengthSq() === 0) dir.set(163, -301, 285).normalize() // initial camera position minus center
    this.controls.target.copy(center)
    this.camera.position.copy(center).addScaledVector(dir, dist)
    this.controls.update()
  }

  /** Replaces the insole geometry. */
  setInsole(insole: InsoleMesh, grid: Grid, sensors: readonly Point[]): void {
    if (this.mesh) {
      this.scene.remove(this.mesh)
      this.mesh.geometry.dispose()
    }
    this.mesh0 = insole
    this.foot?.seat(insole.heightAt)
    this.grid = grid
    this.sensors = sensors
    this.img = createHeatmapImage(grid)
    this.texture?.dispose()
    this.texture = new DataTexture(new Uint8Array(this.img.data.buffer), this.img.width, this.img.height, RGBAFormat, UnsignedByteType)
    this.texture.colorSpace = SRGBColorSpace
    this.texture.magFilter = this.texture.minFilter = LinearFilter
    this.texture.generateMipmaps = false
    this.material.map = this.material.emissiveMap = this.texture
    this.material.needsUpdate = true

    const geo = new BufferGeometry()
    geo.setAttribute("position", new BufferAttribute(insole.positions.slice(), 3))
    const uv = new Float32Array(insole.topCount * 2 * 2)
    const w = grid.nx * grid.cell, h = grid.ny * grid.cell
    for (let i = 0; i < insole.topCount; i++) {
      const x = insole.topXY[i * 2], y = insole.topXY[i * 2 + 1]
      uv.set([(x - grid.x0) / w, (y - grid.y0) / h], i * 2)
      uv.set([(x - grid.x0) / w, (y - grid.y0) / h], (insole.topCount + i) * 2)
    }
    geo.setAttribute("uv", new BufferAttribute(uv, 2))
    geo.setIndex(new BufferAttribute(insole.indices, 1))
    geo.addGroup(0, insole.topTriangles * 3, 0)
    geo.addGroup(insole.topTriangles * 3, insole.indices.length - insole.topTriangles * 3, 1)
    geo.computeVertexNormals()
    this.baseZ = new Float32Array(insole.topCount)
    for (let i = 0; i < insole.topCount; i++) this.baseZ[i] = insole.positions[i * 3 + 2]
    this.mesh = new Mesh(geo, [this.plain ? this.plainMaterial : this.material, this.baseMaterial])
    this.scene.add(this.mesh)
  }

  /** Repaints the heatmap texture and (in terrain mode) displaces the surface. */
  setField(f: FieldStyle): void {
    if (!this.mesh || !this.mesh0 || !this.grid || !this.img || !this.texture) return
    paintHeatmap(this.img, this.grid, f.map, f.vmax, f.colormap, f.patterns, f.diverging, this.emptyColor)
    this.texture.needsUpdate = true
    const pos = this.mesh.geometry.getAttribute("position") as BufferAttribute
    const amp = f.diverging ? TERRAIN_MM / 2 : TERRAIN_MM
    for (let i = 0; i < this.mesh0.topCount; i++) {
      const d = f.terrain ? (sampleGrid(this.grid, f.map, this.mesh0.topXY[i * 2], this.mesh0.topXY[i * 2 + 1]) / f.vmax) * amp * this.mesh0.rimFade[i] : 0
      pos.setZ(i, Math.max(0.5, this.baseZ[i] + d))
    }
    pos.needsUpdate = true
    if (f.terrain || this.terrainWas) this.mesh.geometry.computeVertexNormals()
    this.terrainWas = f.terrain
    this.lift = (x, y) => (f.terrain ? (sampleGrid(this.grid!, f.map, x, y) / f.vmax) * amp : 0)
  }
  private terrainWas = false
  private lift: (x: number, y: number) => number = () => 0

  private foot: FootModel | null = null
  private footCache = new Map<string, Promise<FootModel>>()
  private footRequest = 0
  private footVisible = true
  private plainMaterial = new MeshStandardMaterial({ color: 0xc9ccd1, roughness: 0.8 })
  private baseMaterial = new MeshStandardMaterial({ color: 0x3a3a3a, roughness: 0.9 })
  private dark = true
  private emptyColor: readonly [number, number, number] = [32, 30, 24]
  private plain = false

  /** Shows the scanned foot model at `url` (loads once per url, then swaps instantly). A later setFoot or setScanFoot
   *  wins over a load that is still in flight. */
  async setFoot(url: string): Promise<void> {
    const request = ++this.footRequest
    let p = this.footCache.get(url)
    if (!p) this.footCache.set(url, (p = FootModel.load(url)))
    const next = await p
    if (request === this.footRequest) this.useFoot(next)
  }

  /** Shows the user's own scan (canonical frame) instead of a bundled foot; with `real`, its textured version instead. */
  setScanFoot(positions: Float32Array, indices: Uint32Array, real?: { geo: BufferGeometry; map: Texture }): void {
    this.footRequest++
    this.useFoot(real ? FootModel.fromTextured(real.geo.clone(), real.map) : FootModel.fromScan(positions, indices))
  }

  private useFoot(next: FootModel): void {
    if (this.foot === next) return
    if (this.foot) this.scene.remove(this.foot.mesh)
    this.foot = next
    next.setTone(this.dark)
    if (this.mesh0) next.seat(this.mesh0.heightAt)
    next.pose(this.footPose)
    next.mesh.visible = this.footVisible
    this.scene.add(next.mesh)
    this.fitCamera()
  }

  setFootVisible(on: boolean): void {
    this.footVisible = on
    if (this.foot) this.foot.mesh.visible = on
  }

  private footPose: FootPose = { pitch: 0, pivot: 0, lift: 0 }
  setFootPose(p: FootPose): void {
    this.footPose = p
    this.foot?.pose(p)
  }

  /** Insole without heatmap (the "Your insole" view). */
  setPlain(on: boolean): void {
    this.plain = on
    if (this.mesh) (this.mesh.material as MeshStandardMaterial[])[0] = on ? this.plainMaterial : this.material
  }

  /** Sensor spheres on/off; positions follow the surface. */
  setSensorsVisible(on: boolean): void {
    this.sensorMesh.visible = on
    if (!on || !this.mesh0) return
    this.sensors.forEach((s, i) => {
      this.tmp.makeTranslation(s.x, s.y, this.mesh0!.heightAt(s.x, s.y) + this.lift(s.x, s.y) + 1.5)
      this.sensorMesh.setMatrixAt(i, this.tmp)
    })
    this.sensorMesh.count = this.sensors.length
    this.sensorMesh.instanceMatrix.needsUpdate = true
  }

  /** CoP trail up to `upTo` frames (cop = [x, y, ...], NaN = no load) and a marker at the latest point. */
  setCop(cop: Float32Array, upTo: number, visible: boolean): void {
    this.trail.visible = this.marker.visible = visible
    if (!visible || !this.mesh0) return
    const pts: number[] = []
    let last: [number, number] | null = null
    for (let f = 0; f < upTo; f++) {
      const x = cop[f * 2], y = cop[f * 2 + 1]
      if (Number.isNaN(x)) continue
      pts.push(x, y, this.mesh0.heightAt(x, y) + this.lift(x, y) + 2)
      last = [x, y]
    }
    this.trail.geometry.setAttribute("position", new BufferAttribute(new Float32Array(pts), 3))
    this.marker.visible = last !== null
    if (last) this.marker.position.set(last[0], last[1], this.mesh0.heightAt(...last) + this.lift(...last) + 2)
  }

  /** Orbits the camera around the target by (dAzimuth, dPolar) radians, or zooms by `zoom` (>1 = farther). */
  nudge(dAzimuth: number, dPolar: number, zoom = 1): void {
    const off = this.camera.position.clone().sub(this.controls.target)
    const r = off.length() * zoom
    let polar = Math.acos(off.z / off.length()) + dPolar
    polar = Math.min(Math.PI - 0.05, Math.max(0.05, polar))
    const az = Math.atan2(off.y, off.x) + dAzimuth
    this.camera.position.set(
      this.controls.target.x + r * Math.sin(polar) * Math.cos(az),
      this.controls.target.y + r * Math.sin(polar) * Math.sin(az),
      this.controls.target.z + r * Math.cos(polar),
    )
    this.controls.update()
  }

  /** Draws one frame. Returns true while camera damping still needs more frames. */
  render(): boolean {
    const moving = this.controls.update()
    this.renderer.render(this.scene, this.camera)
    return moving
  }
}
