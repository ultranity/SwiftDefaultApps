/*
* ----------------------------------------------------------------------------
* "THE BEER-WARE LICENSE" (Revision 42):
* <g.litenstein@gmail.com> wrote this file. As long as you retain this notice you
* can do whatever you want with this stuff. If we meet some day, and you think
* this stuff is worth it, you can buy me a beer in return., Gregorio Litenstein.
* ----------------------------------------------------------------------------
*/

import SwiftUI

/**
Sidebar list backed by NSOutlineView. The File Types list holds thousands of rows; an outline view only
builds the visible ones and reloads in one pass, where SwiftUI's List diffs every row on each change.
Group headers toggle on click (Option-click toggles every group); collapsed state lives in AppModel.
*/
@MainActor
struct EntryList: NSViewRepresentable {
	@ObservedObject var model: AppModel

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> NSScrollView {
		let outline = NSOutlineView()
		let column = NSTableColumn(identifier: .init("entry"))
		outline.addTableColumn(column)
		outline.outlineTableColumn = column
		outline.headerView = nil
		outline.style = .sourceList
		outline.floatsGroupRows = true
		outline.indentationPerLevel = 0
		outline.usesAutomaticRowHeights = false
		outline.dataSource = context.coordinator
		outline.delegate = context.coordinator
		outline.target = context.coordinator
		outline.action = #selector(Coordinator.clicked(_:))
		context.coordinator.outline = outline

		let scroll = NSScrollView()
		scroll.documentView = outline
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		context.coordinator.update(model)
	}

	@MainActor
	final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
		/** NSOutlineView identifies items by reference. */
		final class Group {
			let section: EntrySection
			let rows: [Row]
			init(_ section: EntrySection) {
				self.section = section
				self.rows = section.entries.map(Row.init)
			}
		}
		final class Row {
			let entry: Entry
			init(_ entry: Entry) { self.entry = entry }
		}

		weak var outline: NSOutlineView?
		private var model: AppModel?
		private var version = -1
		private var groups: [Group] = []
		/** Rows shown at the root when the list is not grouped. */
		private var flat: [Row] = []
		private var rowsByID: [String: Row] = [:]
		private var isSyncing = false
		private var shownSelection: String?

		func update(_ model: AppModel) {
			self.model = model
			guard let outline else { return }
			isSyncing = true
			defer { isSyncing = false }
			if version != model.listVersion {
				version = model.listVersion
				let sections = model.sections
				if sections.count == 1, sections[0].title == nil {
					groups = []
					flat = sections[0].entries.map(Row.init)
					rowsByID = Dictionary(flat.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })
				} else {
					groups = sections.map(Group.init)
					flat = []
					rowsByID = Dictionary(groups.flatMap(\.rows).map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })
				}
				outline.reloadData()
				for group in groups where !model.isCollapsed(group.section) {
					outline.expandItem(group)
				}
			}
			syncSelection()
		}

		private func syncSelection() {
			guard let outline, let model else { return }
			guard let id = model.selection, let row = rowsByID[id], outline.row(forItem: row) >= 0 else {
				outline.deselectAll(nil)
				return
			}
			let index = outline.row(forItem: row)
			if outline.selectedRow != index {
				outline.selectRowIndexes([index], byExtendingSelection: false)
			}
			// Only follow selection changes; reloads (e.g. collapsing a group) keep the scroll position.
			if shownSelection != id {
				shownSelection = id
				outline.scrollRowToVisible(index)
			}
		}

		@objc func clicked(_ sender: NSOutlineView) {
			guard let group = sender.item(atRow: sender.clickedRow) as? Group else { return }
			model?.toggle(group.section.id, all: NSEvent.modifierFlags.contains(.option))
		}

		// MARK: Data source

		func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
			switch item {
			case nil: return groups.isEmpty ? flat.count : groups.count
			case let group as Group: return group.rows.count
			default: return 0
			}
		}

		func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
			switch item {
			case nil: return groups.isEmpty ? flat[index] : groups[index]
			case let group as Group: return group.rows[index]
			default: fatalError("Rows have no children")
			}
		}

		func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Group }

		// MARK: Delegate

		func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Group }

		func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Row }

		/** Expansion is driven by AppModel through clicks on the header, never by the outline view itself. */
		func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

		func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
			item is Group ? 24 : 34
		}

		func outlineViewSelectionDidChange(_ notification: Notification) {
			guard !isSyncing, let outline, let row = outline.item(atRow: outline.selectedRow) as? Row else { return }
			shownSelection = row.entry.id
			model?.selection = row.entry.id
		}

		func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
			switch item {
			case let group as Group:
				let cell = outlineView.makeView(withIdentifier: GroupCell.identifier, owner: nil) as? GroupCell ?? GroupCell()
				cell.configure(group.section, isCollapsed: model?.isCollapsed(group.section) ?? false)
				cell.wantsLayer = true
				return cell
			case let row as Row:
				let cell = outlineView.makeView(withIdentifier: EntryCell.identifier, owner: nil) as? EntryCell ?? EntryCell()
				cell.configure(row.entry)
				return cell
			default:
				return nil
			}
		}
	}
}

/** Icon, title and a secondary line. */
private final class EntryCell: NSTableCellView {
	static let identifier = NSUserInterfaceItemIdentifier("EntryCell")
	private let visualEffectView = NSVisualEffectView()
	private let icon = NSImageView()
	private let title = NSTextField(labelWithString: "")
	private let subtitle = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		setupVisualEffect()
		identifier = Self.identifier
		title.lineBreakMode = .byTruncatingTail
		subtitle.lineBreakMode = .byTruncatingMiddle
		subtitle.font = .preferredFont(forTextStyle: .caption1)
		subtitle.textColor = .secondaryLabelColor
		let text = NSStackView(views: [title, subtitle])
		text.orientation = .vertical
		text.alignment = .leading
		text.spacing = 1
		let stack = NSStackView(views: [icon, text])
		stack.spacing = 8
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			icon.widthAnchor.constraint(equalToConstant: 20),
			icon.heightAnchor.constraint(equalToConstant: 20),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
		text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	}

	required init?(coder: NSCoder) { fatalError() }

	@MainActor
	func configure(_ entry: Entry) {
		title.stringValue = entry.title
		subtitle.stringValue = entry.subtitle
		subtitle.isHidden = entry.subtitle.isEmpty
		switch entry.kind {
		case .scheme:
			icon.image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)
			icon.contentTintColor = .systemBlue
		case .type:
			icon.image = Icons.type(entry.id)
			icon.contentTintColor = nil
		case .app(let declarations):
			icon.image = Icons.app(declarations.path)
			icon.contentTintColor = nil
		}
	}
	private func setupVisualEffect() {
		visualEffectView.material = .headerView
		visualEffectView.blendingMode = .withinWindow
		visualEffectView.state = .followsWindowActiveState
		visualEffectView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(visualEffectView, positioned: .below, relativeTo: nil)
		NSLayoutConstraint.activate([
			visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
			visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
			visualEffectView.topAnchor.constraint(equalTo: topAnchor),
			visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor)
		])
	}
}

/** Group header: disclosure chevron, optional app icon, title and row count. */
private final class GroupCell: NSTableCellView {
	static let identifier = NSUserInterfaceItemIdentifier("GroupCell")
	private let chevron = NSImageView()
	private let icon = NSImageView()
	private let title = NSTextField(labelWithString: "")
	private let count = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		identifier = Self.identifier
		chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
		chevron.contentTintColor = .secondaryLabelColor
		title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
		title.textColor = .secondaryLabelColor
		title.lineBreakMode = .byTruncatingTail
		count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
		count.textColor = .tertiaryLabelColor
		let spacer = NSView()
		spacer.setContentHuggingPriority(.init(1), for: .horizontal)
		let stack = NSStackView(views: [chevron, icon, title, spacer, count])
		stack.spacing = 5
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			chevron.widthAnchor.constraint(equalToConstant: 10),
			icon.widthAnchor.constraint(equalToConstant: 14),
			icon.heightAnchor.constraint(equalToConstant: 14),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
		title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		toolTip = "Click to collapse or expand; Option-click for all groups"
	}

	required init?(coder: NSCoder) { fatalError() }

	override var wantsUpdateLayer: Bool { true }
	override func updateLayer() {
		super.updateLayer()
		layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
	}
	@MainActor
	func configure(_ section: EntrySection, isCollapsed: Bool) {
		chevron.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
		icon.image = section.app.map { Icons.app($0.path) }
		icon.isHidden = section.app == nil
		title.stringValue = section.title ?? ""
		count.stringValue = "\(section.entries.count)"
	}
}
