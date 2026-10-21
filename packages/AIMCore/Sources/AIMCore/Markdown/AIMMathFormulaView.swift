import SwiftMath
import SwiftUI

public enum AIMMathValidation {
    public static func isRenderable(_ latex: String) -> Bool {
        MTMathListBuilder.build(fromString: latex) != nil
    }
}

/// Native LaTeX rendering shared by every Markdown surface. SwiftMath performs
/// the typesetting directly; no JavaScript or web view is involved.
public struct AIMMathFormulaView: View {
    public let latex: String
    public var fontSize: CGFloat
    public var display: Bool

    public init(latex: String, fontSize: CGFloat = 18, display: Bool = false) {
        self.latex = latex
        self.fontSize = fontSize
        self.display = display
    }

    public var body: some View {
        Group {
            if AIMMathValidation.isRenderable(latex) {
                AIMMathPlatformView(latex: latex, fontSize: fontSize, display: display)
            } else {
                Text(latex)
                    .font(.system(size: fontSize, design: .serif))
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(latex))
    }
}

#if canImport(UIKit)
import UIKit

private struct AIMMathPlatformView: UIViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let display: Bool

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: fontSize)
        label.textAlignment = display ? .center : .left
        label.labelMode = display ? .display : .text
        label.textColor = .label
        label.contentInsets = MTEdgeInsets()
        label.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: proposal.width == nil ? .defaultLow : .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}
#elseif canImport(AppKit)
import AppKit

private struct AIMMathPlatformView: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let display: Bool

    func makeNSView(context: Context) -> MTMathUILabel { MTMathUILabel() }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: fontSize)
        label.textAlignment = display ? .center : .left
        label.labelMode = display ? .display : .text
        label.textColor = .labelColor
        label.contentInsets = MTEdgeInsets()
    }
}
#endif
