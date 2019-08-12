# Nim Runner for UNIX

This is a rewrite of the [Taker's](https://github.com/taker-project/taker_v0) default `taker_unixrun` into [Nim programming language](https://nim-lang.org). I hope you'll like it!

## Supported platforms

Like `taker_unixrun`, it should work on GNU/Linux, macOS and FreeBSD, but now it was tested only on GNU/Linux and FreeBSD. Maybe I'll test it on other systems later. It can also run on other UNIXes, but some patching may be required.

## Building

You will need a `nim` compiler.

Then just run in shell:

```
$ nim c taker_unixrun.nim
```

## Testing

Currently it's hard to test runners, because Taker's test system is used only for testing `taker_unixrun`. Some hacking with Taker, of course, will solve the problem.

Later, I'm planning to split runners' tests from the main tests, so the runner can be tested independently of Taker itself.
