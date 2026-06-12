---
title: Standard Library
description: Reference for Skein's built-in standard library modules.
---

Skein ships with 11 standard library modules available in every Skein program without imports. Stdlib calls compile to static function calls on the corresponding `Skein.Runtime.Stdlib.*` Elixir module.

:::tip[Detailed API docs]
Full API documentation with typespecs is available in the [ExDoc API Reference](/Skein/api/). Generate locally with `mix docs` from the project root.
:::

## String

Text operations. All functions operate on UTF-8 binaries.

```skein
let name = "  Hello, World!  "
String.trim(name)            -- "Hello, World!"
String.upcase("hello")       -- "HELLO"
String.length("hi")          -- 2
String.contains("abc", "b")  -- true
String.split("a,b,c", ",")  -- ["a", "b", "c"]
String.replace("hi", "h", "H") -- "Hi"
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `length` | `(String) -> Int` | Number of Unicode graphemes |
| `slice` | `(String, Int, Int) -> String` | Substring from offset with length |
| `contains` | `(String, String) -> Bool` | Whether string contains substring |
| `split` | `(String, String) -> List[String]` | Split on delimiter |
| `trim` | `(String) -> String` | Remove leading/trailing whitespace |
| `upcase` | `(String) -> String` | Convert to uppercase |
| `downcase` | `(String) -> String` | Convert to lowercase |
| `starts_with` | `(String, String) -> Bool` | Check prefix |
| `ends_with` | `(String, String) -> Bool` | Check suffix |
| `replace` | `(String, String, String) -> String` | Replace all occurrences |

## Int

Integer operations.

```skein
Int.parse("42")          -- Ok(42)
Int.abs(-5)              -- 5
Int.clamp(15, 0, 10)     -- 10
Int.min(3, 7)            -- 3
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `parse` | `(String) -> Result[Int, String]` | Parse string to integer |
| `to_string` | `(Int) -> String` | Convert to string |
| `abs` | `(Int) -> Int` | Absolute value |
| `min` | `(Int, Int) -> Int` | Smaller of two values |
| `max` | `(Int, Int) -> Int` | Larger of two values |
| `clamp` | `(Int, Int, Int) -> Int` | Constrain to range [min, max] |

## Float

Floating-point operations.

```skein
Float.parse("3.14")     -- Ok(3.14)
Float.round(3.456, 2)   -- 3.46
Float.ceil(2.1)          -- 3
Float.floor(2.9)         -- 2
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `parse` | `(String) -> Result[Float, String]` | Parse string to float |
| `to_string` | `(Float) -> String` | Convert to string |
| `round` | `(Float, Int) -> Float` | Round to N decimal places |
| `ceil` | `(Float) -> Int` | Round up to the nearest integer |
| `floor` | `(Float) -> Int` | Round down to the nearest integer |

## List

Collection operations. Lists are ordered, heterogeneous sequences.

```skein
fn double(x: Int) -> Int { x * 2 }
fn over_three(x: Int) -> Bool { x > 3 }
fn add(acc: Int, x: Int) -> Int { acc + x }

let nums = [1, 2, 3, 4, 5]
List.map(nums, &double)        -- [2, 4, 6, 8, 10]
List.filter(nums, &over_three) -- [4, 5]
List.reduce(nums, 0, &add)     -- 15
List.first(nums)               -- Some(1)
List.reverse(nums)             -- [5, 4, 3, 2, 1]
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `length` | `(List[T]) -> Int` | Number of elements |
| `map` | `(List[T], (T) -> U) -> List[U]` | Transform each element |
| `filter` | `(List[T], (T) -> Bool) -> List[T]` | Keep elements matching predicate |
| `reduce` | `(List[T], U, (U, T) -> U) -> U` | Fold left with accumulator |
| `find` | `(List[T], (T) -> Bool) -> Option[T]` | First matching element |
| `first` | `(List[T]) -> Option[T]` | First element |
| `last` | `(List[T]) -> Option[T]` | Last element |
| `head` | `(List[T]) -> Option[T]` | Alias for `first` |
| `tail` | `(List[T]) -> List[T]` | All elements except the first |
| `take` | `(List[T], Int) -> List[T]` | First N elements |
| `drop` | `(List[T], Int) -> List[T]` | All except first N elements |
| `sort` | `(List[T]) -> List[T]` | Sort in ascending order |
| `sort_by` | `(List[T], (T) -> U) -> List[T]` | Sort by key function |
| `reverse` | `(List[T]) -> List[T]` | Reverse order |
| `flatten` | `(List[List[T]]) -> List[T]` | Flatten one level of nesting |
| `concat` | `(List[T], List[T]) -> List[T]` | Join two lists |
| `contains` | `(List[T], T) -> Bool` | Membership test |
| `any` | `(List[T], (T) -> Bool) -> Bool` | True if any element matches |
| `all` | `(List[T], (T) -> Bool) -> Bool` | True if all elements match |
| `none` | `(List[T], (T) -> Bool) -> Bool` | True if no element matches |
| `zip` | `(List[T], List[U]) -> List[[T, U]]` | Pair elements from two lists |
| `uniq` | `(List[T]) -> List[T]` | Remove duplicates |
| `count` | `(List[T], (T) -> Bool) -> Int` | Count matching elements |
| `group_by` | `(List[T], (T) -> K) -> Map[K, List[T]]` | Group by key function |

## Map

Key-value operations. Maps are unordered collections of unique keys to values.

```skein
let m = { name: "Alice", age: 30 }
Map.get(m, "name")        -- Some("Alice")
Map.get!(m, "name")       -- "Alice" (raises on missing)
Map.keys(m)               -- ["name", "age"]
Map.has(m, "email")       -- false
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `get` | `(Map[K,V], K) -> Option[V]` | Lookup by key |
| `get!` | `(Map[K,V], K) -> V` | Lookup by key, raises on missing |
| `put` | `(Map[K,V], K, V) -> Map[K,V]` | Insert or update key |
| `delete` | `(Map[K,V], K) -> Map[K,V]` | Remove key |
| `keys` | `(Map[K,V]) -> List[K]` | All keys |
| `values` | `(Map[K,V]) -> List[V]` | All values |
| `entries` | `(Map[K,V]) -> List[[K,V]]` | All key-value pairs |
| `size` | `(Map[K,V]) -> Int` | Number of entries |
| `has` | `(Map[K,V], K) -> Bool` | Key existence check |
| `merge` | `(Map[K,V], Map[K,V]) -> Map[K,V]` | Merge maps (second wins on conflicts) |
| `map_values` | `(Map[K,V], (V) -> U) -> Map[K,U]` | Transform all values |
| `filter` | `(Map[K,V], (K,V) -> Bool) -> Map[K,V]` | Keep matching entries |

## Set

Unique collections. Sets are unordered collections of unique values.

```skein
let s = Set.from([1, 2, 3])
Set.contains(s, 2)               -- true
Set.union(s, Set.from([3, 4]))   -- Set{1, 2, 3, 4}
Set.size(s)                      -- 3
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `from` | `(List[T]) -> Set[T]` | Create set from list |
| `add` | `(Set[T], T) -> Set[T]` | Add element |
| `remove` | `(Set[T], T) -> Set[T]` | Remove element |
| `contains` | `(Set[T], T) -> Bool` | Membership test |
| `size` | `(Set[T]) -> Int` | Number of elements |
| `union` | `(Set[T], Set[T]) -> Set[T]` | Union of two sets |
| `intersection` | `(Set[T], Set[T]) -> Set[T]` | Intersection of two sets |
| `difference` | `(Set[T], Set[T]) -> Set[T]` | Elements in first but not second |
| `to_list` | `(Set[T]) -> List[T]` | Convert to list |

## Option

Optional values. Used when a value may or may not exist.

Values are `Some(value)` or `None`. Functions like `List.find` and `Map.get` return `Option`.

```skein
fn increment(n: Int) -> Int { n + 1 }

let x = Some(42)
Option.unwrap(x, 0)        -- 42 (returns 0 on None)
Option.map(x, &increment)  -- Some(43)
Option.is_some(x)          -- true
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `unwrap` | `(Option[T], T) -> T` | Extract value, or the default on `None` |
| `map` | `(Option[T], (T) -> U) -> Option[U]` | Transform inner value if present |
| `flat_map` | `(Option[T], (T) -> Option[U]) -> Option[U]` | Chain optional operations |
| `is_some` | `(Option[T]) -> Bool` | True if `Some` |
| `is_none` | `(Option[T]) -> Bool` | True if `None` |

## Result

Error handling. Used for operations that can succeed or fail.

Values are `Ok(value)` or `Err(error)`. Effect calls and parsing functions return `Result`.

```skein
fn increment(n: Int) -> Int { n + 1 }

let r = Ok(42)
Result.unwrap(r, 0)        -- 42 (returns 0 on Err)
Result.map(r, &increment)  -- Ok(43)
Result.is_ok(r)            -- true
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `unwrap` | `(Result[T,E], T) -> T` | Extract value, or the default on `Err` |
| `map` | `(Result[T,E], (T) -> U) -> Result[U,E]` | Transform success value |
| `map_err` | `(Result[T,E], (E) -> F) -> Result[T,F]` | Transform error value |
| `flat_map` | `(Result[T,E], (T) -> Result[U,E]) -> Result[U,E]` | Chain fallible operations |
| `is_ok` | `(Result[T,E]) -> Bool` | True if `Ok` |
| `is_err` | `(Result[T,E]) -> Bool` | True if `Err` |
| `ok` | `(T) -> Result[T,E]` | Wrap value in `Ok` |
| `err` | `(E) -> Result[T,E]` | Wrap error in `Err` |

## Uuid

UUID generation and parsing (v4).

```skein
let id = Uuid.new()        -- "550e8400-e29b-41d4-a716-446655440000"
Uuid.parse("...")           -- Ok(uuid)
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `new` | `() -> String` | Generate a random v4 UUID |
| `parse` | `(String) -> Result[String, String]` | Parse and validate UUID string |
| `to_string` | `(String) -> String` | Format UUID as string |

## Instant

Timestamps. Represents a point in time.

```skein
let now = Instant.now()
let later = Instant.add(now, Duration.hours(2))
Instant.is_before(now, later)  -- true
Instant.diff(later, now)       -- Duration (2 hours)
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `now` | `() -> Instant` | Current timestamp |
| `parse` | `(String) -> Result[Instant, String]` | Parse ISO 8601 string |
| `to_string` | `(Instant) -> String` | Format as ISO 8601 |
| `add` | `(Instant, Duration) -> Instant` | Add duration to instant |
| `subtract` | `(Instant, Duration) -> Instant` | Subtract duration from instant |
| `diff` | `(Instant, Instant) -> Duration` | Time between two instants |
| `is_before` | `(Instant, Instant) -> Bool` | Chronological comparison |
| `is_after` | `(Instant, Instant) -> Bool` | Chronological comparison |

## Duration

Time spans. Used with `Instant` for time arithmetic and with `timer.*` for scheduling.

```skein
let d = Duration.minutes(30)
Duration.to_seconds(d)        -- 1800
Duration.to_string(d)         -- "30m"
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `seconds` | `(Int) -> Duration` | Create from seconds |
| `minutes` | `(Int) -> Duration` | Create from minutes |
| `hours` | `(Int) -> Duration` | Create from hours |
| `days` | `(Int) -> Duration` | Create from days |
| `to_seconds` | `(Duration) -> Int` | Convert to total seconds |
| `to_string` | `(Duration) -> String` | Human-readable string |

## Compilation

Stdlib calls compile to static function calls on the corresponding runtime module:

```skein
-- Skein source
String.upcase("hello")

-- Compiles to (Core Erlang)
call 'Elixir.Skein.Runtime.Stdlib.String':'upcase'("hello")
```

The code generator recognizes stdlib calls by matching the module name against `@stdlib_modules` in the code generator. No capabilities are required for stdlib calls since they perform no I/O effects — though note that `Uuid.new()` and `Instant.now()` are nondeterministic and return different values on each call.
