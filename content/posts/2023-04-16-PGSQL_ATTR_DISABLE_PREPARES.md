---
title: "Boost your PDO + PostgreSQL performance by enabling this option"
date: 2023-04-16T02:53:51+02:00
tags: []
draft: true
---

Want a "free" performance boost using PHP PDO + PostgreSQL without optimizing your queries?
Then you should enable the driver-specific `PGSQL_ATTR_DISABLE_PREPARES` option.<!--more-->

# Browsing the PHP manual

The other day I was looking around in the PHP manual and stumbled upon the
"PDO Drivers" section. Looking at the
[PostgreSQL subsection](https://www.php.net/manual/en/ref.pdo-pgsql.php),
I found this constant:

> **PDO::PGSQL_ATTR_DISABLE_PREPARES (int)**
Send the query and the parameters to the server together in a single call,
avoiding the need to create a named prepared statement separately. If the query
is only going to be executed once this can reduce latency by avoiding an
unnecessary server round-trip.

That sounded interesting - reduce the database calls by 50% just by enabling this option?
I was looking around to find more about this setting, but there are almost no further resources.
What I *could* find was:

* Doctrine [enables this setting by default](https://github.com/doctrine/dbal/pull/714]) since 2014.
* The [commit messages](https://github.com/php/php-src/commit/e378348a316008822737d47cf47a4938cbc07dd6)
that introduced this feature to PHP reads:

> Faster than prepared statements when queries are run once. Slightly
slower than PDO::ATTR_EMULATE_PREPARES but without the potential
security implications of embedding parameters in the query itself.

So what's the drawback? If you are preparing a statement and then execute
it *many* times, this setting will decrease performance. But I'm pretty sure
almost all webapps use one-off queries exclusively.

# Benchmarks

Time to do some
"scientific" benchmarks on a website which I maintain, and which has a pretty
old codebase with sometimes 100 and more queries per page load.
I tested three different scenarios with `PGSQL_ATTR_DISABLE_PREPARES` enabled
and disabled.

![targets](/images/pgsql-plot.png)

As you can see enabling this option reduces the total page load time in
scenario **T** by 15%, 7% in test **C** and 3,8% in test **O**, although the
error bars are overlapping in the last two scenarios.

# Defaults

In my opinion, defaults should be chosen to provide sane defaults
and optimum performance for the *majority* of applications. I'm glad
that `ERRMODE_EXCEPTION` is enabled by default since PHP 8.0 - but this
will **break** all applications that expect `execute()` et al to **not** throw
Exceptions. Nevertheless, it should improve code quality because database
errors will no longer be unnoticed.

The option `PGSQL_ATTR_DISABLE_PREPARES` on the other hand should **not break**
any application - the worst case would be making applications slower that
execute the same statement many times. But changing defaults seems to be
a lengthy process for PHP - which is good on one side, because that means
less applications will break when upgrading PHP. On the other side, I think
enabling this option would be a good default. But maybe there a reasons
I don't know about (yet), or just no one cares enough to start the process
of changing the default. Furthermore, this option *only* works for
PostgreSQL, so the affected userbase is not everyone who uses the `PDO` class.