import SwiftSyntax

extension SyntaxProtocol {
    var nonWhitespaceDescription: String {
        description.filter { !$0.isWhitespace }
    }
}
