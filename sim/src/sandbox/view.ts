import {
  AmbientLight, BoxGeometry, BufferAttribute, BufferGeometry, CatmullRomCurve3, CylinderGeometry, DataTexture, DirectionalLight,
  InstancedMesh, LinearFilter, Matrix4, Mesh, MeshBasicMaterial, MeshStandardMaterial, PerspectiveCamera, Raycaster,
  Box3, Color, RGBAFormat, RingGeometry, Scene, Group, SRGBColorSpace, TubeGeometry, UnsignedByteType, Vector2, Vector3, WebGLRenderer,
  type Material,
} from "three"
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js"
import { createHeatmapImage, paintHeatmap, type ColormapName, type HeatmapImage } from "../core/colormap"
import type { FootPose } from "../core/gait"
import { buildInsole, type InsoleMesh } from "../core/insole"
import type { Grid } from "../core/pressure"
import type { Point } from "../core/types"
import { FootModel } from "../view/foot"

/** Accent for the selected / hinted sensor (cursor.com orange). */
const ACCENT = "#E5532D"
const WIRE_RADIUS = 0.6

const BOARD_CENTER = new Vector3(3, -52, 0)
const BOARD_LENGTH = 45, BOARD_WIDTH = 18, PCB = 1.6, HEADER = 2.5, PIN_TIP = 5.5
const PIN_PITCH = 2.54
const FOOT_ROLL_RAD = 0.14 // foot tilt at full roll
const Z = new Vector3(0, 0, 1)

export interface SensorVis extends Point {
  /** Orange ring: this is the sensor the current hint is about. */
  hinted: boolean
}

/** Where wire `index` meets the board header (the row facing the insole). */
function pinPosition(index: number): Vector3 {
  const k = index % 15
  return new Vector3(BOARD_CENTER.x - 7 * PIN_PITCH + k * PIN_PITCH, BOARD_CENTER.y + BOARD_WIDTH / 2 - PIN_PITCH / 2, PIN_TIP)
}

/** three.js scene of the sandbox: insole with heatmap, FSR discs, wires, Arduino Nano model, optional scanned foot, press marker.
 *  Renders on demand: call `render()`; it returns true while camera damping needs more frames. */
export class SandboxScene {
  readonly controls: OrbitControls
  private renderer: WebGLRenderer
  private camera = new PerspectiveCamera(35, 1, 10, 3000)
  private scene = new Scene()
  private insole: InsoleMesh
  private insoleMesh: Mesh
  private img: HeatmapImage
  private tex: DataTexture
  private discs = new Group()
  private wires = new Group()
  private pcb = new MeshStandardMaterial({ color: 0x124a63, roughness: 0.6 })
  private marker = new Group()
  private foot: FootModel | null = null
  private footCache = new Map<string, Promise<FootModel>>()
  private footRequest = 0
  private footVisible = true
  private footRoll = 0
  private raycaster = new Raycaster()
  private shared = {
    base: new CylinderGeometry(9.15, 9.15, 0.5, 32).rotateX(Math.PI / 2),
    pad: new CylinderGeometry(6.35, 6.35, 0.2, 32).rotateX(Math.PI / 2),
    rim: new RingGeometry(5.3, 6.35, 40),
    halo: new RingGeometry(10.5, 12, 40),
    handle: new RingGeometry(12.6, 13.4, 40),
  }
  private baseMat = new MeshStandardMaterial({ color: 0x1c1c1c, roughness: 0.7 })
  private padMat = new MeshStandardMaterial({ color: 0x3b3b3b, roughness: 0.5 })
  /** Rings and handles sit on the dark insole in both themes, so they stay light. */
  private inkMat = new MeshBasicMaterial({ color: 0xf2f1ed })
  private handleMat = new MeshBasicMaterial({ color: 0xf2f1ed, transparent: true, opacity: 0.4, depthWrite: false })
  private accentMat = new MeshBasicMaterial({ color: ACCENT })
  private wireMat = new MeshBasicMaterial({ color: 0xffffff })
  private ink = new Color(0xffffff)

  constructor(private canvas: HTMLCanvasElement, grid: Grid, private outline: readonly Point[], onChange: () => void) {
    this.renderer = new WebGLRenderer({ canvas, antialias: true })
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
    this.camera.up.set(0, 0, 1)
    this.setTheme("#000000", "#ffffff")
    this.controls = new OrbitControls(this.camera, canvas)
    this.controls.enableDamping = true
    this.controls.addEventListener("change", onChange)
    this.setCamera("3d")

    this.scene.add(new AmbientLight(0xffffff, 1.1))
    const sun = new DirectionalLight(0xffffff, 1.6)
    sun.position.set(-150, -100, 300)
    this.scene.add(sun, this.discs, this.wires, this.buildBoard(), this.marker)

    // Insole shell with the heatmap texture on its top face.
    this.insole = buildInsole(outline, grid, new Float32Array(grid.nx * grid.ny), null)
    this.img = createHeatmapImage(grid)
    this.tex = new DataTexture(new Uint8Array(this.img.data.buffer), this.img.width, this.img.height, RGBAFormat, UnsignedByteType)
    this.tex.colorSpace = SRGBColorSpace
    this.tex.magFilter = this.tex.minFilter = LinearFilter
    this.tex.generateMipmaps = false
    const top = new MeshStandardMaterial({ roughness: 0.8, metalness: 0, map: this.tex, emissiveMap: this.tex, emissive: 0xffffff, emissiveIntensity: 0.4 })
    const geo = new BufferGeometry()
    const ins = this.insole
    geo.setAttribute("position", new BufferAttribute(ins.positions.slice(), 3))
    const uv = new Float32Array(ins.topCount * 4)
    const w = grid.nx * grid.cell, h = grid.ny * grid.cell
    for (let i = 0; i < ins.topCount; i++) {
      const u = (ins.topXY[i * 2] - grid.x0) / w, v = (ins.topXY[i * 2 + 1] - grid.y0) / h
      uv.set([u, v], i * 2)
      uv.set([u, v], (ins.topCount + i) * 2)
    }
    geo.setAttribute("uv", new BufferAttribute(uv, 2))
    geo.setIndex(new BufferAttribute(ins.indices, 1))
    geo.addGroup(0, ins.topTriangles * 3, 0)
    geo.addGroup(ins.topTriangles * 3, ins.indices.length - ins.topTriangles * 3, 1)
    geo.computeVertexNormals()
    this.insoleMesh = new Mesh(geo, [top, new MeshStandardMaterial({ color: 0x3a3a3a, roughness: 0.9 })])
    this.scene.add(this.insoleMesh)

    // Press marker: ring on the surface plus a thin stem.
    const ringMat = new MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.9 })
    this.marker.add(new Mesh(new RingGeometry(0.88, 1, 48), ringMat), new Mesh(new CylinderGeometry(0.6, 0.6, 24, 8).rotateX(Math.PI / 2).translate(0, 0, 12), ringMat))
    this.marker.visible = false
    this.marker.renderOrder = 5
  }

  /** Arduino Nano-like board (PCB, USB port, chip, two header rows) at the heel end of the insole. */
  private buildBoard(): Group {
    const g = new Group()
    g.position.copy(BOARD_CENTER)
    const box = (w: number, d: number, h: number, mat: Material, x: number, y: number, z: number) => {
      const m = new Mesh(new BoxGeometry(w, d, h), mat)
      m.position.set(x, y, z)
      g.add(m)
    }
    box(BOARD_LENGTH, BOARD_WIDTH, PCB, this.pcb, 0, 0, PCB / 2)
    box(9, 7.6, 3, new MeshStandardMaterial({ color: 0xb8b8b8, metalness: 0.6, roughness: 0.4 }), -BOARD_LENGTH / 2 + 2, 0, PCB + 1.5)
    box(8, 8, 1.2, new MeshStandardMaterial({ color: 0x111111, roughness: 0.5 }), 5, 0, PCB + 0.6)
    const plastic = new MeshStandardMaterial({ color: 0x151515, roughness: 0.6 })
    const gold = new MeshStandardMaterial({ color: 0xd4af37, metalness: 0.8, roughness: 0.35 })
    const pins = new InstancedMesh(new BoxGeometry(0.64, 0.64, PIN_TIP - PCB), gold, 30)
    const m = new Matrix4()
    let n = 0
    for (const side of [-1, 1]) {
      const y = side * (BOARD_WIDTH / 2 - PIN_PITCH / 2)
      box(15 * PIN_PITCH, PIN_PITCH, HEADER, plastic, 0, y, PCB + HEADER / 2)
      for (let k = 0; k < 15; k++) {
        m.makeTranslation(-7 * PIN_PITCH + k * PIN_PITCH, y, PCB + (PIN_TIP - PCB) / 2)
        pins.setMatrixAt(n++, m)
      }
    }
    g.add(pins)
    return g
  }

  /** Page colors (from the CSS tokens): canvas background, and ink for the wires. */
  setTheme(bg: string, fg: string): void {
    this.renderer.setClearColor(new Color(bg), 1)
    this.ink.set(fg)
    this.wireMat.color.copy(this.ink).lerp(new Color(bg), 0.4)
    this.styleFoot()
  }

  /** Pale glass: the insole is dark on both page themes, so the foot reads as light on it. */
  private styleFoot(): void {
    if (!this.foot) return
    const m = this.foot.mesh.material as MeshStandardMaterial
    m.color.set(0xf4f1ea)
    m.emissive.set(0xf4f1ea)
    m.emissiveIntensity = 0.4
    this.foot.opacity = 0.45
  }

  setBoard(isEsp: boolean): void {
    this.pcb.color.set(isEsp ? 0x1d1d1d : 0x124a63)
  }

  /** Board center on screen for its label. */
  boardAnchor(): Vector3 {
    return new Vector3(BOARD_CENTER.x + 6, BOARD_CENTER.y - 14, 0)
  }

  resize(): void {
    const c = this.canvas
    this.renderer.setSize(c.clientWidth, c.clientHeight, false)
    this.camera.aspect = c.clientWidth / Math.max(1, c.clientHeight)
    this.camera.updateProjectionMatrix()
    this.fit()
  }

  /** Sets the viewing direction ("3d" or straight down) and fits everything in view. */
  setCamera(view: "3d" | "top" | "side"): void {
    this.viewDir.copy(view === "top" ? new Vector3(0, -0.02, 1) : view === "side" ? new Vector3(1, 0, 0.02) : new Vector3(170, -40, 420)).normalize()
    this.fit(false)
  }

  /** Moves the camera back along the current viewing direction until the bounding box of insole, foot and board
   *  (with a margin) is fully inside the canvas. Call on resize and when the foot model changes. */
  fit(keepDirection = true): void {
    if (keepDirection && this.controls.target.lengthSq() > 0) this.viewDir.copy(this.camera.position).sub(this.controls.target).normalize()
    const box = new Box3(new Vector3(-48, -64, 0), new Vector3(62, 245, 70))
    const center = box.getCenter(new Vector3())
    this.controls.target.copy(center)
    const corners = [0, 1].flatMap((i) => [0, 1].flatMap((j) => [0, 1].map((k) => new Vector3(i ? box.max.x : box.min.x, j ? box.max.y : box.min.y, k ? box.max.z : box.min.z))))
    let dist = 150
    for (let n = 0; n < 80; n++, dist *= 1.04) {
      this.camera.position.copy(center).addScaledVector(this.viewDir, dist)
      this.camera.lookAt(center)
      this.camera.updateMatrixWorld(true)
      // keep clear of the segmented control on top and the legend below
      if (corners.every((c) => { const v = c.clone().project(this.camera); return Math.abs(v.x) < 0.94 && v.y < 0.8 && v.y > -0.85 })) break
    }
    this.camera.far = Math.max(3000, dist * 3)
    this.camera.updateProjectionMatrix()
    this.controls.update()
  }
  private viewDir = new Vector3(170, -40, 420).normalize()

  /** Surface height of the insole at (x, y), mm. */
  heightAt(x: number, y: number): number {
    return this.insole.heightAt(x, y)
  }

  /** Repaints the insole heatmap texture. */
  paint(grid: Grid, map: Float32Array, vmax: number, cmap: ColormapName): void {
    paintHeatmap(this.img, grid, map, vmax, cmap, false)
    this.tex.needsUpdate = true
  }

  /** Screen position (CSS px within the canvas) of a world point, or null when behind the camera. */
  screenOf(p: Vector3): { x: number; y: number } | null {
    const v = p.clone().project(this.camera)
    if (v.z > 1) return null
    return { x: ((v.x + 1) / 2) * this.canvas.clientWidth, y: ((1 - v.y) / 2) * this.canvas.clientHeight }
  }

  /** World position on top of the insole for an (x, y) in the foot frame. */
  surfacePoint(x: number, y: number, lift = 0): Vector3 {
    return new Vector3(x, y, this.insole.heightAt(x, y) + lift)
  }

  /** Foot-frame point under a pointer, or null when the pointer is not over the insole. */
  pickInsole(clientX: number, clientY: number): Point | null {
    const r = this.canvas.getBoundingClientRect()
    this.raycaster.setFromCamera(new Vector2(((clientX - r.left) / r.width) * 2 - 1, -((clientY - r.top) / r.height) * 2 + 1), this.camera)
    const hit = this.raycaster.intersectObject(this.insoleMesh)[0]
    return hit && hit.point.z > 0.4 ? { x: hit.point.x, y: hit.point.y } : null
  }

  /** Discs lying on the insole (tilted to the surface), each with a faint grab handle ring. The selected one gets an ink
   *  halo, the hinted one an orange one. Wires are rebuilt to match. */
  setSensors(list: readonly SensorVis[], selected: number | null): void {
    this.discs.clear()
    list.forEach((s, i) => {
      const g = new Group()
      const hx = this.insole.heightAt(s.x + 2, s.y) - this.insole.heightAt(s.x - 2, s.y)
      const hy = this.insole.heightAt(s.x, s.y + 2) - this.insole.heightAt(s.x, s.y - 2)
      g.quaternion.setFromUnitVectors(Z, new Vector3(-hx / 4, -hy / 4, 1).normalize())
      g.position.copy(this.surfacePoint(s.x, s.y, 0.2))
      const base = new Mesh(this.shared.base, this.baseMat)
      base.position.z = 0.25
      const pad = new Mesh(this.shared.pad, this.padMat)
      pad.position.z = 0.6
      const ring = new Mesh(this.shared.rim, s.hinted ? this.accentMat : this.inkMat)
      ring.position.z = 0.75
      const handle = new Mesh(this.shared.handle, s.hinted ? this.accentMat : this.handleMat)
      handle.position.z = 0.4
      g.add(base, pad, ring, handle)
      if (i === selected || s.hinted) {
        const halo = new Mesh(this.shared.halo, s.hinted ? this.accentMat : this.inkMat)
        halo.position.z = 0.4
        g.add(halo)
      }
      this.discs.add(g)
    })
    this.rebuildWires(list)
  }

  /** Lateral (outer) edge of the insole at height y. */
  private lateralEdgeX(y: number): number {
    const o = this.outline
    y = Math.max(-12, y) // below the heel the lane just continues straight
    let best = Infinity
    for (let i = 0; i < o.length; i++) {
      const a = o[i], b = o[(i + 1) % o.length]
      if (a.y > y !== b.y > y) best = Math.min(best, a.x + ((y - a.y) / (b.y - a.y)) * (b.x - a.x))
    }
    return best
  }

  /** One bundle of wires: each leaves its sensor straight out to the outer edge, drops to the floor and runs down a
   *  parallel lane beside the insole to the board. Lanes are ordered by sensor height (toes outermost) so no wire
   *  crosses another; header pins are assigned in lane order for the same reason (visual only). */
  private rebuildWires(list: readonly SensorVis[]): void {
    for (const c of this.wires.children) (c as Mesh).geometry.dispose()
    this.wires.clear()
    const LANE = 1.9, GAP = 5, BOTTOM = -24
    const order = list.map((_, i) => i).sort((a, b) => list[b].y - list[a].y) // outermost lane first
    order.forEach((i, rank) => {
      const s = list[i]
      const pin = pinPosition(rank)
      const pts: Vector3[] = [new Vector3(s.x, s.y, this.insole.heightAt(s.x, s.y) + 0.6)]
      const edge = this.lateralEdgeX(s.y)
      // Stub across the insole surface to the edge.
      for (let k = 1; k <= 6; k++) {
        const x = s.x + ((edge + 1 - s.x) * k) / 6
        pts.push(new Vector3(x, s.y, this.insole.heightAt(x, s.y) + 0.6))
      }
      // Trunk lane on the floor, following the outer edge down toward the heel.
      for (let y = s.y; y > BOTTOM; y -= 12) pts.push(new Vector3(this.lateralEdgeX(y) - GAP - rank * LANE, y, 0.9))
      pts.push(new Vector3(this.lateralEdgeX(BOTTOM) - GAP - rank * LANE + 4, BOTTOM - 8, 0.9))
      pts.push(new Vector3((pin.x + pts[pts.length - 1].x) / 2, pin.y - 2, 3))
      pts.push(pin)
      this.wires.add(new Mesh(new TubeGeometry(new CatmullRomCurve3(pts, false, "centripetal"), 120, WIRE_RADIUS, 6), this.wireMat))
    })
  }

  /** Fingertip marker on the surface (null hides it). */
  setPress(p: (Point & { radius: number }) | null): void {
    this.marker.visible = p !== null
    if (!p) return
    this.marker.position.copy(this.surfacePoint(p.x, p.y, 0.8))
    this.marker.scale.set(p.radius, p.radius, 1)
    this.marker.children[1].scale.set(1 / p.radius, 1 / p.radius, 1)
  }

  /** Shows the scanned foot at `url` (loaded once per url). A later call wins over a load that is still in flight. */
  async setFoot(url: string): Promise<void> {
    const request = ++this.footRequest
    let p = this.footCache.get(url)
    if (!p) this.footCache.set(url, (p = FootModel.load(url)))
    const next = await p
    if (request !== this.footRequest || this.foot === next) return
    if (this.foot) this.scene.remove(this.foot.mesh)
    this.foot = next
    next.seat(this.insole.heightAt)
    next.mesh.visible = this.footVisible
    this.styleFoot()
    this.scene.add(next.mesh)
    this.poseFoot(this.lastPose, this.footRoll)
  }
  private lastPose: FootPose = { pitch: 0, pivot: 0, lift: 0 }

  setFootVisible(on: boolean): void {
    this.footVisible = on
    if (this.foot) this.foot.mesh.visible = on
  }

  /** Pitch/lift from the gait pose, plus roll (-1 pronation .. 1 supination) about the foot's long axis. */
  poseFoot(pose: FootPose, roll: number): void {
    this.lastPose = pose
    this.footRoll = roll
    if (!this.foot) return
    this.foot.pose(pose)
    // Pronation lowers the medial (+x) side.
    const m = this.foot.mesh
    const pivot = new Vector3(this.foot.centerX, 0, this.foot.seatZ)
    m.quaternion.setFromAxisAngle(new Vector3(0, 1, 0), -roll * FOOT_ROLL_RAD)
    m.position.copy(pivot).sub(pivot.clone().applyQuaternion(m.quaternion))
  }

  render(): boolean {
    const moving = this.controls.update()
    this.renderer.render(this.scene, this.camera)
    return moving
  }
}
