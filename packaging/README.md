# Packaging
These are partial packaging metadata for distributions.
You can use these to build your own packages so your Plumage installation is package-managed, or if you're willing to pick up maintainance of it for a distribution, they may contain some useful starting points.

## debian
Actually targetting Ubuntu Trusty.
Note that the source format is set to `native` for making private package builds without having to roll origin tarballs.
(This also affects the changelog.)
If you symlink this to the base of the Plumage sources it should build a binary package for each component plus one for the SUID `plumage_run` wrapper.

**Careful:** the `rules` assume you will be building with a disposable chrooted environment, like [sbuild](https://wiki.debian.org/sbuild).
They'll make a mess of the source directory copying common files around that they don't know how to clean up again.
Note that, for Ubuntu Trusty at least, some of the dependencies are in `universe`.
