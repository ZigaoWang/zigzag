# Specs

How Zigzag behaves today, one file per area: the everyday behavior people rely on, which shouldn't change by accident.

One behavior per line, with the test that checks it on the next:

```
- <what you do> → <what happens>.
  Test: SuiteName.testName
```

A behavior nothing checks yet says `No test yet.` instead. SpecLinksTests fails if a named test doesn't exist.

A PR that changes one of these behaviors updates its line in the same PR. A bug fix that brings back what a line already says leaves the spec alone.
