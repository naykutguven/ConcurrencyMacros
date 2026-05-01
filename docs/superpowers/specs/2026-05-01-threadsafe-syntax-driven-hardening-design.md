# ThreadSafe Syntax-Driven Hardening Design

Date: 2026-05-01

## Goal

Harden `@ThreadSafe` for 1.0 by replacing fragile string and regex based macro logic with syntax-driven analysis where correctness depends on Swift source structure. The public macro API should remain unchanged.

The implementation should support a conservative Swift surface reliably and diagnose unsupported shapes clearly instead of silently skipping them.

## Current Problems

`ThreadSafeInitializerMacro` detects initializer assignments by searching rendered statement strings. This misses valid syntax such as no-space assignments and can misread statements whose source text merely contains an assignment-looking substring.

`ClassDeclSyntax.storedVariables` returns tuple metadata and infers unannotated property types from default value text. That works for simple literals, but it cannot reliably represent complex defaults because macros do not have type-checker information.

`VariableDeclSyntax.isMutable` rejects any attributed property and any multi-binding declaration by returning `false`. That makes unsupported shapes disappear from expansion instead of producing actionable diagnostics.

## Recommended Approach

Use SwiftSyntax to build an internal property model and to identify initializer assignments structurally.

Introduce an internal representation similar to:

```swift
struct ThreadSafeStoredProperty {
    let name: TokenSyntax
    let type: TypeSyntax
    let defaultValue: ExprSyntax?
}
```

The model should be created by a stricter stored-property extractor. The extractor should either return a supported property or report why the property cannot participate in `@ThreadSafe`.

## Supported Property Surface

For 1.0, support single-binding mutable stored properties with identifier patterns:

```swift
var value: Value
var value: Value = defaultValue
var value: Value?
```

Simple inferred literals should remain supported for source compatibility when the macro can map the literal to an unambiguous Swift type:

```swift
var count = 0
var enabled = true
var name = "Seed"
```

All other inferred defaults should require explicit type annotations:

```swift
var formatter: DateFormatter = DateFormatter()
var cache: [String: Item] = [:]
var value: Value = makeValue()
```

Unsupported property shapes should emit diagnostics. This includes property wrappers, multi-binding declarations, unsupported attributes that interfere with accessor generation, and complex inferred defaults without explicit type annotations. Computed properties should be ignored because they are not stored properties and do not need `_State` storage.

## Initializer Rewriting

Replace regex assignment detection with SwiftSyntax matching for assignment expressions.

The initializer macro should recognize plain assignments to tracked properties:

```swift
self.value = value
value = value
self.value=value
value=value
```

The syntax matcher should inspect assignment expressions rather than source text. It should match an `=` operator and a left-hand side that is either a tracked identifier or a member access whose base is `self` and whose member name is tracked.

The body rewrite should:

1. Insert staging locals for tracked properties at the top of the initializer body.
2. Rewrite supported assignments before state initialization to assign the staging local instead of the original property.
3. Insert `self._state = ConcurrencyMacros.Mutex<_State>(_State(...))` after the last required tracked-property assignment.
4. Leave statements after `_state` initialization unchanged so later property access uses the generated accessors.

Unsupported initializer forms should be diagnosed when they affect correctness. Examples include required tracked properties assigned only inside conditional branches, loops, `defer`, `do/catch`, unsupported pattern assignments, or initializer flows that make it ambiguous whether `_state` is initialized exactly once.

## Diagnostics

The hardened implementation should prefer explicit diagnostics over silent skipping. Diagnostics should explain the exact migration path.

Examples:

- "Property 'cache' must declare an explicit type when the default value is not a simple literal."
- "`@ThreadSafe` supports one stored property per declaration; split 'a' and 'b' into separate declarations."
- "`@ThreadSafe` does not support property wrappers in 1.0."
- "Initializer assignment to 'value' must be a plain assignment before `_state` initialization."

Diagnostic identifiers should be stable enough for tests.

## Testing

Add focused macro tests for:

- no-space initializer assignments
- `self.value = ...` and bare `value = ...`
- false-positive string cases that should not rewrite
- complex inferred defaults diagnosed unless explicitly typed
- property wrappers diagnosed
- multi-binding declarations diagnosed
- computed properties ignored because they are not tracked stored properties
- required property assignments in unsupported control flow diagnosed
- current happy paths preserved

End-to-end expansion tests should continue checking that `_State`, `_state`, accessors, and initializer rewriting compose correctly.

## Non-Goals

This design does not add full property-wrapper support. Wrapper-backed storage and generated accessor macros interact in ways that need a separate design.

This design does not attempt to infer arbitrary Swift types from expressions. Macros do not have type-checker access, so complex defaults should be explicitly typed.

This design does not change the public `@ThreadSafe`, `@ThreadSafeProperty`, or `@ThreadSafeInitializer` macro spelling.

## Risks and Tradeoffs

The implementation will be more complex than the current string-based approach. The benefit is that the behavior becomes tied to Swift syntax instead of formatting.

Some users may see new build failures where unsupported shapes were previously skipped. That is intentional for 1.0 readiness because silent partial expansion is more dangerous than an explicit migration error.

SwiftSyntax APIs add maintenance cost, but the package already depends on SwiftSyntax and is pinned to a narrow `602.x` range.

## Acceptance Criteria

The hardening is complete when:

- initializer assignment detection no longer depends on regex or rendered statement strings
- no-space assignments are handled correctly
- unsupported tracked property shapes produce diagnostics instead of silent skips
- simple inferred literals remain supported, and all other inferred defaults are diagnosed
- existing supported `@ThreadSafe` usage keeps expanding as before
- relevant macro expansion tests cover happy paths and rejected shapes
