// A way to put the keyboard away, in every Asteria app on iPhone. The iPhone keyboard has no key that hides it, and
// many fields (a chat composer, a search field, a note, a number pad) have no Return action that ends editing, so the
// keyboard could get stuck on screen (owner, 7 November 2026).
//
// The field you're typing in gets a small "hide keyboard" button at its trailing end while you edit: in a one-line
// field it sits in the field's trailing slot; in a multi-line one, at the trailing edge, and the text keeps clear of
// it. Done at the UIKit level, when any field starts editing, so it reaches every screen and sheet without
// each one asking for it. (SwiftUI's keyboard toolbar can't: it only reaches fields under the view that declares it,
// and SwiftUI gives every field its own accessory host, which ignores a replacement.) `Smartz.configure` installs it.
#if os(iOS)
import UIKit

@MainActor
enum SmartzKeyboard {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty, UIDevice.current.userInterfaceIdiom == .phone else { return }
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                nonisolated(unsafe) let field = note.object
                MainActor.assumeIsolated { attach(to: field as AnyObject?) }
            })
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                nonisolated(unsafe) let field = note.object
                MainActor.assumeIsolated { detach(from: field as AnyObject?) }
            })
        }
    }

    private static func attach(to field: AnyObject?) {
        guard let input = field as? UIView, let host = input.superview, !host.subviews.contains(where: { ($0 as? HideButton)?.field === input }) else { return }
        if let field = input as? UITextField {
            // A field that uses its trailing slot already (a search field's own button, say) keeps it.
            guard field.rightView == nil || field.rightView is Spacer else { return }
            field.rightView = Spacer(frame: CGRect(x: 0, y: 0, width: 32, height: 28))
            field.rightViewMode = .whileEditing
        } else if let view = input as? UITextView, view.isEditable {
            view.textContainerInset.right += 30
        } else {
            return
        }
        // The button sits over the field's trailing end, as the field's sibling, so a tap on it never reaches the field
        // (which would take it as a tap in the text and keep the keyboard up).
        let button = HideButton(field: input)
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        let vertical = input is UITextField
            ? button.centerYAnchor.constraint(equalTo: input.centerYAnchor)
            : button.bottomAnchor.constraint(equalTo: input.bottomAnchor, constant: -2)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: input.trailingAnchor, constant: -2),
            vertical,
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private static func detach(from field: AnyObject?) {
        guard let input = field as? UIView else { return }
        input.superview?.subviews.filter { ($0 as? HideButton)?.field === input }.forEach { $0.removeFromSuperview() }
        if let view = input as? UITextView { view.textContainerInset.right = max(0, view.textContainerInset.right - 30) }
    }

    /// Keeps the field's text clear of the button.
    final class Spacer: UIView {
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override var intrinsicContentSize: CGSize { bounds.size }
    }

    /// The little button: a keyboard with a chevron down, in the field's tint. Hides the keyboard.
    final class HideButton: UIButton {
        private(set) weak var field: UIView?

        init(field: UIView) {
            self.field = field
            super.init(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: "keyboard.chevron.compact.down",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            configuration.contentInsets = .zero
            self.configuration = configuration
            tintColor = .secondaryLabel
            accessibilityLabel = "Hide Keyboard"
            addAction(UIAction { [weak self] _ in self?.field?.resignFirstResponder() }, for: .primaryActionTriggered)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -8, dy: -8).contains(point)
        }
    }
}
#endif
