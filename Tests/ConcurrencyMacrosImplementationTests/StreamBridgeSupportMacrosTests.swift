//
//  StreamBridgeSupportMacrosTests.swift
//  ConcurrencyMacrosImplementationTests
//
//  Created by Codex on 15.03.26.
//

import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing
@testable import ConcurrencyMacrosImplementation

@Suite("StreamBridgeSupportMacros")
struct StreamBridgeSupportMacrosTests {
    @Test("StreamToken expands conformance extension")
    func streamTokenExpandsConformanceExtension() throws {
        let source = """
        @StreamToken(cancelMethod: "invalidate")
        final class ObservationToken {
            func invalidate() {}
        }
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(ClassDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        let extensions = try StreamTokenMacro.expansion(
            of: attribute,
            attachedTo: declaration,
            providingExtensionsOf: TypeSyntax(stringLiteral: declaration.name.text),
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )

        #expect(extensions.count == 1)
        let output = try #require(extensions.first).nonWhitespaceDescription
        #expect(output.contains("extensionObservationToken:ConcurrencyMacros.StreamBridgeTokenCancellable"))
        #expect(output.contains("funccancelStreamBridgeToken(){self.invalidate()}"))
    }

    @Test("StreamToken rejects missing cancelMethod")
    func streamTokenRejectsMissingCancelMethod() throws {
        let source = """
        @StreamToken
        final class ObservationToken {}
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(ClassDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        do {
            _ = try StreamTokenMacro.expansion(
                of: attribute,
                attachedTo: declaration,
                providingExtensionsOf: TypeSyntax(stringLiteral: declaration.name.text),
                conformingTo: [],
                in: BasicMacroExpansionContext()
            )
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.message == "'@StreamToken' requires a 'cancelMethod:' argument.")
            #expect(diagnostic.diagMessage.diagnosticID == MessageID(domain: "StreamTokenMacro", id: "missingCancelMethod"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("StreamToken defers missing target cancel method checks to compiler")
    func streamTokenDefersMissingTargetCancelMethodChecksToCompiler() throws {
        let source = """
        @StreamToken(cancelMethod: "invalidate")
        final class ObservationToken {}
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(ClassDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        let extensions = try StreamTokenMacro.expansion(
            of: attribute,
            attachedTo: declaration,
            providingExtensionsOf: TypeSyntax(stringLiteral: declaration.name.text),
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )

        #expect(extensions.count == 1)
        let output = try #require(extensions.first).nonWhitespaceDescription
        #expect(output.contains("funccancelStreamBridgeToken(){self.invalidate()}"))
    }

    @Test("StreamToken defers unsupported cancel method signature checks to compiler")
    func streamTokenDefersUnsupportedCancelMethodSignatureChecksToCompiler() throws {
        let source = """
        @StreamToken(cancelMethod: "invalidate")
        final class ObservationToken {
            static func invalidate() {}
        }
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(ClassDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        let extensions = try StreamTokenMacro.expansion(
            of: attribute,
            attachedTo: declaration,
            providingExtensionsOf: TypeSyntax(stringLiteral: declaration.name.text),
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )

        #expect(extensions.count == 1)
        let output = try #require(extensions.first).nonWhitespaceDescription
        #expect(output.contains("funccancelStreamBridgeToken(){self.invalidate()}"))
    }

    @Test("StreamToken defers mutating cancel method checks to compiler")
    func streamTokenDefersMutatingCancelMethodChecksToCompiler() throws {
        let source = """
        @StreamToken(cancelMethod: "invalidate")
        struct ObservationToken {
            mutating func invalidate() {}
        }
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(StructDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        let extensions = try StreamTokenMacro.expansion(
            of: attribute,
            attachedTo: declaration,
            providingExtensionsOf: TypeSyntax(stringLiteral: declaration.name.text),
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )

        #expect(extensions.count == 1)
        let output = try #require(extensions.first).nonWhitespaceDescription
        #expect(output.contains("funccancelStreamBridgeToken(){self.invalidate()}"))
    }

    @Test("StreamBridgeDefaults validates argument set")
    func streamBridgeDefaultsValidatesArgumentSet() throws {
        let source = """
        @StreamBridgeDefaults(cancel: .none, buffering: .bufferingNewest(1), safety: .strict)
        final class StockTicker {}
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(ClassDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        let members = try StreamBridgeDefaultsMacro.expansion(
            of: attribute,
            providingMembersOf: declaration,
            conformingTo: [],
            in: BasicMacroExpansionContext()
        )

        #expect(members.isEmpty)
    }

    @Test("StreamBridgeDefaults rejects unknown labels")
    func streamBridgeDefaultsRejectsUnknownLabels() throws {
        let source = """
        @StreamBridgeDefaults(mode: .strict)
        final class StockTicker {}
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(ClassDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        do {
            _ = try StreamBridgeDefaultsMacro.expansion(
                of: attribute,
                providingMembersOf: declaration,
                conformingTo: [],
                in: BasicMacroExpansionContext()
            )
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.message == "'@StreamBridgeDefaults' arguments must be labeled 'cancel:', 'buffering:', or 'safety:'.")
            #expect(diagnostic.diagMessage.diagnosticID == MessageID(domain: "StreamBridgeDefaultsMacro", id: "unknownDefaultsArgumentLabel"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("StreamToken rejects actor attachment")
    func streamTokenRejectsActorAttachment() throws {
        let source = """
        @StreamToken(cancelMethod: "stop")
        actor ObservationToken {
            func stop() {}
        }
        """
        let sourceFile = Parser.parse(source: source)
        let declaration = try #require(sourceFile.statements.first?.item.as(ActorDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))

        do {
            _ = try StreamTokenMacro.expansion(
                of: attribute,
                attachedTo: declaration,
                providingExtensionsOf: TypeSyntax(stringLiteral: declaration.name.text),
                conformingTo: [],
                in: BasicMacroExpansionContext()
            )
            Issue.record("Expected diagnostics error to be thrown")
        } catch let error as DiagnosticsError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.message == "'@StreamToken' can only be attached to class, struct, or enum declarations.")
            #expect(diagnostic.diagMessage.diagnosticID == MessageID(domain: "StreamTokenMacro", id: "invalidAttachment"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
