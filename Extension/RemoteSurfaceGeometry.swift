import QuartzCore

enum RemoteSurfaceGeometry {
    /// A hosted CAContext root must use an explicit zero anchor and position.
    /// Assigning frame with CALayer's default center anchor leaves a half-size
    /// position that the remote host applies again. Child layers use ordinary
    /// zero-origin frames within these bounds.
    static func apply(to root: CALayer, size: CGSize, scale: CGFloat) {
        root.anchorPoint = .zero
        root.bounds = CGRect(origin: .zero, size: size)
        root.position = .zero
        root.contentsScale = scale
    }
}
