# Basic usage:

(Option order doesn't matter, except "-- query" which must be at
the end.)

Select or create 'myprj' session, store it active in the
 current shell session group, and perform a query, which will
 be stored in 'myprj' chat history.
```bash
$ z -n myprj --sp -- "What's a SID and Session Group Leader?"
```

Same, but subdirs can be used
```bash
$ z -n myprj/subprj --sp -- "Help me"
$ z -n myprj -- "One-time use of myprj, not saved."
```

Store 'default' as user global session (to be used when session
 is not specified or not set with --sp in the current shell.
```bash
$ z -n default --su # Store 'default' as user global session
```

```bash
$ z I can query unsafely too.
$ cat q.txt | z -
```

System prompt name (from system files or through 'persona' bin)
 Here I'm specifying cat-talk as my session, and storing (-ss)
 its active system prompt name as 'my-cat'
```bash
$ z --system my-cat --ss -n cat-talk -- "I stored my-cat in my 'session')
```

Provide a path to the system prompt (resolved to its full present path),
and store it default in the 'cat-talk' session. Then set a string
temporarily as the prompt.
```bash
$ z --system-file here/sys.txt --ss -n cat-talk -- "And a query."
$ z --system-str "You are a helpful assistant" -n cat-talk -- "And a query."
```
