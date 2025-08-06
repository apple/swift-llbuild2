//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2022-2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#ifndef INTERNAL_HELPERS_H
#define INTERNAL_HELPERS_H
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#if defined(__APPLE__)
#include <sys/types.h>

ssize_t __getdirentries64(int fd, void *buf, size_t bufsize, off_t *basep);
#endif

static int positive_int_parse(const char *str) {
    int out = 0;
    char c = 0;

    while ((c = *str++) != 0) {
        out *= 10;
        if (c >= '0' && c <= '9') {
            out += c - '0';
        } else {
            return -1;
        }
    }
    return out;
}

#if defined(__linux__) || defined(__APPLE__)
// Platform-specific version that uses syscalls directly and doesn't allocate heap memory.
// Safe to use after vfork() and before execve()
static int highest_possibly_open_fd_dir_syscall(const char *fd_dir) {
    int highest_fd_so_far = 0;
    int dir_fd = open(fd_dir, O_RDONLY);
    if (dir_fd < 0) {
        // errno set by `open`.
        return -1;
    }

    // Buffer for directory entries - allocated on stack, no heap allocation
    char buffer[4096] = {0};
#if defined(__linux__)
    ssize_t bytes_read = -1;
#elif defined(__APPLE__)
    ssize_t bytes_read = -1;
    off_t os_controlled_seek_pos = -1;
#endif

    while ((
#if defined(__linux__)
#  if defined(__GLIBC__) && __GLIBC__ == 2 && defined(__GLIBC_MINOR__) && __GLIBC_MINOR__ >= 30
        bytes_read = getdents64(dir_fd, (struct dirent64 *)buffer, sizeof(buffer))
#  else
        bytes_read = syscall(SYS_getdents64, dir_fd, (struct dirent64 *)buffer, sizeof(buffer))
#  endif
#elif defined(__APPLE__)
        bytes_read = __getdirentries64(dir_fd, buffer, sizeof(buffer), &os_controlled_seek_pos)
#endif
        ) > 0) {
        if (bytes_read < 0) {
            if (errno == EINTR) {
                continue;
            } else {
                // `errno` set by getdents64/getdirentries.
                highest_fd_so_far = -1;
                goto error;
            }
        }
        long offset = 0;
        while (offset < bytes_read) {
#if defined(__linux__)
            struct dirent64 *entry = (struct dirent64 *)(buffer + offset);
#elif defined(__APPLE__)
            struct dirent *entry = (struct dirent *)(buffer + offset);
#endif

            // Skip "." and ".." entries
            if (entry->d_name[0] != '.') {
                int number = positive_int_parse(entry->d_name);
                if (number > highest_fd_so_far) {
                    highest_fd_so_far = number;
                }
            }

            offset += entry->d_reclen;
        }
    }

error:
    close(dir_fd);
    return highest_fd_so_far;
}
#endif

static int highest_possibly_open_fd(void) {
#if defined(__APPLE__)
    int hi = highest_possibly_open_fd_dir_syscall("/dev/fd");
    if (hi < 0) {
        hi = getdtablesize();
    }
#elif defined(__linux__)
    int hi = highest_possibly_open_fd_dir_syscall("/proc/self/fd");
    if (hi < 0) {
        hi = getdtablesize();
    }
#else
    int hi = 1024;
#endif

    return hi;
}

static int block_everything_but_something_went_seriously_wrong_signals(sigset_t *old_mask) {
    sigset_t mask;
    int r = 0;
    r |= sigfillset(&mask);
    r |= sigdelset(&mask, SIGABRT);
    r |= sigdelset(&mask, SIGBUS);
    r |= sigdelset(&mask, SIGFPE);
    r |= sigdelset(&mask, SIGILL);
    r |= sigdelset(&mask, SIGKILL);
    r |= sigdelset(&mask, SIGSEGV);
    r |= sigdelset(&mask, SIGSTOP);
    r |= sigdelset(&mask, SIGSYS);
    r |= sigdelset(&mask, SIGTRAP);

    r |= pthread_sigmask(SIG_BLOCK, &mask, old_mask);
    return r;
}
#endif
