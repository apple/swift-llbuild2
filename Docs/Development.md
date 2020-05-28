# Development

This document contains information on how to develop `llbuild2`.

# RE2 Server

`llbuild2` can perform execution on build servers that implement [Bazel's RE2 APIs](https://github.com/bazelbuild/remote-apis). There are [many](https://github.com/bazelbuild/remote-apis#servers) OSS build servers that you can stand up for development. 

[Buildbarn](https://github.com/buildbarn) is one such build server which can be run locally with Docker. Follow the instructions on [this](https://github.com/buildbarn/bb-deployments#recommended-setup) page to setup your server for development and then test the connection using [`retool`](./retool.md):

```sh
$ swift run retool capabilities --url grpc://localhost:8980 --instance-name remote-execution

BazelRemoteAPI.Build_Bazel_Remote_Execution_V2_ServerCapabilities:
cache_capabilities {
  digest_function: [MD5, SHA1, SHA256, SHA384, SHA512]
  action_cache_update_capabilities {
  }
  symlink_absolute_path_strategy: ALLOWED
}
execution_capabilities {
  digest_function: SHA256
  exec_enabled: true
  execution_priority_capabilities {
    priorities {
      min_priority: -2147483648
      max_priority: 2147483647
    }
  }
}
low_api_version {
  major: 2
}
high_api_version {
  major: 2
}
```
