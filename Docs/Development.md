# Development

This document contains information on how to develop `llbuild2`.

# RE2 Server

`llbuild2` can perform execution on build servers that implement [Bazel's RE2 APIs](https://github.com/bazelbuild/remote-apis). There are [many](https://github.com/bazelbuild/remote-apis#servers) OSS build servers that you can stand up for development. 

[Buildbarn](https://github.com/buildbarn) is one such build server which can be run locally with Docker. Follow the instructions on [this](https://github.com/buildbarn/bb-deployments#recommended-setup) page to setup your server for development and then test the connection using [`retool`](./retool.md):

```sh
$ swift run retool ... (coming soon)
```
