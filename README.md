This is a repository of Slackware packages targeted for Unraid, though they should work in Slackware as well. They are built with Docker using Unraid as the base image. [Slackbuilds.org](https://slackbuilds.org) is used when possible and [Alien's SlackBuild Toolkit](https://alien.slackbook.org/AST/) is used for the others.

This repository is compatible with `slackpkg+`. To use it, add `MIRRORPLUS['bobbintb']=https://raw.githubusercontent.com/bobbintb/Slackware_Packages/refs/heads/main/builds/` to your `/etc/slackpkg/slackpkgplus.conf` file. Make sure you run `slackpkg update gpg` and `slackpkg update` after modifying the config file.
You can download `slackpkg` and `slackpkg+` here:

  slackpkg 15.0.10 https://www.slackpkg.org/

  slackpkg+ 1.8.0 https://slakfinder.org/slackpkg+.html
