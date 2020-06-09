#  `llcastool` - CAS Database manipulation tool

`llcastool` is a low-level helper tool for interacting with the cas databases.

## capabilities

Dump server capabilities. This command is also useful for testing connection with the remote server.

```sh
$ llcastool capabilities --url bazel://localhost:8980/remote-execution
```

## put/get

The put/get a single file into or out of the CAS database specified by the URL.

For example, to store a file in a file-backed CAS database and then retreive it using its CAS data id.

```sh
$ cd "$(mktemp -d /tmp/llb2_XXXXXX)"
$ echo foo > foo.txt

# Put the file in the database.
$ llcastool put --url file://$PWD/cas foo.txt
0~SdyHDfHef9YHlM685En1zNrlda_6pnoktirLA-A525I=

# Retreive the previously stored file from the database.
$ llcastool get --url file://$PWD/cas --id 0~SdyHDfHef9YHlM685En1zNrlda_6pnoktirLA-A525I= bar.txt
$ cat bar.txt
foo
```
