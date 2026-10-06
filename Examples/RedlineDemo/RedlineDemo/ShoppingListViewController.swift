import UIKit

/// The UIKit tab's content: a shopping list built only from UIKit views, to try annotate mode on.
///
/// A class because UIKit screens are `UIViewController` subclasses.
final class ShoppingListViewController: UIViewController {
    private let itemField = UITextField()
    private let aisleControl = UISegmentedControl(items: ["Produce", "Dairy", "Pantry", "Frozen"])
    private let urgentSwitch = UISwitch()
    private let addButton = UIButton(configuration: .filled())
    private let statusLabel = UILabel()
    private var itemCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureControls()
        addContent()
    }

    // MARK: - Layout

    private func configureControls() {
        itemField.borderStyle = .roundedRect
        itemField.placeholder = "2 lemons"
        itemField.font = .preferredFont(forTextStyle: .body)
        itemField.adjustsFontForContentSizeCategory = true
        itemField.clearButtonMode = .whileEditing
        itemField.returnKeyType = .done
        itemField.accessibilityLabel = "Item"
        itemField.accessibilityIdentifier = "uikit.item"
        itemField.addAction(UIAction { [weak self] _ in self?.addItem() }, for: .editingDidEndOnExit)

        aisleControl.selectedSegmentIndex = 0
        aisleControl.accessibilityIdentifier = "uikit.aisle"

        urgentSwitch.accessibilityLabel = "Buy today"
        urgentSwitch.accessibilityIdentifier = "uikit.urgent"

        var button = UIButton.Configuration.filled()
        button.title = "Add to list"
        button.image = UIImage(systemName: "cart.badge.plus")
        button.imagePadding = 8
        button.buttonSize = .large
        button.cornerStyle = .large
        addButton.configuration = button
        addButton.accessibilityIdentifier = "uikit.submit"
        addButton.addAction(UIAction { [weak self] _ in self?.addItem() }, for: .primaryActionTriggered)

        statusLabel.text = "The list is empty."
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "uikit.status"
    }

    private func addContent() {
        let heading = Self.makeLabel("Shopping list", style: .title2)
        heading.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        heading.accessibilityTraits = .header

        let hint = Self.makeLabel("Put the quantity in the name, such as 2 lemons.", style: .footnote)
        // Planted bug for the demo: a fixed dark gray, not .secondaryLabel, so the hint fades out in dark mode.
        hint.textColor = UIColor(white: 0.25, alpha: 1)
        hint.accessibilityIdentifier = "uikit.hint"

        let item = Self.makeStack([Self.makeLabel("Item", style: .headline), itemField, hint], spacing: 8)
        let aisle = Self.makeStack([Self.makeLabel("Aisle", style: .headline), aisleControl], spacing: 8)
        let urgent = UIStackView(arrangedSubviews: [Self.makeLabel("Buy today", style: .body), urgentSwitch])
        urgent.alignment = .center
        urgent.spacing = 12

        let content = Self.makeStack([makeBanner(), heading, item, aisle, urgent, addButton, statusLabel], spacing: 24)
        content.setCustomSpacing(12, after: addButton)

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
            itemField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    /// The note at the top of the screen that says it is built with UIKit.
    private func makeBanner() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "info.circle.fill"))
        icon.tintColor = .systemBlue
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = Self.makeLabel("This screen is UIKit", style: .headline)
        let body = Self.makeLabel(
            """
            Every control and label on this screen is a UIKit view: UILabel, UITextField, UISegmentedControl, \
            UISwitch and UIButton, in a UIViewController hosted with UIViewControllerRepresentable. Redline can pick \
            UIKit views today. Support for apps without a SwiftUI root is coming soon.
            """,
            style: .subheadline
        )
        let row = UIStackView(arrangedSubviews: [icon, Self.makeStack([title, body], spacing: 4)])
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let banner = UIView()
        banner.backgroundColor = .systemBlue.withAlphaComponent(0.12)
        banner.layer.cornerRadius = 14
        banner.layer.cornerCurve = .continuous
        banner.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: banner.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -14),
        ])

        // One accessibility element, so VoiceOver reads it and Redline picks it as a whole.
        banner.isAccessibilityElement = true
        banner.accessibilityLabel = [title.text, body.text].compactMap { $0 }.joined(separator: ". ")
        banner.accessibilityIdentifier = "uikit.banner"
        return banner
    }

    private static func makeLabel(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private static func makeStack(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        return stack
    }

    // MARK: - Adding items

    private func addItem() {
        let name = itemField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            statusLabel.text = "Enter an item first."
            return
        }
        let aisle = aisleControl.titleForSegment(at: aisleControl.selectedSegmentIndex) ?? ""
        let urgency = urgentSwitch.isOn ? "buy today" : "no rush"
        itemCount += 1
        itemField.text = nil
        let count = itemCount == 1 ? "1 item" : "\(itemCount) items"
        statusLabel.text = "\(count) on the list. Last added: \(name), \(aisle), \(urgency)."
    }
}
