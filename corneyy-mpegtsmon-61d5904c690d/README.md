Freeware open source realtime monitoring the quality of the multicast mpeg ts

Application features:

* Realtime monitoring the bitrate, scrambling control, transport error indicator 
* Realtime monitoring the сontinuity counter to detect packet lost
* Distributed realtime monitoring by [remote probes](https://bitbucket.org/corneyy/mtsm_probe)
* SNMP agent ([MIB](https://bitbucket.org/corneyy/mpegtsmon/raw/2611cba323edc6f7199651bb5640f3a06d86ad64/mibs/MPEGTSMON-MIB.mib)):
    * Total bytes_in, сontinuity error counters
    * Total streams, bad streams gauges
    * Stream up/down traps
    * Bytes_in, сontinuity error counters, status of each stream
    * Probes status
    * Stream status at probes
* Web-console:
    * summary state
    * stream's list with bitrate and error charts
    * stream's and probe's list with error charts
    * the wall of stream thumbnails

Known issues:

* The program does not control the state of discontinuity indicator in the adaptation field

Screenshoots:

![](http://farbow.ru/mpegtsmon/mpegtsmon_shot01_thumb.png)
![](http://farbow.ru/mpegtsmon/mpegtsmon_shot02_thumb.png)

Installation

Required: Erlang/OTP 18+, git, rebar, gcc. ffmpeg for thumbnails. 

Installation procedure:

* git clone git@bitbucket.org:corneyy/mpegtsmon.git or download branch from [Bitbucket](https://bitbucket.org/corneyy/mpegtsmon/downloads)
* git checkout release or git checkout master
* rebar get-deps compile
* Check paths in thumb.sh
* Prepare mcasts.txt (see mcasts.txt.sample). Names encoding - utf8. Set priority field to "1" for bolding stream name in the web-console
* Prepare configs from * .sample, snmp/* .sample. Use sample2conf.sh for copying
* Use run.sh for console test 
* Use release.sh for copying mpegtsmon mini-release to other directory
* Use start_daemon.sh and stop_daemon.sh for background run.
* Centos6 init.d service prototype: contrib/centos6/mpegtsmon

Detailed description: http://farbow.ru/mpegtsmon/en

Contact: [G+](https://plus.google.com/u/0/communities/100931549539779383687)