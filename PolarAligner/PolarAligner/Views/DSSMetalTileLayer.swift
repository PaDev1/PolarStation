import SwiftUI
import Metal
import MetalKit

/// Metal-accelerated underlay that composites DSS sky imagery tiles.
///
/// Equatorial mode: tiles are axis-aligned rectangles on screen.
/// Alt-az mode: each tile's four RA/Dec corners are projected through the full
/// equatorial→alt-az→stereographic pipeline, producing a properly warped quad.
/// The GPU interpolates texture coordinates within each triangle, giving seamless
/// tile boundaries with correct orientation — no per-tile rotation math needed.
struct DSSMetalTileLayer: NSViewRepresentable {
    let viewModel: SkyMapViewModel
    let tileService: DSSTileService
    let viewSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, tileService: tileService)
    }

    func makeNSView(context: Context) -> MTKView {
        guard let device = tileService.device else { return MTKView() }
        let view = MTKView(frame: .zero, device: device)
        view.delegate              = context.coordinator
        view.isPaused              = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly       = false
        view.colorPixelFormat      = .bgra8Unorm
        view.clearColor            = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque        = false
        view.layer?.backgroundColor = CGColor(gray: 0, alpha: 0)
        context.coordinator.setup(device: device, view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard nsView.device != nil else { return }
        context.coordinator.viewModel   = viewModel
        context.coordinator.tileService = tileService
        context.coordinator.viewSize    = viewSize
        nsView.setNeedsDisplay(nsView.bounds)
    }

    // MARK: - Coordinator / MTKViewDelegate

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var viewModel: SkyMapViewModel
        var tileService: DSSTileService
        var viewSize: CGSize = .zero

        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?

        init(viewModel: SkyMapViewModel, tileService: DSSTileService) {
            self.viewModel   = viewModel
            self.tileService = tileService
        }

        func setup(device: MTLDevice, view: MTKView) {
            self.device = device
            commandQueue = device.makeCommandQueue()

            guard let library = device.makeDefaultLibrary(),
                  let vertFn  = library.makeFunction(name: "dss_vertex"),
                  let fragFn  = library.makeFunction(name: "dss_fragment") else { return }

            let vertDesc = MTLVertexDescriptor()
            vertDesc.attributes[0].format      = .float2  // position
            vertDesc.attributes[0].offset      = 0
            vertDesc.attributes[0].bufferIndex = 0
            vertDesc.attributes[1].format      = .float2  // texCoord
            vertDesc.attributes[1].offset      = 8
            vertDesc.attributes[1].bufferIndex = 0
            vertDesc.layouts[0].stride         = 16       // 4 floats × 4 bytes

            let pDesc = MTLRenderPipelineDescriptor()
            pDesc.vertexFunction   = vertFn
            pDesc.fragmentFunction = fragFn
            pDesc.vertexDescriptor = vertDesc
            pDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let att = pDesc.colorAttachments[0]!
            att.isBlendingEnabled           = true
            att.sourceRGBBlendFactor        = .sourceAlpha
            att.destinationRGBBlendFactor   = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor      = .one
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            pipeline = try? device.makeRenderPipelineState(descriptor: pDesc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let commandQueue,
                  let drawable = view.currentDrawable,
                  let rpDesc   = view.currentRenderPassDescriptor else { return }

            rpDesc.colorAttachments[0].loadAction = .clear

            let size = viewSize
            guard size.width > 0, size.height > 0 else {
                commitEmpty(commandQueue: commandQueue, rpDesc: rpDesc, drawable: drawable)
                return
            }

            let fov = viewModel.mapFOV
            guard fov <= DSSTileService.minFOV else {
                commitEmpty(commandQueue: commandQueue, rpDesc: rpDesc, drawable: drawable)
                return
            }

            // Ensure projection cache is current (LST, lat trig, projection center)
            viewModel.updateProjectionCache()
            let isAltAz = viewModel.mapMode == .altAz

            // Tile center: in alt-az mode convert current alt-az center to equatorial
            let tileCenter: (raDeg: Double, decDeg: Double)
            if isAltAz {
                tileCenter = viewModel.altazToEquatorialFast(
                    altDeg: viewModel.centerAlt, azDeg: viewModel.centerAz)
            } else {
                tileCenter = (viewModel.centerRA, viewModel.centerDec)
            }

            let tiles = tileService.visibleTiles(
                centerRA: tileCenter.raDeg, centerDec: tileCenter.decDeg, fov: fov)
            tileService.requestTiles(tiles)

            // Screen pixel → Metal NDC (y-up)
            let w = size.width, h = size.height
            func toNDC(_ sx: CGFloat, _ sy: CGFloat) -> (Float, Float) {
                (Float(sx / w * 2 - 1), Float(1 - sy / h * 2))
            }

            struct Cmd { let tex: MTLTexture; let verts: [Float] }
            var cmds: [Cmd] = []

            if isAltAz {
                // Alt-az: project each tile's 4 RA/Dec corners through the full pipeline.
                //
                // DSS images are north-up, east-left (sky-chart convention).
                // Our alt-az projection applies the same east-left flip as equatorial,
                // so no mirroring is needed — just project the corners and assign UVs:
                //
                //   NE (RA+hSz, Dec+hSz) → screen left-top  → UV (0,0) image top-left
                //   NW (RA-hSz, Dec+hSz) → screen right-top → UV (1,0) image top-right
                //   SE (RA+hSz, Dec-hSz) → screen left-bot  → UV (0,1) image bottom-left
                //   SW (RA-hSz, Dec-hSz) → screen right-bot → UV (1,1) image bottom-right
                //
                // The GPU bilinearly interpolates UV within each triangle, correctly
                // handling the parallactic rotation and any within-tile distortion.

                let hSz = DSSTileService.tileSizeDeg / 2.0

                for tile in tiles {
                    guard let tex = tileService.metalTexture(key: tile.key) else { continue }

                    // 4 corners: (raDeg, decDeg, u, v)
                    let corners: [(Double, Double, Float, Float)] = [
                        (tile.raDeg + hSz, tile.decDeg + hSz, 0, 0),  // NE
                        (tile.raDeg - hSz, tile.decDeg + hSz, 1, 0),  // NW
                        (tile.raDeg + hSz, tile.decDeg - hSz, 0, 1),  // SE
                        (tile.raDeg - hSz, tile.decDeg - hSz, 1, 1),  // SW
                    ]

                    var pts: [(Float, Float, Float, Float)] = []
                    var valid = true
                    for (ra, dec, u, v) in corners {
                        let clampedDec = min(max(dec, -89.9), 89.9)
                        guard let p = viewModel.projectFast(raDeg: ra, decDeg: clampedDec) else {
                            valid = false; break
                        }
                        let sp = viewModel.toScreen(p, size: size)
                        let (nx, ny) = toNDC(sp.x, sp.y)
                        pts.append((nx, ny, u, v))
                    }
                    guard valid, pts.count == 4 else { continue }

                    let (ne, nw, se, sw) = (pts[0], pts[1], pts[2], pts[3])
                    // Two triangles: NE-NW-SE and NW-SW-SE
                    cmds.append(Cmd(tex: tex, verts: [
                        ne.0, ne.1, ne.2, ne.3,
                        nw.0, nw.1, nw.2, nw.3,
                        se.0, se.1, se.2, se.3,
                        nw.0, nw.1, nw.2, nw.3,
                        sw.0, sw.1, sw.2, sw.3,
                        se.0, se.1, se.2, se.3,
                    ]))
                }

            } else {
                // Equatorial: axis-aligned rects (pixPerDeg scale)
                let halfView  = min(w, h) / 2.0
                let pixPerDeg = halfView / (fov / 2.0 * .pi / 180.0) * (.pi / 180.0)

                for tile in tiles {
                    guard let tex = tileService.metalTexture(key: tile.key) else { continue }
                    guard let proj = viewModel.projectFast(raDeg: tile.raDeg, decDeg: tile.decDeg)
                    else { continue }
                    let center = viewModel.toScreen(proj, size: size)
                    let half   = CGFloat(tile.sizeDeg * pixPerDeg / 2.0)
                    if center.x + half < 0 || center.x - half > w ||
                       center.y + half < 0 || center.y - half > h { continue }

                    // Screen corners → NDC
                    // In equatorial mode east is LEFT, so left edge = east = u=0
                    let (tlx, tly) = toNDC(center.x - half, center.y - half)  // screen top-left (east, north)
                    let (trx, try_) = toNDC(center.x + half, center.y - half)  // screen top-right (west, north)
                    let (blx, bly) = toNDC(center.x - half, center.y + half)  // screen bottom-left (east, south)
                    let (brx, bry) = toNDC(center.x + half, center.y + half)  // screen bottom-right (west, south)

                    cmds.append(Cmd(tex: tex, verts: [
                        tlx, tly,  0, 0,
                        trx, try_, 1, 0,
                        blx, bly,  0, 1,
                        trx, try_, 1, 0,
                        brx, bry,  1, 1,
                        blx, bly,  0, 1,
                    ]))
                }
            }

            guard let buf = commandQueue.makeCommandBuffer() else { return }
            guard let enc = buf.makeRenderCommandEncoder(descriptor: rpDesc) else {
                buf.commit(); return
            }

            if !cmds.isEmpty, let device {
                enc.setRenderPipelineState(pipeline)
                var allVerts: [Float] = []
                for cmd in cmds { allVerts.append(contentsOf: cmd.verts) }
                let byteLen = allVerts.count * MemoryLayout<Float>.size
                if let vBuf = device.makeBuffer(bytes: allVerts, length: byteLen,
                                                options: .storageModeShared) {
                    enc.setVertexBuffer(vBuf, offset: 0, index: 0)
                    for (i, cmd) in cmds.enumerated() {
                        enc.setFragmentTexture(cmd.tex, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
                    }
                }
            }

            enc.endEncoding()
            buf.present(drawable)
            buf.commit()
        }

        private func commitEmpty(commandQueue: MTLCommandQueue,
                                 rpDesc: MTLRenderPassDescriptor,
                                 drawable: CAMetalDrawable) {
            guard let buf = commandQueue.makeCommandBuffer() else { return }
            if let enc = buf.makeRenderCommandEncoder(descriptor: rpDesc) { enc.endEncoding() }
            buf.present(drawable)
            buf.commit()
        }
    }
}
