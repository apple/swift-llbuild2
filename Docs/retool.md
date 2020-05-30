#  `retool` - Remote Execution Tool

`retool` is a low-level helper tool for interacting with the remote execution services.

## capabilities

Dump server capabilities. This command is also useful for testing connection with the remote server.

```sh
$ retool capabilities --url grpc://localhost:8980 --instance-name remote-execution
```
## CAS

The CAS subcommand allows performing operations on the CAS database.

In this example, we store a file in a file-backed CAS database and then retreive it using its CAS data id.

```sh
$ cd "$(mktemp -d /tmp/llb2_XXXXXX)"
$ echo foo > foo.txt

# Put the file in the database.
$ retool cas put --url file://$PWD/cas foo.txt
0~SdyHDfHef9YHlM685En1zNrlda_6pnoktirLA-A525I=

# Retreive the previously stored file from the database.
$ retool cas get --url file://$PWD/cas --id 0~SdyHDfHef9YHlM685En1zNrlda_6pnoktirLA-A525I= bar.txt
$ cat bar.txt
foo
```
