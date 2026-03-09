import SwiftSyntax
import Testing

extension AttributeSyntax {
    var identifierTypeName: String? {
        attributeName.as(IdentifierTypeSyntax.self)?.name.text
    }

    func singleArgumentExpressionDescription() throws -> String {
        let arguments = try #require(
            self.arguments?.as(LabeledExprListSyntax.self),
            "Expected attribute to have one argument"
        )
        let expression = try #require(
            arguments.first?.expression,
            "Expected attribute to include one argument expression"
        )
        return expression.nonWhitespaceDescription
    }
}
