---
title: Skein Language
description: A BEAM language designed for humans to build agent services, and for agents to write code in.
template: splash
hero:
  tagline: A new programming language that compiles to BEAM bytecode, designed for building cloud services where AI agents are first-class constructs.
  actions:
    - text: Get Started
      link: /getting-started/overview/
    - text: Language Guide
      link: /language/syntax/
      variant: minimal
---

## What is Skein?

Skein is a programming language that compiles to BEAM bytecode and runs on the Erlang VM (OTP). It is co-optimized for two audiences: **humans who read and review code**, and **LLM agents who generate and modify code**.

The language sits at the intersection of three ideas:

1. **The BEAM/OTP runtime** provides battle-tested concurrency, fault tolerance, and distribution -- exactly what long-running agent processes need.
2. **An integrated platform model** with trace-driven development and the "service as the unit of work" philosophy.
3. **Agent-writability as a first-class design constraint** -- a language whose entire spec fits in an LLM context window, with maximally regular syntax and a type system that doubles as a contract language for tool calling.

## Current Status

**Phase 1 ("Hello BEAM") is complete.** The end-to-end compilation pipeline works:

- Lexer tokenizes Skein source into a token stream
- Parser builds a full AST via recursive descent
- Code generator produces Core Erlang via the `:cerl` module
- OTP's `:compile.forms/2` compiles to BEAM bytecode
- Modules load into the VM and functions are callable from Elixir

The test suite has **162 checks** (134 unit tests + 28 property-based tests) with 0 failures.

## Quick Example

```
module Hello {
  fn greet(name: String) -> String {
    "Hello, ${name}!"
  }

  fn add(a: Int, b: Int) -> Int {
    a + b
  }

  fn classify(n: Int) -> String {
    match n > 0 {
      true  -> "positive"
      false -> "non-positive"
    }
  }
}
```

Compile and call from Elixir:

```elixir
{:module, mod} = Skein.Compiler.compile_file("hello.skein")
mod.greet("World")    #=> "Hello, World!"
mod.add(3, 4)         #=> 7
mod.classify(-1)      #=> "non-positive"
```
