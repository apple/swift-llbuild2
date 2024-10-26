> ⚠️ Warning: BashExpr is an experimental API.

Here is all the boilerplate steps that you need in order to implement your own evaluator for a bash-like language.

# BashExpr

### What is BashExpr?

BashExpr is able to parse and interpret something like `echo $(cat paths.txt | head):/foo bar`.

It is implemented around "protocols"/"delegates" so you provide your own in-memory implementation of the commands.

You would wish tree sitter would take a string and produce an enum like this:

```
indirect enum BashExpr<T: Equatable>: Equatable {
   case program([BashExpr])
   case command(commandName: BashExpr, args: [BashExpr])
   case literal(String)
   case number(Int)
   case error(BashExprError<T>)
   case concatenation([BashExpr])
   case commandSubstitution([BashExpr])
   case simpleExpansion([BashExpr])
}
```

... and let's pretend it can do that. ([100 lines of code](BashExpr+TreeSitter.swift) to do this).

If you have the above, you can very easily start writing an evaluator. BashExpr gives you these knobs:

### Sandboxing
You get to have a lot of fine-grained control over what you want to allow and disallow in Bash. You can leverage the conventional string-based stdin, stdout and stderr (and process exit code), but you can also return BashExpr return values, or pass them around as args. It really is on you or your use case to set the boundaries.

### Variable mappings (passing Swift values as ENV vars)
TBD.

### In-memory commands

In reality you are providing in-memory implementation for the commands. But what your users see is the ever-familiar POSIX shell. Best of both worlds.

### Memoized BashExpr and llbuild2fx

TBD

### Leveraging Swift Argparse
TBD.

### Inline errors

Incorporating "error" as part of a valid thing in AST makes it easy to provide contextual errors. You can plug in your own error type into this mechanism.

### Multi-pass evaluation

In some cases you might want to post-process this tree in many passes. Think of it as a petri dish that can let you grow your controlled subset of Bash. And for parts that you intentionally want to restrict, use your own enum to provide errors and diagnostics.


---

### A BashExpr dialect for CAS operations

The best way to transform CAS objects is directly in Swift.

The next best is with Bash and "castool". Let's emulate that with BashExpr.

### Bonus content: Can you plug this into a spreadsheet calc engine?

Yes. Especially if you also incorporate the CAS layer. A sandboxed shell dialect with in-memory implementation of commands (err, formulas) seems like a good fit for a calc engine to me.

### Bonus content: Can you extend BashExpr and recognize data frames or JSON as first-class data values?

Yes. And this is what Nushell executes really well. We can take a stab at it.
In this area, next step beyond this is to incorporate this layer into the spreadsheet grid. A different flavor of Microsoft's "Gridlets".

---

### Beyond BashExpr (similar ideas in a different domain)

Next step: Something like BashExpr, but for intercepting Unix syscalls. You provide your own implementation of the syscall. (see also gVisor and Browsix, two projects with very different goals)
