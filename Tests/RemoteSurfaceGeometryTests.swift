import QuartzCore

@main
struct RemoteSurfaceGeometryTests {
    static func main() {
        let root = CALayer()
        let child = CALayer()
        root.addSublayer(child)
        // Exercise the reported Retina screen, a non-Retina display, a small
        // picker preview, and re-acquisition of the Retina destination.
        let destinations: [(CGSize, CGFloat)] = [
            (CGSize(width: 1512, height: 982), 2),
            (CGSize(width: 1920, height: 1080), 1),
            (CGSize(width: 302, height: 196), 2),
            (CGSize(width: 1512, height: 982), 2),
        ]
        for (size, scale) in destinations {
            RemoteSurfaceGeometry.apply(to: root, size: size, scale: scale)
            child.frame = root.bounds
            assert(root.position == .zero)
            assert(root.anchorPoint == .zero)
            assert(root.bounds == CGRect(origin: .zero, size: size))
            assert(root.contentsScale == scale)
            assert(child.frame == root.bounds)
            // The exported root has neither a model-frame offset nor a position
            // offset for the remote host to apply a second time.
            assert(root.frame == CGRect(origin: .zero, size: size))
        }
        print("PASS: remote root has zero frame/anchor/position offsets across Retina, non-Retina, preview, and resize geometry")
    }
}
