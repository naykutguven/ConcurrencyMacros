import SwiftSyntax
import Testing

extension DeclGroupSyntax {
    func memberDecl(at index: Int) throws -> DeclSyntax {
        let memberDecl = try #require(
            memberBlock.members.dropFirst(index).first?.decl,
            "Expected declaration to contain a member at index \(index): \(self)"
        )
        return DeclSyntax(memberDecl)
    }
}
