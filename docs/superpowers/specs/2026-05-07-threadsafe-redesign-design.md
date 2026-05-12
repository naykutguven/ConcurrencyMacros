# ThreadSafe Redesign Design

Date: 2026-05-07

## Goal

Redesign `@ThreadSafe` into a macro that makes synchronous mutable class state easy to use safely with Swift Concurrency and explicit `Sendable` conformance.

The redesigned macro should:

- protect supported mutable instance stored properties by default
- make single-property read-modify-write operations atomic where Swift's accessor model permits it
- keep multi-property invariants explicit through a generated `inLock` helper
- support both checked `Sendable` and explicit `@unchecked Sendable` use cases
- diagnose unsupported or unsafe source shapes clearly
- replace fragile implementation details from the current `Mutex<_State>` design when needed

The public primary macro name remains `@ThreadSafe`. No compatibility constraint is required for current behavior because the SDK is not yet in use.

## User Model

Primary usage should stay small and obvious:

```swift
@ThreadSafe
final class Store: Sendable {
    var count = 0
    var items: [String] = []
}
```

The macro protects every supported mutable instance `var` by default. `let` properties are ignored. Unsupported mutable instance storage is diagnosed unless the user explicitly marks it with an escape hatch such as `@ThreadSafeIgnored`.

The class must explicitly declare either checked `Sendable` or `@unchecked Sendable`. The macro must not synthesize conformance invisibly because explicit conformance keeps the user responsible for deciding whether checked or unchecked safety is appropriate.

Checked `Sendable` mode:

- requires the class to be `final`
- requires all tracked stored property types to satisfy `Sendable`
- rejects `@ThreadSafeIgnored` mutable instance state
- uses generated compiler checks so type errors point back to the property/type involved

Unchecked mode:

- allows explicit `@unchecked Sendable`
- can support non-final classes, non-`Sendable` stored values, and ignored mutable state
- should emit diagnostics or notes that the user is taking responsibility for state outside the checked model

The expected ergonomic behavior is:

```swift
store.count += 1
store.items.append("x")
```

Both operations should be atomic for a single property. Multi-property invariants remain explicit:

```swift
store.inLock { state in
    state.count += state.items.count
}
```

## Generated Architecture

The current generated `Mutex<_State>` shape is not enough for the redesign because single-property `_modify` accessors need runtime support that can hold a lock for the full modifying access. The redesign should introduce dedicated runtime storage for generated `@ThreadSafe` code.

Checked mode should synthesize a `Sendable` state model:

```swift
private struct _ThreadSafeState: Sendable {
    var count: Int
    var items: [String]
}

private let _threadSafeStorage: ConcurrencyMacros.ThreadSafeStorage<_ThreadSafeState>
```

Unchecked mode should use a storage path that permits non-`Sendable` state:

```swift
private struct _ThreadSafeState {
    var formatter: DateFormatter
}

private let _threadSafeStorage: ConcurrencyMacros.UncheckedThreadSafeStorage<_ThreadSafeState>
```

The exact runtime API can be refined during implementation, but it must support these generated operations:

- locked snapshot reads
- locked writes
- `_modify`-compatible single-member mutation
- whole-state synchronous mutation for `inLock`

Generated properties should conceptually become computed properties with `get`, `set`, and `_modify`:

```swift
var count: Int {
    get { _threadSafeStorage.read(\.count) }
    set { _threadSafeStorage.write(\.count, newValue) }
    _modify {
        yield &_threadSafeStorage[modifying: \.count]
    }
}
```

The implementation should choose a runtime design that preserves this semantic requirement: the lock is held for the whole single-property modifying access, so operations such as `count += 1` and `items.append(...)` are atomic for that property.

The generated state helper should be:

```swift
@discardableResult
func inLock<Result: Sendable>(
    _ body: @Sendable (inout _ThreadSafeState) throws -> Result
) rethrows -> Result
```

Checked mode should keep the `Result: Sendable` constraint. Unchecked mode may use a relaxed helper if implementation proves that is necessary for legitimate unchecked use cases.

Unchecked mode should prefer this relaxed shape when the state or returned value cannot satisfy checked sendability:

```swift
@discardableResult
func inLock<Result>(
    _ body: (inout _ThreadSafeState) throws -> Result
) rethrows -> Result
```

The checked and unchecked helper signatures should remain source-compatible for ordinary call sites, but checked mode should keep the stronger `@Sendable` closure and `Result: Sendable` enforcement.

Reserved synthesized names should be macro-specific:

- `_ThreadSafeState`
- `_threadSafeStorage`
- `inLock`
- initializer staging locals derived from tracked properties

Name collisions must be diagnosed before expansion produces invalid or misleading code.

## Initializers

Initializer rewriting should keep the current staging model, but the contract should be simpler and stricter.

When a class has no designated initializer, every tracked property must have a default value or be optional-like so the macro can synthesize initial storage immediately.

When a class has designated initializers, each designated initializer must initialize every required tracked property through a plain top-level assignment before `_threadSafeStorage` initialization.

Conceptually:

```swift
@ThreadSafe
final class Store: Sendable {
    var count: Int
    var title = "Untitled"

    init(count: Int) {
        self.count = count
    }
}
```

rewrites initializer setup as:

```swift
var _count: Int
let _title: String = "Untitled"
_count = count
self._threadSafeStorage = .init(_ThreadSafeState(count: _count, title: _title))
```

After storage initialization, property access should use generated property accessors.

Unsupported pre-storage initializer behavior should be diagnosed. This includes:

- required assignment only inside conditional branches
- assignment inside loops, `defer`, `do/catch`, or other unsupported control flow
- reads of tracked properties before storage exists
- nested mutation of tracked properties before storage exists
- ambiguous multiple-initialization paths
- staging local collisions with parameters, locals, or tracked property names

The existing syntax-driven scanner and its regression coverage provide useful precedent and should be retained or adapted rather than replaced with string matching.

## Optional Method Support

Method atomicity should remain explicit. The macro must not auto-wrap every method because that would create reentrancy and deadlock hazards and cannot be made safe for arbitrary `async` APIs.

The redesign should add an optional helper macro named `@ThreadSafeMethod` for simple synchronous instance methods whose entire body should run under the lock:

```swift
@ThreadSafeMethod
func resetAndSeed(_ values: [String]) {
    count = values.count
    items = values
}
```

Recommended v1 scope:

- synchronous instance methods only
- no `async`
- no `static` or `class`
- no extension methods
- throwing methods are supported through the generated `rethrows` locking helper
- body runs under the same storage lock

Even with `@ThreadSafeMethod`, `inLock` remains the preferred API for nontrivial invariants because it makes the locked state explicit.

Generated documentation and diagnostics should warn users not to re-enter generated properties or call other locking methods while the same lock is held.

## Diagnostics

Diagnostics are part of the API surface. They should prefer explicit failure over silent partial protection.

Required diagnostics include:

- `@ThreadSafe` attached to a non-class declaration
- missing explicit `Sendable` or `@unchecked Sendable` conformance
- checked `Sendable` on a non-final class
- explicit `@unchecked Sendable` accepted, with clear responsibility language where useful
- `@ThreadSafeIgnored` used in checked mode
- unsupported instance mutable stored property shapes
- multi-binding mutable declarations
- non-identifier stored property patterns
- property wrappers
- property observers
- `lazy`, `weak`, `unowned`, and other unsupported modifiers
- unsupported property attributes
- complex inferred defaults without explicit type annotations
- reserved generated-name collisions
- invalid or ambiguous initializer staging
- unsupported initializer pre-storage property access

Diagnostics should give migration hints. Examples:

- split multi-binding declarations into separate `var` declarations
- add an explicit type annotation for complex defaults
- remove observers or move logic into an explicit locking method
- mark intentionally unmanaged mutable state with `@ThreadSafeIgnored` and use `@unchecked Sendable`
- mark checked `Sendable` classes `final`, or use `@unchecked Sendable` only when subclass state is intentionally outside macro checking

Where possible, checked mode should rely on generated compiler checks to enforce `Sendable` at the property type level. Macro diagnostics should still cover syntax-only safety rules that the compiler cannot infer from generated code.

## Testing

Macro expansion tests should cover:

- checked `Sendable` happy paths
- unchecked `Sendable` happy paths with non-`Sendable` stored values
- generated state and storage names
- generated `get`, `set`, `_modify`, and `inLock`
- no-designated-initializer default initialization
- designated-initializer staging
- helper attributes applied only where expected

Runtime tests should cover:

- concurrent `count += 1` reaches the expected final value
- concurrent array append or dictionary mutation is atomic for a single property
- `inLock` preserves multi-property invariants
- `inLock` rethrows errors and returns values correctly
- checked and unchecked storage variants behave consistently for locking

Diagnostic tests should cover every unsupported property shape and initializer flow listed above.

End-to-end tests should prove:

- one `import ConcurrencyMacros` is enough
- checked mode compiles for `final class Store: Sendable`
- unchecked mode compiles where checked mode cannot
- non-`Sendable` tracked values fail in checked mode

Regression tests should preserve current scanner edge-case coverage:

- no-space assignment
- bare and explicit `self` assignments
- shadowing by parameters and locals
- closure parameters and capture aliases
- nested declarations
- shorthand optional binding
- `for`, `switch`, and `catch` shadowing
- unsupported nested mutation before storage initialization

## Non-Goals

The v1 redesign does not include:

- auto-wrapping every method
- async method locking
- property wrapper support
- arbitrary type inference from complex default expressions
- protecting mutable state hidden behind computed properties
- guaranteeing thread safety of nested reference objects stored inside tracked properties
- making non-final checked `Sendable` classes appear safe

## Risks and Tradeoffs

Dedicated runtime storage increases implementation complexity, but it is required for the core ergonomic goal: atomic single-property read-modify-write operations.

Holding a lock across `_modify` introduces reentrancy risk. The macro should document this plainly and avoid auto-wrapping methods. Users should use `inLock` for intentional multi-field critical sections and avoid calling back into the same object while the lock is held.

Unchecked mode is intentionally less strict. It is necessary for legacy or framework types that cannot satisfy checked `Sendable`, but diagnostics and docs should make clear that users are taking responsibility for anything the compiler cannot verify.

Some unsupported source shapes will fail loudly. That is acceptable because silent partial protection is more dangerous than an explicit migration error.

## Acceptance Criteria

The redesign is ready for implementation when:

- the public model requires explicit checked or unchecked `Sendable` conformance
- checked mode requires `final`
- checked mode enforces tracked property `Sendable` constraints
- unchecked mode permits non-`Sendable` tracked values through an explicit unchecked path
- supported mutable instance properties are protected by default
- unsupported mutable instance state is diagnosed unless intentionally ignored
- single-property compound mutations are atomic through generated `_modify` behavior
- multi-property invariants are expressed through `inLock`
- initializer staging is syntax-driven and has comprehensive diagnostics
- tests cover expansion, runtime behavior, diagnostics, and single-import end-to-end usage
