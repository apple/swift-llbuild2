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

#ifndef PS_API_H
#define PS_API_H

#include <stdbool.h>
#include <unistd.h>

typedef enum ps_error_kind_s {
    PS_ERROR_KIND_EXECVE = 1,
    PS_ERROR_KIND_PIPE = 2,
    PS_ERROR_KIND_FCNTL = 3,
    PS_ERROR_KIND_SIGNAL = 4,
    PS_ERROR_KIND_SIGPROC_MASK = 5,
    PS_ERROR_KIND_CHDIR = 6,
    PS_ERROR_KIND_SETSID = 7,
    PS_ERROR_KIND_DUP2 = 8,
    PS_ERROR_KIND_READ_FROM_CHILD = 9,
    PS_ERROR_KIND_DUP = 10,
    PS_ERROR_KIND_SIGMASK_THREAD = 11,
    PS_ERROR_KIND_FAILED_CHILD_WAITPID = 12,
} ps_error_kind;

typedef struct ps_error_s {
    ps_error_kind pse_kind;
    int pse_code;
    const char *pse_file;
    int pse_line;
    int pse_extra_info;
} ps_error;

typedef enum ps_fd_setup_kind_s {
    PS_MAP_FD = 1,
    PS_CLOSE_FD = 2,
} ps_fd_setup_kind;

typedef struct ps_fd_setup_s {
    ps_fd_setup_kind psfd_kind;
    int psfd_parent_fd;
} ps_fd_setup;

typedef struct ps_process_configuration_s {
    const char *psc_path;

    // including argv[0]
    char **psc_argv;

    char **psc_env;

    const char *psc_cwd;

    int psc_fd_setup_count;
    const ps_fd_setup *psc_fd_setup_instructions;

    bool psc_new_session;
    bool psc_close_other_fds;
} ps_process_configuration;

pid_t ps_spawn_process(ps_process_configuration *config, ps_error *out_error);

void ps_convert_exit_status(int in_status, bool *out_has_exited, bool *out_is_exit_code, int *out_code);

#endif
