import AppKit

class PaddedTextFieldCell: NSTextFieldCell {
    private let inset = NSSize(width: 8, height: 2)
    var fieldBackgroundColor: NSColor?
    var fieldCornerRadius: CGFloat = 4

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let bg = fieldBackgroundColor {
            let path = NSBezierPath(roundedRect: cellFrame, xRadius: fieldCornerRadius, yRadius: fieldCornerRadius)
            bg.setFill()
            path.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        return base.insetBy(dx: inset.width, dy: inset.height)
    }

    private func configureEditor(_ textObj: NSText) {
        if let color = textColor { textObj.textColor = color }
        if let tv = textObj as? NSTextView {
            tv.insertionPointColor = textColor ?? .textColor
            tv.drawsBackground = false
            tv.backgroundColor = .clear
        }
        textObj.font = font
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        configureEditor(textObj)
        super.edit(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        configureEditor(textObj)
        super.select(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

// MARK: - Attachment chip button

private class AttachmentChip: NSView {
    var onRemove: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let thumb = NSImageView()
    private let removeBtn = NSButton()

    init(attachment: ChatAttachment, theme t: PopoverTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = t.inputBg.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = t.accentColor.withAlphaComponent(0.4).cgColor

        thumb.frame = NSRect(x: 4, y: 4, width: 16, height: 16)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        if let img = attachment.thumbnail {
            thumb.image = img
            if !attachment.isImage {
                thumb.contentTintColor = t.accentColor
            }
        }
        addSubview(thumb)

        label.frame = NSRect(x: 24, y: 5, width: 90, height: 14)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = t.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = attachment.filename
        addSubview(label)

        removeBtn.frame = NSRect(x: 118, y: 3, width: 18, height: 18)
        removeBtn.bezelStyle = .inline
        removeBtn.isBordered = false
        removeBtn.title = ""
        if let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove") {
            removeBtn.image = x.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        }
        removeBtn.contentTintColor = t.textDim
        removeBtn.target = self
        removeBtn.action = #selector(tappedRemove)
        addSubview(removeBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tappedRemove() { onRemove?() }
}

// MARK: - TerminalView

class TerminalView: NSView, NSTextFieldDelegate {
    let scrollView    = NSScrollView()
    let textView      = NSTextView()
    let inputField    = NSTextField()
    private let attachStrip = NSView()

    /// Called when the user submits a message, with any pending file/image attachments.
    var onSendMessage: ((String, [ChatAttachment]) -> Void)?
    /// Called when a slash command is run (e.g. "stop", "dir", "model", "finder").
    /// "help" is handled internally and not forwarded.
    var onSlashCommand: ((String) -> Void)?

    // MARK: - Slash commands (consistent across every provider)

    private struct SlashItem {
        let name: String
        let summary: String
        let isProvider: Bool
    }
    /// App-level commands — same behavior in every provider.
    private let appCommands: [SlashItem] = [
        SlashItem(name: "stop",   summary: "Interrupt the current turn", isProvider: false),
        SlashItem(name: "dir",    summary: "Change the working directory", isProvider: false),
        SlashItem(name: "model",  summary: "Set the model for this pet", isProvider: false),
        SlashItem(name: "finder", summary: "Open the working directory in Finder", isProvider: false),
        SlashItem(name: "help",   summary: "List slash commands", isProvider: false),
    ]
    /// Commands the provider's CLI advertises (from its stream-json init event).
    private var providerCommandItems: [SlashItem] = []
    private var allCommands: [SlashItem] { appCommands + providerCommandItems }
    private let palette = NSView()
    private var filteredCommands: [SlashItem] = []
    private var selectedCommandIndex = 0
    private var paletteVisible = false
    private let paletteRowHeight: CGFloat = 22
    private let maxVisibleRows = 8

    /// Provider-advertised slash commands (names, with or without a leading "/").
    /// App commands take precedence on name clashes.
    func setProviderCommands(_ names: [String]) {
        let appNames = Set(appCommands.map { $0.name })
        providerCommandItems = names
            .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty && !appNames.contains($0) }
            .map { SlashItem(name: $0, summary: "\(provider.displayName) command", isProvider: true) }
        if paletteVisible { updateSlashPalette() }
    }

    private var pendingAttachments: [ChatAttachment] = [] {
        didSet { rebuildAttachmentStrip(); updateLayout() }
    }
    private var isDragHighlighted = false {
        didSet { layer?.borderColor = isDragHighlighted ? theme.accentColor.cgColor : NSColor.clear.cgColor
                 layer?.borderWidth = isDragHighlighted ? 2 : 0 }
    }
    private var currentAssistantText = ""
    private var isStreaming = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupViews()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupViews()
        registerForDraggedTypes([.fileURL])
    }

    var characterColor: NSColor?
    var themeOverride: PopoverTheme?
    var provider: AgentProvider = .claude { didSet { updatePlaceholder() } }

    var theme: PopoverTheme {
        var t = themeOverride ?? PopoverTheme.current
        if let color = characterColor { t = t.withCharacterColor(color) }
        t = t.withCustomFont()
        return t
    }

    // MARK: - Layout

    private let inputHeight: CGFloat = 30
    private let padding: CGFloat     = 10
    private let stripHeight: CGFloat = 28

    private func updateLayout() {
        let hasAttachments = !pendingAttachments.isEmpty
        let usedStripH = hasAttachments ? stripHeight : 0

        inputField.frame = NSRect(x: padding, y: 6,
                                  width: frame.width - padding * 2, height: inputHeight)

        attachStrip.isHidden = !hasAttachments
        attachStrip.frame = NSRect(x: padding, y: inputHeight + 6 + 2,
                                   width: frame.width - padding * 2, height: usedStripH)

        let scrollY = inputHeight + 6 + 2 + usedStripH + 4
        scrollView.frame = NSRect(x: padding, y: scrollY,
                                  width: frame.width - padding * 2,
                                  height: frame.height - scrollY - padding)

        if paletteVisible { layoutPalette() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        updateLayout()
    }

    // MARK: - Setup

    private func setupViews() {
        let t = theme

        // Scroll / text view
        scrollView.hasVerticalScroller  = true
        scrollView.scrollerStyle        = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.borderType           = .noBorder
        scrollView.drawsBackground      = false

        textView.isEditable      = false
        textView.isSelectable    = true
        textView.backgroundColor = .clear
        textView.textColor       = t.textPrimary
        textView.font            = t.font
        textView.isRichText      = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = 8
        textView.defaultParagraphStyle = defaultPara
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        addSubview(scrollView)

        // Attachment strip (hidden until files are dropped)
        attachStrip.wantsLayer = true
        attachStrip.layer?.backgroundColor = NSColor.clear.cgColor
        attachStrip.isHidden = true
        addSubview(attachStrip)

        // Input field
        inputField.focusRingType = .none
        let paddedCell = PaddedTextFieldCell(textCell: "")
        paddedCell.isEditable    = true
        paddedCell.isScrollable  = true
        paddedCell.font          = t.font
        paddedCell.textColor     = t.textPrimary
        paddedCell.drawsBackground = false
        paddedCell.isBezeled     = false
        paddedCell.fieldBackgroundColor = nil
        paddedCell.fieldCornerRadius    = 0
        paddedCell.placeholderAttributedString = NSAttributedString(
            string: provider.inputPlaceholder,
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        )
        inputField.cell   = paddedCell
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        inputField.delegate = self
        addSubview(inputField)

        // Slash-command suggestion palette (hidden until "/" is typed).
        palette.wantsLayer = true
        palette.layer?.backgroundColor = t.popoverBg.cgColor
        palette.layer?.cornerRadius = 6
        palette.layer?.borderWidth = 1
        palette.layer?.borderColor = t.separatorColor.cgColor
        palette.isHidden = true
        addSubview(palette)

        updateLayout()
    }

    private func updatePlaceholder() {
        let t = theme
        (inputField.cell as? PaddedTextFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: provider.inputPlaceholder,
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        )
    }

    // MARK: - Attachment strip UI

    private func rebuildAttachmentStrip() {
        attachStrip.subviews.forEach { $0.removeFromSuperview() }
        let t = theme
        var x: CGFloat = 0
        for (i, att) in pendingAttachments.enumerated() {
            let chip = AttachmentChip(attachment: att, theme: t)
            chip.frame = NSRect(x: x, y: 2, width: 138, height: 24)
            chip.onRemove = { [weak self] in
                self?.pendingAttachments.remove(at: i)
            }
            attachStrip.addSubview(chip)
            x += 142
        }
    }

    // MARK: - Input

    @objc private func inputSubmitted() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // A bare "/command" matching an app command runs it instead of messaging
        // the agent. Provider commands (e.g. /compact) fall through and are sent
        // to the CLI as a normal message.
        if text.hasPrefix("/") {
            let name = String(text.dropFirst()).lowercased()
            if appCommands.contains(where: { $0.name == name }) {
                inputField.stringValue = ""
                hidePalette()
                runCommand(name)
                return
            }
        }
        inputField.stringValue = ""

        let attachments = pendingAttachments
        pendingAttachments = []

        appendUser(text)
        isStreaming = true
        currentAssistantText = ""
        onSendMessage?(text, attachments)
    }

    // MARK: - Slash-command palette

    /// NSTextField text changed — refresh the suggestion palette.
    func controlTextDidChange(_ obj: Notification) {
        updateSlashPalette()
    }

    /// Intercept arrows / Enter / Tab / Esc while the palette is open.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard paletteVisible else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            selectedCommandIndex = max(0, selectedCommandIndex - 1)
            rebuildPaletteRows()
            return true
        case #selector(NSResponder.moveDown(_:)):
            selectedCommandIndex = min(filteredCommands.count - 1, selectedCommandIndex + 1)
            rebuildPaletteRows()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            executeSelectedCommand()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if selectedCommandIndex < filteredCommands.count {
                inputField.stringValue = "/\(filteredCommands[selectedCommandIndex].name)"
            }
            updateSlashPalette()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hidePalette()
            return true
        default:
            return false
        }
    }

    private func updateSlashPalette() {
        let text = inputField.stringValue
        // Only while typing a single "/token" (no space yet).
        guard text.hasPrefix("/"), !text.contains(" ") else { hidePalette(); return }
        let query = String(text.dropFirst()).lowercased()
        filteredCommands = query.isEmpty ? allCommands : allCommands.filter { $0.name.hasPrefix(query) }
        guard !filteredCommands.isEmpty else { hidePalette(); return }
        if selectedCommandIndex >= filteredCommands.count { selectedCommandIndex = 0 }
        paletteVisible = true
        palette.isHidden = false
        layoutPalette()
    }

    /// Visible slice of the filtered list, scrolled to keep the selection in view.
    private func visibleWindow() -> (start: Int, count: Int) {
        let total = filteredCommands.count
        let count = min(total, maxVisibleRows)
        var start = 0
        if selectedCommandIndex >= maxVisibleRows {
            start = selectedCommandIndex - maxVisibleRows + 1
        }
        start = max(0, min(start, total - count))
        return (start, count)
    }

    private func layoutPalette() {
        let stripUsed = pendingAttachments.isEmpty ? 0 : stripHeight + 2
        let (_, count) = visibleWindow()
        let h = CGFloat(count) * paletteRowHeight + 8
        palette.frame = NSRect(x: padding, y: inputHeight + 10 + stripUsed,
                               width: frame.width - padding * 2, height: h)
        rebuildPaletteRows()
    }

    private func hidePalette() {
        paletteVisible = false
        palette.isHidden = true
        selectedCommandIndex = 0
    }

    private func rebuildPaletteRows() {
        palette.subviews.forEach { $0.removeFromSuperview() }
        let t = theme
        let (start, count) = visibleWindow()
        for offset in 0..<count {
            let idx = start + offset
            let cmd = filteredCommands[idx]
            let y = palette.bounds.height - CGFloat(offset + 1) * paletteRowHeight - 4
            let row = NSButton(frame: NSRect(x: 4, y: y, width: palette.bounds.width - 8, height: paletteRowHeight))
            row.isBordered = false
            row.bezelStyle = .inline
            row.alignment = .left
            let title = NSMutableAttributedString()
            title.append(NSAttributedString(string: "/\(cmd.name)  ", attributes: [
                .font: t.fontBold, .foregroundColor: t.accentColor
            ]))
            title.append(NSAttributedString(string: cmd.summary, attributes: [
                .font: t.font, .foregroundColor: t.textDim
            ]))
            row.attributedTitle = title
            row.wantsLayer = true
            row.layer?.cornerRadius = 4
            row.layer?.backgroundColor = (idx == selectedCommandIndex)
                ? t.accentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            row.tag = idx
            row.target = self
            row.action = #selector(paletteRowClicked(_:))
            palette.addSubview(row)
        }
    }

    @objc private func paletteRowClicked(_ sender: NSButton) {
        selectedCommandIndex = sender.tag
        executeSelectedCommand()
    }

    private func executeSelectedCommand() {
        guard paletteVisible, selectedCommandIndex < filteredCommands.count else { return }
        let item = filteredCommands[selectedCommandIndex]
        inputField.stringValue = ""
        hidePalette()
        if item.isProvider {
            // Send the provider command to the CLI as a normal message.
            sendText("/\(item.name)")
        } else {
            runCommand(item.name)
        }
    }

    /// Submit arbitrary text as if the user typed and entered it.
    private func sendText(_ text: String) {
        appendUser(text)
        isStreaming = true
        currentAssistantText = ""
        onSendMessage?(text, [])
    }

    private func runCommand(_ name: String) {
        if name == "help" {
            var lines = appCommands.map { "  /\($0.name) — \($0.summary)" }
            if !providerCommandItems.isEmpty {
                lines.append("  …plus \(providerCommandItems.count) \(provider.displayName) commands (type / to see them)")
            }
            appendSystemNote("Slash commands:\n\(lines.joined(separator: "\n"))")
            return
        }
        onSlashCommand?(name)
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragHighlighted = false
        guard let urls = sender.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        else { return false }
        let new = urls.compactMap { ChatAttachment.from(url: $0) }
        guard !new.isEmpty else { return false }
        pendingAttachments.append(contentsOf: new)
        return true
    }

    // MARK: - Append Methods

    private var messageSpacing: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0 {
            if !storage.string.hasSuffix("\n") {
                storage.append(NSAttributedString(string: "\n"))
            }
        }
    }

    func appendUser(_ text: String) {
        let t = theme
        ensureNewline()
        let para = messageSpacing
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "> ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor, .paragraphStyle: para
        ]))
        attributed.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: t.fontBold, .foregroundColor: t.textPrimary, .paragraphStyle: para
        ]))
        textView.textStorage?.append(attributed)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        currentAssistantText += cleaned
        if !cleaned.isEmpty {
            textView.textStorage?.append(renderMarkdown(cleaned))
            scrollToBottom()
        }
    }

    func endStreaming() {
        if isStreaming { isStreaming = false }
    }

    func appendError(_ text: String) {
        let t = theme
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: t.font, .foregroundColor: t.errorColor
        ]))
        scrollToBottom()
    }

    /// A dim, non-error system note (e.g. "Stopped").
    func appendSystemNote(_ text: String) {
        let t = theme
        endStreaming()
        ensureNewline()
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        scrollToBottom()
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        endStreaming()
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "  \(toolName.uppercased()) ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        let color  = isError ? t.errorColor : t.successColor
        let prefix = isError ? "  FAIL " : "  DONE "
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: prefix, attributes: [
            .font: t.fontBold, .foregroundColor: color
        ]))
        block.append(NSAttributedString(string: "\(summary.isEmpty ? "" : summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func replayHistory(_ messages: [AgentMessage]) {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
            case .error:
                appendError(msg.text)
            case .toolUse:
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
            case .toolResult:
                let isErr = msg.text.hasPrefix("ERROR:")
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: isErr ? t.errorColor : t.successColor
                ]))
            }
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let t = theme
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeLines.joined(separator: "\n")
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
                    result.append(NSAttributedString(string: codeText + "\n", attributes: [
                        .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock { codeLines.append(line); continue }

            if line.hasPrefix("### ") {
                result.append(NSAttributedString(string: String(line.dropFirst(4)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("## ") {
                result.append(NSAttributedString(string: String(line.dropFirst(3)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 1, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 2, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                result.append(NSAttributedString(string: "  \u{2022} ", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
                result.append(renderInlineMarkdown(content + suffix, theme: t))
            } else {
                result.append(renderInlineMarkdown(line + suffix, theme: t))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            let codeText = codeLines.joined(separator: "\n")
            let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
            result.append(NSAttributedString(string: codeText + "\n", attributes: [
                .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
            ]))
        }

        return result
    }

    private func renderInlineMarkdown(_ text: String, theme t: PopoverTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex

        while i < text.endIndex {
            if text[i] == "`" {
                let afterTick = text.index(after: i)
                if afterTick < text.endIndex, let closeIdx = text[afterTick...].firstIndex(of: "`") {
                    let code = String(text[afterTick..<closeIdx])
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 0.5, weight: .regular)
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: codeFont, .foregroundColor: t.accentColor, .backgroundColor: t.inputBg
                    ]))
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            if text[i] == "*",
               text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    let bold = String(text[start..<range.lowerBound])
                    result.append(NSAttributedString(string: bold, attributes: [
                        .font: t.fontBold, .foregroundColor: t.textPrimary
                    ]))
                    i = range.upperBound
                    continue
                }
            }
            if text[i] == "[" {
                let afterBracket = text.index(after: i)
                if afterBracket < text.endIndex,
                   let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let parenStart = text.index(after: closeBracket)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let afterParen = text.index(after: parenStart)
                        if afterParen < text.endIndex,
                           let closeParen = text[afterParen...].firstIndex(of: ")") {
                            let linkText = String(text[afterBracket..<closeBracket])
                            let urlStr   = String(text[afterParen..<closeParen])
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: t.font, .foregroundColor: t.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                            if let url = URL(string: urlStr) { attrs[.link] = url }
                            result.append(NSAttributedString(string: linkText, attributes: attrs))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }
            if text[i] == "h" {
                let remaining = String(text[i...])
                if remaining.hasPrefix("https://") || remaining.hasPrefix("http://") {
                    var j = i
                    while j < text.endIndex && !text[j].isWhitespace && text[j] != ")" && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    let urlStr = String(text[i..<j])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: t.font, .foregroundColor: t.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                    if let url = URL(string: urlStr) { attrs[.link] = url }
                    result.append(NSAttributedString(string: urlStr, attributes: attrs))
                    i = j
                    continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: t.font, .foregroundColor: t.textPrimary
            ]))
            i = text.index(after: i)
        }
        return result
    }
}
