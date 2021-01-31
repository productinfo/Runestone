//
//  LayoutManager.swift
//  
//
//  Created by Simon Støvring on 25/01/2021.
//

import UIKit

protocol LayoutManagerDelegate: AnyObject {
    func layoutManager(_ layoutManager: LayoutManager, stringIn range: NSRange) -> String
    func layoutManagerDidInvalidateContentSize(_ layoutManager: LayoutManager)
    func lengthOfString(in layoutManager: LayoutManager) -> Int
}

final class LayoutManager {
    // MARK: - Public
    weak var delegate: LayoutManagerDelegate?
    weak var containerView: UIView? {
        didSet {
            if containerView != oldValue {
                setupViewHierarchy()
            }
        }
    }
    var lineManager: LineManager
    var frame: CGRect = .zero {
        didSet {
            if frame.size.width != oldValue.size.width {
                invalidateAllLines()
            }
        }
    }
    var viewport: CGRect = .zero
    var contentSize: CGSize {
        if let contentSize = _contentSize {
            return contentSize
        } else {
            let contentSize = CGSize(width: frame.width, height: lineManager.contentHeight)
            _contentSize = contentSize
            return contentSize
        }
    }
    var theme: EditorTheme = DefaultEditorTheme() {
        didSet {
            if theme !== oldValue {
                gutterBackgroundView.backgroundColor = theme.gutterBackgroundColor
                gutterBackgroundView.hairlineColor = theme.gutterHairlineColor
                gutterBackgroundView.hairlineWidth = theme.gutterHairlineWidth
                gutterSelectionBackgroundView.backgroundColor = theme.selectedLinesGutterBackgroundColor
                lineSelectionBackgroundView.backgroundColor = theme.selectedLineBackgroundColor
                invalidateAllLines()
            }
        }
    }
    var isEditing = false {
        didSet {
            if isEditing != oldValue {
                updateShownViews()
            }
        }
    }
    var showLineNumbers = false {
        didSet {
            if showLineNumbers != oldValue {
                updateShownViews()
                if showLineNumbers {
                    updateGutterWidth()
                }
            }
        }
    }
    var highlightSelectedLine = false {
        didSet {
            if highlightSelectedLine != oldValue {
                updateShownViews()
            }
        }
    }
    var gutterLeadingPadding: CGFloat = 3
    var gutterTrailingPadding: CGFloat = 3
    var gutterMargin: CGFloat = 10
    var selectedRange: NSRange? {
        didSet {
            if selectedRange != oldValue {
                updateShownViews()
            }
        }
    }
    var gutterWidth: CGFloat {
        if showLineNumbers {
            return lineNumberWidth + gutterLeadingPadding + gutterTrailingPadding
        } else {
            return 0
        }
    }

    // MARK: - Views
    private var lineViewReuseQueue = ViewReuseQueue<DocumentLineNodeID, LineView>()
    private var lineNumberLabelReuseQueue = ViewReuseQueue<DocumentLineNodeID, LineNumberView>()
    private let gutterBackgroundView = GutterBackgroundView()
    private let lineNumberContainerView = UIView()
    private let gutterSelectionBackgroundView = UIView()
    private let lineSelectionBackgroundView = UIView()

    // MARK: - Sizing
    private var _contentSize: CGSize?
    private var lineNumberWidth: CGFloat = 0
    private var previousGutterWidthUpdateLineCount: Int?
    private var leadingLineSpacing: CGFloat {
        if showLineNumbers {
            return gutterWidth + gutterMargin
        } else {
            return 0
        }
    }

    // MARK: - Rendering
    private let operationQueue: OperationQueue
    private let syntaxHighlightController: SyntaxHighlightController
    private var textRenderers: [DocumentLineNodeID: TextRenderer] = [:]
    private var needsLayout = false
    private var needsLayoutSelection = false

    // MARK: - Helpers
    private var currentDelegate: LayoutManagerDelegate {
        if let delegate = delegate {
            return delegate
        } else {
            fatalError("Delegate unavailable")
        }
    }

    init(lineManager: LineManager, syntaxHighlightController: SyntaxHighlightController, operationQueue: OperationQueue) {
        self.lineManager = lineManager
        self.syntaxHighlightController = syntaxHighlightController
        self.operationQueue = operationQueue
        self.gutterBackgroundView.isUserInteractionEnabled = false
        self.lineNumberContainerView.isUserInteractionEnabled = false
        self.gutterSelectionBackgroundView.isUserInteractionEnabled = false
        self.lineSelectionBackgroundView.isUserInteractionEnabled = false
        self.updateShownViews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveMemoryWarning(_:)),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil)
    }

    func setNeedsLayout() {
        needsLayout = true
    }

    func layoutIfNeeded() {
        guard needsLayout else {
            return
        }
        needsLayout = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        syntaxHighlightController.prepare()
        layoutGutter()
        layoutSelection()
        let oldVisibleLineIds = Set(lineViewReuseQueue.visibleViews.keys)
        var nextLine = lineManager.line(containingYOffset: viewport.minY)
        var appearedLineIDs: Set<DocumentLineNodeID> = []
        var maxY = viewport.minY
        while let line = nextLine, maxY < viewport.maxY {
            appearedLineIDs.insert(line.id)
            show(line, maxY: &maxY)
            if line.index < lineManager.lineCount - 1 {
                nextLine = lineManager.line(atIndex: line.index + 1)
            } else {
                nextLine = nil
            }
        }
        let disappearedLineIDs = oldVisibleLineIds.subtracting(appearedLineIDs)
        lineViewReuseQueue.enqueueViews(withKeys: disappearedLineIDs)
        lineNumberLabelReuseQueue.enqueueViews(withKeys: disappearedLineIDs)
        if _contentSize == nil {
            delegate?.layoutManagerDidInvalidateContentSize(self)
        }
        CATransaction.commit()
    }

    func setNeedsLayoutSelection() {
        needsLayoutSelection = true
    }

    func layoutSelectionIfNeeded() {
        guard needsLayoutSelection else {
            return
        }
        needsLayoutSelection = true
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        layoutSelection()
        CATransaction.commit()
    }

    func invalidateContentSize() {
        _contentSize = nil
    }

    func removeLine(withID lineID: DocumentLineNodeID) {
        textRenderers.removeValue(forKey: lineID)
    }

    func invalidateAndPrepare(_ lines: Set<DocumentLineNode>) {
        for line in lines {
            if let textRenderer = textRenderers[line.id] {
                textRenderer.documentRange = NSRange(location: line.location, length: line.data.totalLength)
                textRenderer.documentByteRange = line.data.byteRange
                textRenderer.invalidate()
                textRenderer.prepareToDraw()
            }
        }
    }

    func invalidateAllLines() {
        let allTextRenderers = textRenderers.values
        for textRenderer in allTextRenderers {
            textRenderer.invalidate()
        }
    }

    func updateGutterWidth() {
        guard showLineNumbers else {
            return
        }
        let lineCount = lineManager.lineCount
        if lineCount != previousGutterWidthUpdateLineCount {
            previousGutterWidthUpdateLineCount = lineCount
            let characterCount = "\(lineCount)".count
            let wideLineNumberString = String(repeating: "8", count: characterCount)
            let wideLineNumberNSString = wideLineNumberString as NSString
            let size = wideLineNumberNSString.size(withAttributes: [.font: theme.lineNumberFont])
            lineNumberWidth = ceil(size.width) + gutterLeadingPadding + gutterTrailingPadding
        }
    }
}

// MARK: - UITextInput
extension LayoutManager {
    func caretRect(at location: Int) -> CGRect? {
        guard let line = lineManager.line(containingCharacterAt: location) else {
            return nil
        }
        let textRenderer = getTextRenderer(for: line)
        let localLocation = location - line.location
        let localCaretRect = textRenderer.caretRect(atIndex: localLocation)
        let globalYPosition = line.yPosition + localCaretRect.minY
        let globalRect = CGRect(x: localCaretRect.minX, y: globalYPosition, width: localCaretRect.width, height: localCaretRect.height)
        return globalRect.offsetBy(dx: leadingLineSpacing, dy: 0)
    }

    func firstRect(for range: NSRange) -> CGRect? {
        guard let line = lineManager.line(containingCharacterAt: range.location) else {
            fatalError("Cannot find first rect.")
        }
        let textRenderer = textRenderers[line.id]!
        let localRange = NSRange(location: range.location - line.location, length: min(range.length, line.value))
        let firstRect = textRenderer.firstRect(for: localRange)
        return firstRect?.offsetBy(dx: leadingLineSpacing, dy: 0)
    }

    func selectionRects(in range: NSRange) -> [TextSelectionRect] {
        guard let startLine = lineManager.line(containingCharacterAt: range.location) else {
            return []
        }
        guard let endLine = lineManager.line(containingCharacterAt: range.location + range.length) else {
            return []
        }
        var selectionRects: [TextSelectionRect] = []
        let lineIndexRange = startLine.index ..< endLine.index + 1
        for lineIndex in lineIndexRange {
            let line = lineManager.line(atIndex: lineIndex)
            let textRenderer = getTextRenderer(for: line)
            let lineStartLocation = line.location
            let lineEndLocation = lineStartLocation + line.data.totalLength
            let localRangeLocation = max(range.location, lineStartLocation) - lineStartLocation
            let localRangeLength = min(range.location + range.length, lineEndLocation) - lineStartLocation - localRangeLocation
            let localRange = NSRange(location: localRangeLocation, length: localRangeLength)
            let rendererSelectionRects = textRenderer.selectionRects(in: localRange)
            let textSelectionRects: [TextSelectionRect] = rendererSelectionRects.map { rendererSelectionRect in
                let y = line.yPosition + rendererSelectionRect.rect.minY
                var screenRect = CGRect(x: rendererSelectionRect.rect.minX, y: y, width: rendererSelectionRect.rect.width, height: rendererSelectionRect.rect.height)
                let startLocation = lineStartLocation + rendererSelectionRect.range.location
                let endLocation = startLocation + rendererSelectionRect.range.length
                let containsStart = range.location >= startLocation && range.location <= endLocation
                let containsEnd = range.location + range.length >= startLocation && range.location + range.length <= endLocation
                screenRect.origin.x += leadingLineSpacing
                if endLocation < range.location + range.length {
                    screenRect.size.width = frame.width - screenRect.minX
                }
                return TextSelectionRect(rect: screenRect, writingDirection: .leftToRight, containsStart: containsStart, containsEnd: containsEnd)
            }
            selectionRects.append(contentsOf: textSelectionRects)
        }
        return selectionRects.ensuringYAxisAlignment()
    }

    func closestIndex(to point: CGPoint) -> Int? {
        if let line = lineManager.line(containingYOffset: point.y), let textRenderer = textRenderers[line.id] {
            return closestIndex(to: point, in: textRenderer, showing: line)
        } else if point.y <= 0 {
            let firstLine = lineManager.firstLine
            if let textRenderer = textRenderers[firstLine.id] {
                return closestIndex(to: point, in: textRenderer, showing: firstLine)
            } else {
                return 0
            }
        } else {
            let lastLine = lineManager.lastLine
            if point.y >= lastLine.yPosition, let textRenderer = textRenderers[lastLine.id] {
                return closestIndex(to: point, in: textRenderer, showing: lastLine)
            } else {
                return currentDelegate.lengthOfString(in: self)
            }
        }
    }

    private func closestIndex(to point: CGPoint, in textRenderer: TextRenderer, showing line: DocumentLineNode) -> Int {
        let localPoint = CGPoint(x: point.x - leadingLineSpacing, y: point.y - textRenderer.frame.minY)
        let index = textRenderer.closestIndex(to: localPoint)
        if index >= line.data.length && index <= line.data.totalLength && line != lineManager.lastLine {
            return line.location + line.data.length
        } else {
            return line.location + index
        }
    }
}

// MARK: - Layout
extension LayoutManager {
    private func layoutGutter() {
        gutterBackgroundView.frame = CGRect(x: 0, y: viewport.minY, width: gutterWidth, height: viewport.height)
        lineNumberContainerView.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: contentSize.height)
    }

    private func layoutSelection() {
        guard highlightSelectedLine, let selectedRange = selectedRange else {
            return
        }
        let startLocation = selectedRange.location
        let endLocation = selectedRange.location + selectedRange.length
        let selectedRect: CGRect
        if selectedRange.length > 0 {
            let startLine = lineManager.line(containingCharacterAt: startLocation)!
            let endLine = lineManager.line(containingCharacterAt: endLocation)!
            let startTextRenderer = getTextRenderer(for: startLine)
            let endTextRenderer = getTextRenderer(for: endLine)
            let yPos = startTextRenderer.frame.minY
            let height = endTextRenderer.frame.maxY - startTextRenderer.frame.minY
            selectedRect = CGRect(x: 0, y: yPos, width: frame.width, height: height)
        } else {
            let line = lineManager.line(containingCharacterAt: startLocation)!
            let textRenderer = getTextRenderer(for: line)
            selectedRect = CGRect(x: 0, y: textRenderer.frame.minY, width: frame.width, height: textRenderer.frame.height)
        }
        gutterSelectionBackgroundView.frame = CGRect(x: 0, y: selectedRect.minY, width: gutterWidth, height: selectedRect.height)
        lineSelectionBackgroundView.frame = CGRect(x: gutterWidth, y: selectedRect.minY, width: frame.width - gutterWidth, height: selectedRect.height)
    }

    private func setupViewHierarchy() {
        // Remove views from view hierarchy
        gutterBackgroundView.removeFromSuperview()
        lineNumberContainerView.removeFromSuperview()
        gutterSelectionBackgroundView.removeFromSuperview()
        lineSelectionBackgroundView.removeFromSuperview()
        let allLineNumberKeys = lineViewReuseQueue.visibleViews.keys
        lineViewReuseQueue.enqueueViews(withKeys: Set(allLineNumberKeys))
        // Add views to view hierarchy
        containerView?.addSubview(gutterBackgroundView)
        containerView?.addSubview(gutterSelectionBackgroundView)
        containerView?.addSubview(lineSelectionBackgroundView)
        containerView?.addSubview(lineNumberContainerView)
    }

    private func updateShownViews() {
        let selectedLength = selectedRange?.length ?? 0
        gutterBackgroundView.isHidden = !showLineNumbers
        lineNumberContainerView.isHidden = !showLineNumbers
        gutterSelectionBackgroundView.isHidden = !highlightSelectedLine || !showLineNumbers || !isEditing
        lineSelectionBackgroundView.isHidden = !highlightSelectedLine || !isEditing || selectedLength > 0
    }
}

// MARK: - Drawing
extension LayoutManager {
    private func show(_ line: DocumentLineNode, maxY: inout CGFloat) {
        let lineView = lineViewReuseQueue.dequeueView(forKey: line.id)
        let lineNumberView = lineNumberLabelReuseQueue.dequeueView(forKey: line.id)
        // Ensure views are added to the view hiearchy
        if lineView.superview == nil {
            containerView?.addSubview(lineView)
        }
        if lineNumberView.superview == nil {
            lineNumberContainerView.addSubview(lineNumberView)
        }
        // Setup the line
        let lineYPosition = line.yPosition
        let textRenderer = getTextRenderer(for: line)
        prepare(textRenderer, toDraw: line)
        lineView.textRenderer = textRenderer
        lineView.frame = CGRect(x: leadingLineSpacing, y: lineYPosition, width: textRenderer.lineWidth, height: textRenderer.preferredHeight)
        lineView.setNeedsDisplay()
        // Setup the line number
        lineNumberView.text = "\(line.index + 1)"
        lineNumberView.textColor = theme.lineNumberColor
        lineNumberView.font = theme.font
        lineNumberView.frame = CGRect(x: gutterLeadingPadding, y: lineYPosition, width: lineNumberWidth, height: textRenderer.preferredHeight)
        // Start highlighting the line
        textRenderer.syntaxHighlight()
        // Pass back the maximum Y position so the caller can determine if it needs to show more lines.
        maxY = lineView.frame.maxY
    }

    private func getTextRenderer(for line: DocumentLineNode) -> TextRenderer {
        if let cachedTextRenderer = textRenderers[line.id] {
            return cachedTextRenderer
        } else {
            let textRenderer = TextRenderer(syntaxHighlightController: syntaxHighlightController, syntaxHighlightQueue: operationQueue)
            textRenderer.delegate = self
            textRenderer.lineID = line.id
            prepare(textRenderer, toDraw: line)
            textRenderers[line.id] = textRenderer
            return textRenderer
        }
    }

    private func prepare(_ textRenderer: TextRenderer, toDraw line: DocumentLineNode) {
        textRenderer.lineID = line.id
        textRenderer.documentRange = NSRange(location: line.location, length: line.data.totalLength)
        textRenderer.documentByteRange = line.data.byteRange
        textRenderer.lineWidth = frame.width - leadingLineSpacing
        textRenderer.font = theme.font
        textRenderer.textColor = theme.textColor
        textRenderer.prepareToDraw()
        let lineHeight = ceil(textRenderer.preferredHeight)
        let didUpdateHeight = lineManager.setHeight(of: line, to: lineHeight)
        if didUpdateHeight {
            _contentSize = nil
        }
    }
}

// MARK: - TextRendererDelegate
extension LayoutManager: TextRendererDelegate {
    func textRenderer(_ textRenderer: TextRenderer, stringIn range: NSRange) -> String {
        return currentDelegate.layoutManager(self, stringIn: range)
    }

    func textRendererDidUpdateSyntaxHighlighting(_ textRenderer: TextRenderer) {
        if let lineID = textRenderer.lineID {
            let lineView = lineViewReuseQueue.visibleViews[lineID]
            lineView?.setNeedsDisplay()
        }
    }
}

// MARK: - Memory Management
private extension LayoutManager {
    @objc private func didReceiveMemoryWarning(_ notification: Notification) {
        let allLineIDs = Set(textRenderers.keys)
        let visibleLineIDs = Set(lineViewReuseQueue.visibleViews.keys)
        let lineIDsToRelease = allLineIDs.subtracting(visibleLineIDs)
        for lineID in lineIDsToRelease {
            textRenderers.removeValue(forKey: lineID)
        }
    }
}